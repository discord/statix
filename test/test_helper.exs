Code.require_file("support/test_server.exs", __DIR__)

# Exclude UDS tests on OTP < 22 (when :socket module is not available)
exclude =
  if Code.ensure_loaded?(:socket) do
    []
  else
    [:uds]
  end

ExUnit.start(exclude: exclude)

defmodule Statix.TestCase do
  use ExUnit.CaseTemplate

  using options do
    port = Keyword.get(options, :port, 8125)

    quote do
      setup_all do
        {:ok, _} = Statix.TestServer.start_link(unquote(port), __MODULE__.Server)
        :ok
      end

      setup do
        Statix.TestServer.setup(__MODULE__.Server)
      end
    end
  end
end
