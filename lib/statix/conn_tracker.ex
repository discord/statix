defmodule Statix.ConnTracker do
  @moduledoc false

  use GenServer

  alias Statix.Conn

  require Logger

  @backoff_steps [1_000, 5_000, 30_000, 60_000, 120_000, 300_000]
  @max_backoff_index length(@backoff_steps) - 1

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(:statix_conn_tracker, [:set, :protected, :named_table, read_concurrency: true])

    {:ok, %{table: table, paths: %{}}}
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
  end

  @spec report_send_error(key :: term()) :: :ok
  def report_send_error(key) do
    GenServer.cast(__MODULE__, {:report_send_error, key})
  end

  @impl true
  def handle_call({:set, key, connections, opts}, _from, state) do
    close_and_remove(state.table, key)
    :ets.insert(state.table, {key, connections})

    case get_in(state.paths, [key, :health]) do
      %{timer_ref: ref} -> Process.cancel_timer(ref)
      _ -> :ok
    end

    paths =
      case Keyword.fetch(opts, :conn_template) do
        {:ok, template} ->
          Map.put(state.paths, key, %{
            conn_template: template,
            pool_size: length(connections),
            health: :ok
          })

        :error ->
          if Map.has_key?(state.paths, key) do
            put_in(state.paths, [key, :health], :ok)
          else
            state.paths
          end
      end

    {:reply, :ok, %{state | paths: paths}}
  end

  @impl true
  def handle_cast({:report_send_error, path}, state) do
    case Map.fetch(state.paths, path) do
      {:ok, %{health: %{} = health}} ->
        paths = put_in(state.paths, [path, :health, :lost_count], health.lost_count + 1)
        {:noreply, %{state | paths: paths}}

      {:ok, %{health: :ok} = _path_entry} ->
        close_and_remove(state.table, path)

        delay = backoff_ms(0)
        timer_ref = Process.send_after(self(), {:health_check, path}, delay)

        Logger.warning(
          "Statix: UDS path #{path} marked unhealthy, " <>
            "scheduling reconnect in #{delay}ms"
        )

        health = %{backoff_index: 0, timer_ref: timer_ref, lost_count: 1}
        paths = put_in(state.paths, [path, :health], health)
        {:noreply, %{state | paths: paths}}

      :error ->
        Logger.error("Statix: UDS path #{path} has no conn_template, cannot reconnect")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:health_check, path}, state) do
    case Map.fetch(state.paths, path) do
      {:ok, %{health: %{} = _health} = path_info} ->
        attempt_reconnect(path, path_info, state)

      _ ->
        # Not unhealthy (race with successful set, or path removed)
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
  defp attempt_reconnect(path, %{health: health} = path_info, state) do
    results =
      Enum.map(1..path_info.pool_size, fn _ ->
        Conn.safe_open(path_info.conn_template)
      end)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))
    opened = Enum.map(successes, fn {:ok, conn} -> conn end)

    if failures == [] do
      :ets.insert(state.table, {path, opened})

      Logger.info(
        "Statix: reconnected UDS path #{path} " <>
          "after losing #{health.lost_count} metric(s)"
      )

      paths = put_in(state.paths, [path, :health], :ok)
      {:noreply, %{state | paths: paths}}
    else
      close_connections(opened)

      next_index = min(health.backoff_index + 1, @max_backoff_index)
      delay = backoff_ms(next_index)
      timer_ref = Process.send_after(self(), {:health_check, path}, delay)

      Logger.warning(
        "Statix: reconnect failed for UDS path #{path}, " <>
          "#{health.lost_count} metric(s) lost so far, retrying in #{delay}ms"
      )

      new_health = %{health | backoff_index: next_index, timer_ref: timer_ref}
      paths = put_in(state.paths, [path, :health], new_health)
      {:noreply, %{state | paths: paths}}
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
    case :ets.take(table, path) do
      [{^path, connections}] -> close_connections(connections)
      [] -> :ok
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
    base = Enum.at(@backoff_steps, index)
    jitter = trunc(base * 0.1)
    base - jitter + :rand.uniform(jitter * 2 + 1) - 1
  end
end
