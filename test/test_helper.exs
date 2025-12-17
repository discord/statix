Code.require_file("support/test_server.exs", __DIR__)

ExUnit.start()

defmodule Statix.TestCase do
  use ExUnit.CaseTemplate

  using options do
    # Use random high port to avoid collisions with typical infra (statsd/dogstatsd)
    port = Keyword.get(options, :port, 8125 + :rand.uniform(10000))
    auto_connect = Keyword.get(options, :auto_connect, true)

    quote do
      setup_all do
        {:ok, _} = Statix.TestServer.start_link(unquote(port), __MODULE__.Server)
        :ok
      end

      setup do
        Statix.TestServer.setup(__MODULE__.Server)

        if unquote(auto_connect) do
          port = Statix.TestServer.get_port(__MODULE__.Server)
          connect(port: port)
        end

        :ok
      end
    end
  end
end
