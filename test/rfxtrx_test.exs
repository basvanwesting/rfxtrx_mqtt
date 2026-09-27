defmodule ForestShuttle.RfxtrxTest do
  use ExUnit.Case, async: true
  alias ForestShuttle.{FakeUART, Rfxtrx}
  alias ForestShuttle.Rfxtrx.Packet

  @status <<0x14, 0x01, 0x00, 1, 0x02, 0x53, 0xF2, 0::8*14>>
  @started <<0x14, 0x01, 0x07, 2, 0x07, "Copyright RFXCOM">>

  defp start(opts \\ []) do
    opts =
      Keyword.merge(
        [
          name: nil,
          uart: {FakeUART, owner: self()},
          port: "/dev/null",
          reset_delay_ms: 10,
          ack_timeout_ms: 50
        ],
        opts
      )

    start_supervised!({Rfxtrx, opts})
  end

  defp ready do
    pid = start()
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
    task = Task.async(fn -> Rfxtrx.send_command(pid, 1, 1, :open) end)
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
    task = Task.async(fn -> Rfxtrx.send_command(pid, 1, 1, :open) end)
    assert_receive {:uart_write, <<0x09, _, _, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x00>>})
    assert Task.await(task) == :ok
  end

  test "command waits for the ACK with its sequence number" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, 0x0A1B2C3, 1, :open) end)
    assert_receive {:uart_write, <<0x09, 0x19, 0x07, seq, 0x0A, 0x1B, 0x2C, 0x31, 0x00, 0x00>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq + 1, 0x00>>})
    refute Task.yield(task, 20)
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x00>>})
    assert Task.await(task) == :ok
  end

  test "commands are serialised" do
    pid = ready()
    t1 = Task.async(fn -> Rfxtrx.send_command(pid, 1, 1, :open) end)
    t2 = Task.async(fn -> Rfxtrx.send_command(pid, 1, 2, :close) end)
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
    task = Task.async(fn -> Rfxtrx.send_command(pid, 1, 1, :open) end)
    assert_receive {:uart_write, <<_, _, _, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02>>})
    send(pid, {:circuits_uart, "fake", <<0x01, seq, 0x00>>})
    assert Task.await(task) == :ok
  end

  test "NAK and timeout are errors" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, 1, 1, :open) end)
    assert_receive {:uart_write, <<_, _, _, seq, _::binary>>}
    send(pid, {:circuits_uart, "fake", <<0x04, 0x02, 0x01, seq, 0x02>>})
    assert Task.await(task) == {:error, :nak}

    task = Task.async(fn -> Rfxtrx.send_command(pid, 1, 1, :open) end)
    assert_receive {:uart_write, _}
    assert Task.await(task) == {:error, :timeout}
  end

  test "port error disconnects, fails pending calls and reconnects" do
    pid = ready()
    task = Task.async(fn -> Rfxtrx.send_command(pid, 1, 1, :open) end)
    assert_receive {:uart_write, _}
    send(pid, {:circuits_uart, "fake", {:error, :eio}})
    assert Task.await(task) == {:error, :disconnected}
    assert Rfxtrx.send_command(pid, 1, 1, :open) == {:error, :disconnected}
  end

  test "missing port keeps retrying without crashing" do
    pid = start(port: "/nonexistent/*", reconnect_ms: 10)
    refute_receive {:uart_write, _}, 30
    assert Process.alive?(pid)
    assert Rfxtrx.send_command(pid, 1, 1, :open) == {:error, :disconnected}
  end
end
