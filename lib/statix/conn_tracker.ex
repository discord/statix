defmodule Statix.ConnTracker do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(:statix_conn_tracker, [:set, :protected, :named_table, read_concurrency: true])
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
    :ets.insert(state, {key, connections})
    {:reply, :ok, state}
  end
end
