defmodule Statix.Application do
  @moduledoc false

  @doc """
  Starts the Statix supervision tree lazily on first UDS connection.
  No-op if already started. Safe to call concurrently.
  """
  def ensure_started do
    if GenServer.whereis(Statix.ConnTracker) do
      :ok
    else
      do_start()
    end
  end

  defp do_start do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Statix.DynamicSupervisor}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: Statix.Supervisor) do
      {:ok, _pid} -> start_conn_tracker()
      {:error, {:already_started, _pid}} -> start_conn_tracker()
    end
  end

  defp start_conn_tracker do
    case DynamicSupervisor.start_child(Statix.DynamicSupervisor, Statix.ConnTracker) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
