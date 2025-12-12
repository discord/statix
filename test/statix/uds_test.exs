Code.require_file("../support/uds_test_server.exs", __DIR__)

defmodule Statix.UDSTest do
  use ExUnit.Case

  # Only run these tests on OTP 22+ with :socket support
  @moduletag :uds

  defmodule TestStatix do
    use Statix, runtime_config: true
  end

  setup_all do
    # Skip if :socket module is not available
    unless Code.ensure_loaded?(:socket) do
      :ok
    else
      # Create temporary socket path
      socket_path = "/tmp/statix_test_#{:erlang.unique_integer([:positive])}.sock"

      # Start UDS test server
      {:ok, _} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.Server)

      on_exit(fn ->
        File.rm(socket_path)
      end)

      {:ok, socket_path: socket_path}
    end
  end

  setup context do
    if Code.ensure_loaded?(:socket) do
      Statix.UDSTestServer.setup(__MODULE__.Server)
      TestStatix.connect(socket_path: context[:socket_path])
    end

    :ok
  end

  test "increment via UDS", _context do
    TestStatix.increment("sample")
    assert_receive {:test_server, _, "sample:1|c"}

    TestStatix.increment("sample", 2)
    assert_receive {:test_server, _, "sample:2|c"}

    TestStatix.increment("sample", 3, tags: ["foo:bar", "baz"])
    assert_receive {:test_server, _, "sample:3|c|#foo:bar,baz"}
  end

  test "decrement via UDS", _context do
    TestStatix.decrement("sample")
    assert_receive {:test_server, _, "sample:-1|c"}

    TestStatix.decrement("sample", 2)
    assert_receive {:test_server, _, "sample:-2|c"}

    TestStatix.decrement("sample", 3, tags: ["foo:bar", "baz"])
    assert_receive {:test_server, _, "sample:-3|c|#foo:bar,baz"}
  end

  test "gauge via UDS", _context do
    TestStatix.gauge("sample", 2)
    assert_receive {:test_server, _, "sample:2|g"}

    TestStatix.gauge("sample", 2.1)
    assert_receive {:test_server, _, "sample:2.1|g"}

    TestStatix.gauge("sample", 3, tags: ["foo:bar", "baz"])
    assert_receive {:test_server, _, "sample:3|g|#foo:bar,baz"}
  end

  test "histogram via UDS", _context do
    TestStatix.histogram("sample", 2)
    assert_receive {:test_server, _, "sample:2|h"}

    TestStatix.histogram("sample", 2.1)
    assert_receive {:test_server, _, "sample:2.1|h"}

    TestStatix.histogram("sample", 3, tags: ["foo:bar", "baz"])
    assert_receive {:test_server, _, "sample:3|h|#foo:bar,baz"}
  end

  test "timing via UDS", _context do
    TestStatix.timing("sample", 2)
    assert_receive {:test_server, _, "sample:2|ms"}

    TestStatix.timing("sample", 2.1)
    assert_receive {:test_server, _, "sample:2.1|ms"}

    TestStatix.timing("sample", 3, tags: ["foo:bar", "baz"])
    assert_receive {:test_server, _, "sample:3|ms|#foo:bar,baz"}
  end

  test "set via UDS", _context do
    TestStatix.set("sample", "user1")
    assert_receive {:test_server, _, "sample:user1|s"}

    TestStatix.set("sample", "user2", tags: ["foo:bar"])
    assert_receive {:test_server, _, "sample:user2|s|#foo:bar"}
  end

  test "measure via UDS", _context do
    result = TestStatix.measure("sample", [], fn -> :measured end)
    assert result == :measured
    assert_receive {:test_server, _, <<"sample:", _::binary>>}
  end

  test "sample rate via UDS", _context do
    TestStatix.increment("sample", 1, sample_rate: 1.0)
    assert_receive {:test_server, _, "sample:1|c|@1.0"}

    TestStatix.increment("sample", 1, sample_rate: 0.0)
    refute_received {:test_server, _, _}
  end
end
