defmodule Statix.Conn do
  @moduledoc false

  # sock field holds different types depending on state and transport:
  # - UDP: port (after open/1) or atom for process name
  # - UDS: {:socket_path, path} before open/1, socket reference after
  # socket_path field preserves the UDS path even after opening
  defstruct [:sock, :address, :port, :prefix, :transport, :socket_path]

  alias Statix.Packet

  require Logger

  def new(host, port, prefix) when is_binary(host) do
    new(String.to_charlist(host), port, prefix)
  end

  def new(host, port, prefix) when is_list(host) or is_tuple(host) do
    case :inet.getaddr(host, :inet) do
      {:ok, address} ->
        %__MODULE__{address: address, port: port, prefix: prefix, transport: :udp}

      {:error, reason} ->
        raise(
          "cannot get the IP address for the provided host " <>
            "due to reason: #{:inet.format_error(reason)}"
        )
    end
  end

  def new(socket_path, prefix) when is_binary(socket_path) do
    %__MODULE__{
      prefix: prefix,
      transport: :uds,
      sock: {:socket_path, socket_path},
      socket_path: socket_path
    }
  end

  def open(%__MODULE__{transport: :udp} = conn) do
    {:ok, sock} = :gen_udp.open(0, active: false)
    %__MODULE__{conn | sock: sock}
  end

  def open(%__MODULE__{transport: :uds, sock: {:socket_path, path}} = conn) do
    unless Code.ensure_loaded?(:socket) do
      raise "Unix domain socket support requires OTP 22+. Current OTP version does not support :socket module."
    end

    {:ok, sock} = :socket.open(:local, :dgram, :default)
    path_addr = %{family: :local, path: String.to_charlist(path)}

    case :socket.connect(sock, path_addr) do
      :ok ->
        %__MODULE__{conn | sock: sock}

      {:error, reason} ->
        :socket.close(sock)
        raise "Failed to connect to Unix domain socket at #{path}: #{inspect(reason)}"
    end
  end

  def transmit(%__MODULE__{sock: sock, prefix: prefix} = conn, type, key, val, options)
      when is_binary(val) and is_list(options) do
    result =
      prefix
      |> Packet.build(type, key, val, options)
      |> transmit(conn)

    with {:error, error} <- result do
      Logger.error(fn ->
        if(is_atom(sock), do: "", else: "Statix ") <>
          "#{inspect(sock)} #{type} metric \"#{key}\" lost value #{val}" <>
          " error=#{inspect(error)}"
      end)
    end

    result
  end

  defp transmit(packet, %__MODULE__{
         transport: :udp,
         address: address,
         port: port,
         sock: sock_name
       }) do
    sock = Process.whereis(sock_name)

    if sock do
      :gen_udp.send(sock, address, port, packet)
    else
      {:error, :port_closed}
    end
  end

  defp transmit(packet, %__MODULE__{transport: :uds, sock: sock}) do
    # UDS DGRAM sockets send atomically
    :socket.send(sock, packet)
  end

  defp transmit(_packet, %__MODULE__{transport: transport}) do
    raise ArgumentError, "unsupported transport type: #{inspect(transport)}"
  end
end
