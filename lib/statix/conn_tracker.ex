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
  Check if a path is marked unhealthy. Lock-free ETS read for hot path.
  """
  @spec unhealthy?(key :: term()) :: boolean()
  def unhealthy?(key) do
    :ets.lookup(:statix_conn_tracker, {:unhealthy, key}) != []
  rescue
    ArgumentError -> false
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
    :ets.delete(state.table, {:unhealthy, key})

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
          # Mark as unhealthy, insert ETS sentinel, schedule first health-check
          :ets.insert(state.table, {{:unhealthy, path}, true})

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

  defp attempt_reconnect(path, entry, state) do
    # Capture old connections for cleanup AFTER new ones are in ETS.
    # This avoids a window where get/1 returns conns with closed sockets.
    old_conns =
      case :ets.lookup(state.table, path) do
        [{^path, conns}] -> conns
        [] -> []
      end

    # Try to open pool_size new sockets
    results =
      Enum.map(1..entry.pool_size, fn _ ->
        Conn.safe_open(entry.conn_template)
      end)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    cond do
      successes != [] ->
        # At least some sockets opened — swap in new connections, then close old.
        # Accepts partial success: better to have some working sockets than none.
        connections = Enum.map(successes, fn {:ok, conn} -> conn end)
        :ets.insert(state.table, {path, connections})
        :ets.delete(state.table, {:unhealthy, path})
        close_connections(old_conns)

        if failures == [] do
          Logger.info(
            "Statix: reconnected UDS path #{path} " <>
              "after losing #{entry.lost_count} metric(s)"
          )
        else
          opened = length(successes)
          failed = length(failures)

          Logger.info(
            "Statix: partially reconnected UDS path #{path} " <>
              "(#{opened}/#{opened + failed} sockets), " <>
              "lost #{entry.lost_count} metric(s)"
          )
        end

        {:noreply, %{state | unhealthy: Map.delete(state.unhealthy, path)}}

      true ->
        # All failed — keep stale conns in ETS, schedule retry with backoff
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
      fn
        {{:unhealthy, _}, _}, acc ->
          acc

        {_path, connections}, acc ->
          close_connections(connections)
          acc
      end,
      nil,
      table
    )

    :ok
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
