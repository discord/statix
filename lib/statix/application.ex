defmodule Statix.Application do
  @moduledoc false

  @doc """
  Starts the Statix supervision tree lazily on first UDS connection.
  No-op if already started. Safe to call concurrently.
  """
  def ensure_started do
    case Supervisor.start_link([Statix.ConnTracker],
           strategy: :one_for_one,
           name: Statix.Supervisor
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
