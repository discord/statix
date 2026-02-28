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
      case Supervisor.start_link([Statix.ConnTracker],
             strategy: :one_for_one,
             name: Statix.Supervisor
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
