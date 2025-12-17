defmodule Statix.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      %{
        id: Statix.UDSHolder,
        start: {Task, :start_link, [fn -> uds_holder() end]},
        restart: :permanent
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Statix.Supervisor)
  end

  defp uds_holder do
    :ets.new(:statix_uds_sockets, [:named_table, :public, :set, read_concurrency: true])
    Process.register(self(), :statix_uds_holder)
    Process.sleep(:infinity)
  end
end
