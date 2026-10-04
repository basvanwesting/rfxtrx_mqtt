defmodule RfxtrxMqtt.RfxtrxTest do
  use ExUnit.Case, async: true
  alias RfxtrxMqtt.{FakeUART, Rfxtrx}
  alias RfxtrxMqtt.Rfxtrx.Packet

  @status <<0x14, 0x01, 0x00, 1, 0x02, 0x53, 0xF2, 0::8*14>>
  @started <<0x14, 0x01, 0x07, 2, 0x07, "Copyright RFXCOM">>

  defp start(opts \\ []) do
    me = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          uart: {FakeUART, owner: self()},
          port: "/dev/null",
          on_ready_change: fn -> send(me, :ready_change) end,
          reset_delay_ms: 10,
          ack_timeout_ms: 50
        ],
        opts
      )

    start_supervised!({Rfxtrx, opts})
  end

  defp ready(opts \\ []) do
    pid = start(opts)
    assert_receive {:uart_write, reset}
    assert reset == Packet.reset()
    assert_receive :uart_flush
    assert_receive {:uart_write, <<0x0D, 0, 0, 1, 2, _::binary>>}
    send(pid, {:circuits_uart, "fake", @status})
    assert_receive {:uart_write, <<0x0D, 0, 0, 2, 7, _::binary>>}
    send(pid, {:circuits_uart, "fake", @started})
    pid
  end

  test "handshake: reset, flush, status request, start receiver" do
    pid = ready()
    assert %{transceiver_type: 0x53} = Rfxtrx.status(pid)
  end

  test "commands wait until the receiver is started" do
    pid = start()
    assert_receive {:uart_write, _reset}
    assert_receive {:uart_write, <<0x0D, 0, 0, 1, 2, _::binary>>}
    task = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) end)
    send(pid, {:circuits_uart, "fake", @status})
    assert_receive {:uart_write, <<0x0D, 0, 0, 2, 7, _::binary>>}
    refute_receive {:uart_write, <<0x09, _::binary>>}, 30
    send(pid, {:circuits_uart, "fake", @started})
    assert_receive {:uart_write, <<0x09, 0x19, 0x07, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x00>>})
    assert Task.await(task) == :ok
  end

  test "firmware that does not understand start is ready after status" do
    pid = start()
    assert_receive {:uart_write, <<0x0D, 0, 0, 1, 2, _::binary>>}
    send(pid, {:circuits_uart, "fake", @status})
    assert_receive {:uart_write, <<0x0D, 0, 0, 2, 7, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x14, 0x01, 0xFF, 2, 0x07, 0::8*16>>})
    task = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) end)
    assert_receive {:uart_write, <<0x09, _, _, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x00>>})
    assert Task.await(task) == :ok
  end

  test "command waits for the ACK with its sequence number" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 0x0A1B2C3, 1, :open) end)
    assert_receive {:uart_write, <<0x09, 0x19, 0x07, seq, 0x0A, 0x1B, 0x2C, 0x31, 0x00, 0x00>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq + 1, 0x00>>})
    refute Task.yield(task, 20)
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x00>>})
    assert Task.await(task) == :ok
  end

  test "commands are serialised" do
    pid = ready()
    t1 = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) end)
    t2 = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 2, :close) end)
    assert_receive {:uart_write, <<_, _, _, seq1, _::binary-size(4), cmd1, _>>}
    refute_receive {:uart_write, _}, 20
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq1, 0x00>>})
    assert_receive {:uart_write, <<_, _, _, seq2, _::binary-size(4), cmd2, _>>}
    assert seq2 == seq1 + 1
    assert MapSet.new([cmd1, cmd2]) == MapSet.new([0, 1])
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq2, 0x00>>})
    assert Task.await(t1) == :ok
    assert Task.await(t2) == :ok
  end

  test "ACK split over two reads" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) end)
    assert_receive {:uart_write, <<_, _, _, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02>>})
    send(pid, {:circuits_uart, "fake", <<0x01, seq, 0x00>>})
    assert Task.await(task) == :ok
  end

  test "NAK and timeout are errors" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) end)
    assert_receive {:uart_write, <<_, _, _, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x02>>})
    assert Task.await(task) == {:error, :nak}

    task = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) end)
    assert_receive {:uart_write, _}
    assert Task.await(task) == {:error, :timeout}
  end

  test "port error disconnects, fails pending calls and reconnects" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) end)
    assert_receive {:uart_write, _}
    send(pid, {:circuits_uart, "fake", {:error, :eio}})
    assert Task.await(task) == {:error, :disconnected}
    assert Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) == {:error, :disconnected}
  end

  test "rfy command, and an unknown rfy remote is an error" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, :rfy, 0x012345, 1, :up) end)
    assert_receive {:uart_write, <<0x0C, 0x1A, 0x00, seq, 0x01, 0x23, 0x45, 1, 0x01, 0::32>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x00>>})
    assert Task.await(task) == :ok

    task = Task.async(fn -> Rfxtrx.send_command(pid, :rfy, 0x054321, 2, :down) end)
    assert_receive {:uart_write, <<0x0C, 0x1A, 0x00, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x14, 0x01, 0x01, seq, 0x00, 0::8*16>>})
    assert Task.await(task) == {:error, :unknown_rfy_remote}
  end

  test "readiness changes are announced, and a finished handshake does not time out" do
    pid = ready(handshake_timeout_ms: 20)
    assert_receive :ready_change, 100, "announces itself at start"
    assert_receive :ready_change, 100, "ready"
    assert Rfxtrx.ready?(pid)
    refute_receive :ready_change, 40
    assert Rfxtrx.ready?(pid)

    send(pid, {:circuits_uart, "fake", {:error, :eio}})
    assert_receive :ready_change
    refute Rfxtrx.ready?(pid)
  end

  test "a restart after a crash announces itself, replacing a stale ready" do
    pid = ready()
    assert_receive :ready_change
    assert_receive :ready_change
    Process.exit(pid, :kill)
    assert_receive :ready_change
  end

  test "a server that is down is not ready" do
    refute Rfxtrx.ready?(:no_such_rfxtrx)
  end

  test "a handshake without an answer is abandoned and retried, without settling" do
    reset = Packet.reset()
    pid = start(handshake_timeout_ms: 30, reconnect_ms: 10, settle_ms: 5_000)
    assert_receive :ready_change
    assert_receive {:uart_write, ^reset}
    assert_receive {:uart_write, <<0x0D, 0, 0, _, 2, _::binary>>}
    assert_receive {:uart_write, ^reset}, 200
    refute Rfxtrx.ready?(pid)
    refute_received :ready_change
  end

  test "a port lost through an error is left to boot before it is reopened" do
    reset = Packet.reset()
    pid = ready(reconnect_ms: 10, settle_ms: 100)
    send(pid, {:circuits_uart, "fake", {:error, :eio}})
    send(pid, {:circuits_uart, "fake", {:error, :eio}})
    refute_receive {:uart_write, ^reset}, 80
    assert_receive {:uart_write, ^reset}, 200
    refute_receive {:uart_write, ^reset}, 150
  end

  test "a port that appears is left to boot before it is opened" do
    port = Path.join(System.tmp_dir!(), "rfxtrx-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(port) end)
    start(port: port, reconnect_ms: 10, settle_ms: 100)
    refute_receive {:uart_write, _}, 30
    File.touch!(port)
    refute_receive {:uart_write, _}, 60
    assert_receive {:uart_write, reset}, 200
    assert reset == Packet.reset()
  end

  test "missing port keeps retrying without crashing" do
    pid = start(port: "/nonexistent/*", reconnect_ms: 10)
    refute_receive {:uart_write, _}, 30
    assert Process.alive?(pid)
    assert Rfxtrx.send_command(pid, :blinds_t7, 1, 1, :open) == {:error, :disconnected}
  end
end
