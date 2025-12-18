defmodule Statix.UDSTestServer do
  use GenServer

  def start_link(socket_path, test_module) do
    GenServer.start_link(__MODULE__, socket_path, name: test_module)
  end

  @impl true
  def init(socket_path) do
    unless Code.ensure_loaded?(:socket) do
      {:stop, :socket_not_available}
    else
      {:ok, sock} = :socket.open(:local, :dgram, :default)

      addr = %{family: :local, path: String.to_charlist(socket_path)}
      :ok = :socket.bind(sock, addr)
      :ok = :socket.setopt(sock, :otp, :rcvbuf, 65536)

      case :socket.recvfrom(sock, 0, [], :nowait) do
        {:ok, _} = result ->
          send(self(), {:socket_data, result})

        {:select, _select_info} ->
          :ok

        {:error, reason} ->
          {:stop, {:socket_error, reason}}
      end

      {:ok, %{socket: sock, socket_path: socket_path, test: nil}}
    end
  end

  @impl true
  def handle_call({:set_current_test, current_test}, _from, %{test: test} = state) do
    if is_nil(test) or is_nil(current_test) do
      {:reply, :ok, %{state | test: current_test}}
    else
      {:reply, :error, state}
    end
  end

  @impl true
  def handle_info(
        {:"$socket", socket, :select, _select_info},
        %{socket: socket, test: test} = state
      ) do
    case :socket.recvfrom(socket, 0, [], :nowait) do
      {:ok, {_source, packet}} ->
        if test, do: send(test, {:test_server, %{socket: socket}, packet})
        start_receive(socket)
        {:noreply, state}

      {:select, _select_info} ->
        {:noreply, state}

      {:error, reason} ->
        IO.puts("UDS receive error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:socket_data, {:ok, {_source, packet}}}, %{socket: socket, test: test} = state) do
    if test, do: send(test, {:test_server, %{socket: socket}, packet})

    start_receive(socket)
    {:noreply, state}
  end

  defp start_receive(socket) do
    case :socket.recvfrom(socket, 0, [], :nowait) do
      {:ok, {_source, _packet}} = result ->
        send(self(), {:socket_data, result})

      {:select, _select_info} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @impl true
  def terminate(_reason, %{socket: socket, socket_path: path}) do
    :socket.close(socket)
    _ = File.rm(path)
    :ok
  end

  def setup(test_module) do
    :ok = set_current_test(test_module, self())
    ExUnit.Callbacks.on_exit(fn -> set_current_test(test_module, nil) end)
  end

  defp set_current_test(test_module, test) do
    GenServer.call(test_module, {:set_current_test, test})
  end
end
