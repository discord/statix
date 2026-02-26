Code.require_file("../support/uds_test_server.exs", __DIR__)

defmodule Statix.UDSReconnectTest do
  use ExUnit.Case

  @moduletag :uds

  defmodule TestStatix do
    use Statix, runtime_config: true
  end

  describe "pathology: stale UDS sockets after server restart" do
    test "sends fail after server goes away, and remain broken after server returns" do
      socket_path = "/tmp/statix_reconnect_test_#{:erlang.unique_integer([:positive])}.sock"

      # Don't use UDSTestServer.setup/1 — it registers on_exit callbacks
      # that fail when we manually stop the servers during the test.
      {:ok, server} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.Server)
      :ok = GenServer.call(__MODULE__.Server, {:set_current_test, self()})

      TestStatix.connect(socket_path: socket_path)

      # Verify happy path works
      TestStatix.increment("baseline")
      assert_receive {:test_server, _, "baseline:1|c"}, 1000

      # Kill the test server (simulates Datadog agent restart)
      GenServer.stop(server)
      Process.sleep(100)

      # Attempt to send — should return an error
      result_after_kill = TestStatix.increment("after_kill")

      assert {:error, _reason} = result_after_kill,
             "Expected send to fail after server shutdown, got: #{inspect(result_after_kill)}"

      # Restart the test server on the same socket path
      {:ok, server2} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.Server2)
      :ok = GenServer.call(__MODULE__.Server2, {:set_current_test, self()})

      # Attempt to send with the old (stale) sockets — should STILL fail
      result_after_restart = TestStatix.increment("after_restart")

      assert {:error, _reason} = result_after_restart,
             "Expected send to STILL fail with stale sockets after server restart, " <>
               "got: #{inspect(result_after_restart)}. " <>
               "If this passes (:ok), the pathology may not exist as expected."

      GenServer.stop(server2)
      File.rm(socket_path)
    end
  end

  describe "Conn.safe_open/1" do
    test "returns {:ok, conn} on success" do
      socket_path = "/tmp/statix_safe_open_test_#{:erlang.unique_integer([:positive])}.sock"
      {:ok, server} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.SafeOpenServer)

      conn = Statix.Conn.new(socket_path, nil)
      assert {:ok, %Statix.Conn{transport: :uds, sock: sock}} = Statix.Conn.safe_open(conn)
      assert sock != nil

      :socket.close(sock)
      GenServer.stop(server)
      File.rm(socket_path)
    end

    test "returns {:error, reason} when socket path does not exist" do
      conn =
        Statix.Conn.new(
          "/tmp/statix_nonexistent_#{:erlang.unique_integer([:positive])}.sock",
          nil
        )

      assert {:error, _reason} = Statix.Conn.safe_open(conn)
    end
  end

  describe "ConnTracker state" do
    test "set/3 stores conn_template for reconnection" do
      socket_path = "/tmp/statix_ct_state_#{:erlang.unique_integer([:positive])}.sock"
      {:ok, server} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.CTStateServer)

      Statix.ConnTracker.ensure_started()

      conn_template = Statix.Conn.new(socket_path, nil)
      {:ok, opened} = Statix.Conn.safe_open(conn_template)

      Statix.ConnTracker.set(socket_path, [opened], conn_template: conn_template)

      assert {:ok, %Statix.Conn{transport: :uds}} = Statix.ConnTracker.get(socket_path)

      GenServer.stop(server)
      File.rm(socket_path)
    end
  end

  describe "error detection and marking" do
    test "send failure marks path unhealthy and starts health-check" do
      socket_path = "/tmp/statix_error_detect_#{:erlang.unique_integer([:positive])}.sock"
      {:ok, server} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.ErrorDetectServer)
      :ok = GenServer.call(__MODULE__.ErrorDetectServer, {:set_current_test, self()})

      TestStatix.connect(socket_path: socket_path)

      TestStatix.increment("baseline")
      assert_receive {:test_server, _, "baseline:1|c"}, 1000

      GenServer.stop(server)
      Process.sleep(100)

      assert {:error, _} = TestStatix.increment("after_kill")

      # Sync barrier: forces ConnTracker to process all prior casts
      :sys.get_state(Statix.ConnTracker)

      assert Statix.ConnTracker.unhealthy?(socket_path)

      File.rm(socket_path)
    end
  end

  describe "full reconnect cycle" do
    test "health-check reconnects after server restart" do
      socket_path = "/tmp/statix_reconnect_cycle_#{:erlang.unique_integer([:positive])}.sock"
      {:ok, server} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.ReconnectServer)
      :ok = GenServer.call(__MODULE__.ReconnectServer, {:set_current_test, self()})

      TestStatix.connect(socket_path: socket_path)

      TestStatix.increment("before")
      assert_receive {:test_server, _, "before:1|c"}, 1000

      GenServer.stop(server)
      Process.sleep(100)

      assert {:error, _} = TestStatix.increment("during_outage")

      # Sync barrier: forces ConnTracker to process all prior casts
      :sys.get_state(Statix.ConnTracker)

      assert Statix.ConnTracker.unhealthy?(socket_path)

      {:ok, server2} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.ReconnectServer2)
      :ok = GenServer.call(__MODULE__.ReconnectServer2, {:set_current_test, self()})

      # Wait for health-check to fire (first backoff is ~1 second with jitter)
      Process.sleep(2_000)

      refute Statix.ConnTracker.unhealthy?(socket_path)

      TestStatix.increment("after_reconnect")
      assert_receive {:test_server, _, "after_reconnect:1|c"}, 1000

      GenServer.stop(server2)
      File.rm(socket_path)
    end
  end

  describe "backoff behavior" do
    test "backoff index increments on repeated failure" do
      socket_path = "/tmp/statix_backoff_#{:erlang.unique_integer([:positive])}.sock"
      {:ok, server} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.BackoffServer)
      :ok = GenServer.call(__MODULE__.BackoffServer, {:set_current_test, self()})

      TestStatix.connect(socket_path: socket_path)

      GenServer.stop(server)
      Process.sleep(100)

      assert {:error, _} = TestStatix.increment("trigger")

      # Sync barrier: forces ConnTracker to process all prior casts
      :sys.get_state(Statix.ConnTracker)

      assert Statix.ConnTracker.unhealthy?(socket_path)

      # Wait for first health-check to fire and fail (~1s backoff)
      Process.sleep(1_500)

      assert Statix.ConnTracker.unhealthy?(socket_path)

      File.rm(socket_path)
    end

    test "lost_count tracks dropped metrics" do
      socket_path = "/tmp/statix_lost_count_#{:erlang.unique_integer([:positive])}.sock"
      {:ok, server} = Statix.UDSTestServer.start_link(socket_path, __MODULE__.LostCountServer)
      :ok = GenServer.call(__MODULE__.LostCountServer, {:set_current_test, self()})

      TestStatix.connect(socket_path: socket_path)

      GenServer.stop(server)
      Process.sleep(100)

      for _ <- 1..10 do
        TestStatix.increment("lost_metric")
      end

      # Sync barrier: forces ConnTracker to process all prior casts
      :sys.get_state(Statix.ConnTracker)

      assert Statix.ConnTracker.unhealthy?(socket_path)

      File.rm(socket_path)
    end
  end
end
