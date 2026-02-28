defmodule Statix.ConnTracker do
  @moduledoc false

  use GenServer

  alias Statix.Conn

  require Logger

  @backoff_steps [1_000, 5_000, 30_000, 60_000, 120_000, 300_000]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensures ConnTracker is running. Called lazily on first UDS connection.
  No-op if already started. Starts the entire supervision tree if needed.
  """
  defdelegate ensure_started, to: Statix.Application

  @impl true
  def init(_opts) do
    table =
      :ets.new(:statix_conn_tracker, [:set, :protected, :named_table, read_concurrency: true])

    {:ok, %{table: table, unhealthy: %{}, conn_templates: %{}, pool_sizes: %{}}}
  end

  @spec set(key :: term(), connections :: [Conn.t()], opts :: keyword()) :: :ok
  def set(key, connections, opts \\ []) do
    GenServer.call(__MODULE__, {:set, key, connections, opts})
  end

  @spec get(key :: term()) :: {:ok, Conn.t()} | {:error, :not_found}
  def get(key) do
    case :ets.lookup(:statix_conn_tracker, key) do
      [{^key, [_ | _] = connections}] ->
        {:ok, Enum.random(connections)}

      _ ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  Report a send error for the given path. Non-blocking cast.
  If path is not yet unhealthy, marks it and starts the health-check loop.
  If already unhealthy, increments the lost metric count.
  """
  @spec report_send_error(key :: term()) :: :ok
  def report_send_error(key) do
    GenServer.cast(__MODULE__, {:report_send_error, key})
  end

  @impl true
  def handle_call({:set, key, connections, opts}, _from, state) do
    # Close old connections before replacing them
    case :ets.lookup(state.table, key) do
      [{^key, old_connections}] ->
        close_connections(old_connections)

      [] ->
        :ok
    end

    :ets.insert(state.table, {key, connections})

    # Clear unhealthy state if present — a manual connect() supersedes the health-check loop.
    # Cancel the pending timer so it doesn't close these fresh connections.
    unhealthy =
      case Map.pop(state.unhealthy, key) do
        {nil, map} ->
          map

        {entry, map} ->
          Process.cancel_timer(entry.timer_ref)
          map
      end

    # Store conn_template and pool_size if provided
    conn_templates =
      case Keyword.fetch(opts, :conn_template) do
        {:ok, template} -> Map.put(state.conn_templates, key, template)
        :error -> state.conn_templates
      end

    pool_sizes =
      case Keyword.fetch(opts, :pool_size) do
        {:ok, size} -> Map.put(state.pool_sizes, key, size)
        :error -> state.pool_sizes
      end

    {:reply, :ok,
     %{state | conn_templates: conn_templates, unhealthy: unhealthy, pool_sizes: pool_sizes}}
  end

  @impl true
  def handle_cast({:report_send_error, path}, state) do
    if Map.has_key?(state.unhealthy, path) do
      # Already unhealthy — just bump lost count
      state = update_in(state.unhealthy[path].lost_count, &(&1 + 1))
      {:noreply, state}
    else
      case Map.fetch(state.conn_templates, path) do
        {:ok, conn_template} ->
          # Close and remove stale connections — they're permanently broken.
          # UDS DGRAM sockets to a dead server will never recover on their own;
          # only opening new sockets after the server restarts can restore service.
          close_and_remove(state.table, path)

          pool_size = Map.get(state.pool_sizes, path, 1)
          delay = backoff_ms(0)
          timer_ref = Process.send_after(self(), {:health_check, path}, delay)

          unhealthy_entry = %{
            backoff_index: 0,
            timer_ref: timer_ref,
            conn_template: conn_template,
            pool_size: pool_size,
            lost_count: 1
          }

          Logger.warning(
            "Statix: UDS path #{path} marked unhealthy, " <>
              "scheduling reconnect in #{delay}ms"
          )

          {:noreply, put_in(state.unhealthy[path], unhealthy_entry)}

        :error ->
          # No template stored — can't reconnect. This shouldn't happen.
          Logger.error("Statix: UDS path #{path} has no conn_template, cannot reconnect")
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info({:health_check, path}, state) do
    case Map.fetch(state.unhealthy, path) do
      {:ok, entry} ->
        attempt_reconnect(path, entry, state)

      :error ->
        # No longer unhealthy (race with successful set?)
        {:noreply, state}
    end
  end

  # All-or-nothing reconnection strategy.
  #
  # Unlike UDP over a network, a UDS socket is a local-host resource: the server
  # socket file either exists on the filesystem or it doesn't. There is no partial
  # reachability. If we can open one DGRAM connection to it, we can open all of
  # them; if we can't open one, we can't open any. So partial success doesn't need
  # handling — any failure means total failure, and we retry the full pool later.
  defp attempt_reconnect(path, entry, state) do
    results =
      Enum.map(1..entry.pool_size, fn _ ->
        Conn.safe_open(entry.conn_template)
      end)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    if failures == [] do
      connections = Enum.map(successes, fn {:ok, conn} -> conn end)
      :ets.insert(state.table, {path, connections})

      Logger.info(
        "Statix: reconnected UDS path #{path} " <>
          "after losing #{entry.lost_count} metric(s)"
      )

      {:noreply, %{state | unhealthy: Map.delete(state.unhealthy, path)}}
    else
      # Close any that happened to open — we need all or nothing.
      close_connections(Enum.map(successes, fn {:ok, conn} -> conn end))

      next_index = min(entry.backoff_index + 1, length(@backoff_steps) - 1)
      delay = backoff_ms(next_index)
      timer_ref = Process.send_after(self(), {:health_check, path}, delay)

      Logger.warning(
        "Statix: reconnect failed for UDS path #{path}, " <>
          "#{entry.lost_count} metric(s) lost so far, retrying in #{delay}ms"
      )

      updated_entry = %{entry | backoff_index: next_index, timer_ref: timer_ref}
      {:noreply, put_in(state.unhealthy[path], updated_entry)}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :ets.foldl(
      fn {_path, connections}, acc ->
        close_connections(connections)
        acc
      end,
      nil,
      table
    )

    :ok
  end

  defp close_and_remove(table, path) do
    case :ets.lookup(table, path) do
      [{^path, connections}] ->
        close_connections(connections)
        :ets.delete(table, path)

      [] ->
        :ok
    end
  end

  defp close_connections(connections) do
    Enum.each(connections, fn conn ->
      try do
        :socket.close(conn.sock)
      catch
        _, _ -> :ok
      end
    end)
  end

  defp backoff_ms(index) do
    base = Enum.at(@backoff_steps, index, List.last(@backoff_steps))
    jitter = trunc(base * 0.1)
    base - jitter + :rand.uniform(jitter * 2 + 1) - 1
  end
end
