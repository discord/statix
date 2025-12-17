defmodule Statix.SocketPool do
  @moduledoc false

  use GenServer

  alias Statix.Conn

  require Logger

  @doc """
  Starts a socket pool GenServer that owns an ETS table for UDS socket references.
  """
  def start_link(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    GenServer.start_link(__MODULE__, opts, name: via_name(table_name))
  end

  @impl true
  def init(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    conn = Keyword.fetch!(opts, :conn)
    pool = Keyword.fetch!(opts, :pool)

    # Create table owned by this GenServer
    # Use :public access for fast concurrent reads without message passing
    ^table_name = :ets.new(table_name, [:named_table, :public, :set, read_concurrency: true])

    # Open sockets and store in ETS pool
    Enum.each(pool, fn name ->
      opened_conn = Conn.open(conn)
      :ets.insert(table_name, {name, opened_conn})
    end)

    {:ok, %{table: table_name, pool: pool}}
  end

  @impl true
  def terminate(_reason, %{table: table, pool: pool}) do
    # Clean up sockets on termination
    Enum.each(pool, fn name ->
      case :ets.lookup(table, name) do
        [{^name, %Conn{transport: :uds, sock: sock}}] ->
          :socket.close(sock)

        _ ->
          :ok
      end
    end)

    :ok
  end

  defp via_name(table_name) do
    {:via, Registry, {Statix.SocketPoolRegistry, table_name}}
  end
end
