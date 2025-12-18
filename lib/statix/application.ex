defmodule Statix.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      Statix.ConnTracker
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Statix.Supervisor)
  end
end
