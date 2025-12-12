Code.require_file("../support/uds_test_server.exs", __DIR__)

defmodule Statix.UDSTest do
  use ExUnit.Case

  @moduletag :uds

  defmodule TestStatix do
    use Statix, runtime_config: true
  end

  setup_all do
    socket_path = "/tmp/statix_test_#{:erlang.unique_integer([:positive])}.sock"
    {:ok, _} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.Server)

    on_exit(fn ->
      File.rm(socket_path)
    end)

    {:ok, socket_path: socket_path}
  end

  setup context do
    Statix.UDSTestServer.setup(__MODULE__.Server)
    TestStatix.connect(socket_path: context[:socket_path])
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

  test "large packet over 1024 bytes via UDS maintains atomicity", _context do
    # Create tags that will result in a packet > 1024 bytes
    # Each tag is roughly 30 chars, so ~35 tags = ~1050 bytes total packet
    tags =
      for i <- 1..35 do
        "very_long_tag_name_#{i}:very_long_tag_value_#{i}"
      end

    TestStatix.increment("sample.with.long.metric.name", 1, tags: tags)

    # Verify we receive the complete packet atomically (all or nothing)
    assert_receive {:test_server, _, packet}, 1000

    # Verify packet structure is intact and complete
    assert packet =~ ~r/^sample\.with\.long\.metric\.name:1\|c\|#/
    assert String.contains?(packet, "very_long_tag_name_1:very_long_tag_value_1")
    assert String.contains?(packet, "very_long_tag_name_35:very_long_tag_value_35")

    # Verify packet size exceeds 1024 bytes
    assert byte_size(packet) > 1024
  end

  test "very large packet over 4096 bytes via UDS maintains atomicity", _context do
    # ~140 tags at 30 chars each = ~4200 bytes total
    tags =
      for i <- 1..140 do
        "very_long_tag_name_#{i}:very_long_tag_value_#{i}"
      end

    TestStatix.gauge("sample.metric.with.many.tags", 12345, tags: tags)

    assert_receive {:test_server, _, packet}, 1000

    assert packet =~ ~r/^sample\.metric\.with\.many\.tags:12345\|g\|#/
    assert String.contains?(packet, "very_long_tag_name_1:very_long_tag_value_1")
    assert String.contains?(packet, "very_long_tag_name_140:very_long_tag_value_140")
    assert byte_size(packet) > 4096

    # Verify atomicity: all 140 tags present (no truncation)
    tag_count = packet |> String.split(",") |> length()
    assert tag_count == 140
  end
end
