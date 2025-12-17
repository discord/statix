defmodule Statix.ConnTracker do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(:statix_conn_tracker, [:set, :protected, :named_table, read_concurrency: true])

    {:ok, table}
  end

  def set(key, connections) do
    GenServer.call(__MODULE__, {:set, key, connections})
  end

  def get(key) do
    case :ets.lookup(:statix_conn_tracker, key) do
      [{^key, connections}] ->
        random_connection = Enum.random(connections)
        {:ok, random_connection}

      [] ->
        {:error, :not_found}
    end
  end

  @impl true
  def handle_call({:set, key, connections}, _from, state) do
    # Close old connections before replacing them
    case :ets.lookup(state, key) do
      [{^key, old_connections}] ->
        close_connections(old_connections)

      [] ->
        :ok
    end

    :ets.insert(state, {key, connections})
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, table) do
    # Close all sockets before table is destroyed
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

  defp close_connections(connections) do
    Enum.each(connections, fn conn ->
      if conn.transport == :uds and is_reference(conn.sock) do
        :socket.close(conn.sock)
      end
    end)
  end
end
