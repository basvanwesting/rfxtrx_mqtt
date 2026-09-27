defmodule ForestShuttle.Rfxtrx.PacketTest do
  use ExUnit.Case, async: true
  alias ForestShuttle.Rfxtrx.Packet

  test "interface control packets are 14 bytes" do
    assert Packet.reset() == <<0x0D, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
    assert Packet.status_request(7) == <<0x0D, 0, 0, 7, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
  end

  test "blinds1 T7 packs 28-bit id and unit into four bytes" do
    assert Packet.blinds1(0x0A1B2C3, 1, :open, 5) ==
             <<0x09, 0x19, 0x07, 5, 0x0A, 0x1B, 0x2C, 0x31, 0x00, 0x00>>

    assert Packet.blinds1(0x0A1B2C3, 15, :close, 5) ==
             <<0x09, 0x19, 0x07, 5, 0x0A, 0x1B, 0x2C, 0x3F, 0x01, 0x00>>

    assert <<_::8*8, 0x02, 0>> = Packet.blinds1(1, 0, :stop, 0)
    assert <<_::8*8, 0x03, 0>> = Packet.blinds1(1, 0, :confirm, 0)
  end

  test "blinds1 rejects out of range ids and units" do
    assert_raise FunctionClauseError, fn -> Packet.blinds1(0x10000000, 1, :open, 0) end
    assert_raise FunctionClauseError, fn -> Packet.blinds1(1, 16, :open, 0) end
  end

  test "split returns complete frames and the partial tail" do
    ack = <<0x04, 0x02, 0x01, 9, 0x00>>
    assert Packet.split(ack <> ack <> <<0x04, 0x02>>) == {[ack, ack], <<0x04, 0x02>>}
    assert Packet.split(<<>>) == {[], <<>>}
    assert Packet.split(<<0, 0, ack::binary>>) == {[ack], <<>>}, "skips stray zero bytes"
  end

  test "decode" do
    assert Packet.decode(<<0x04, 0x02, 0x01, 9, 0x00>>) == {:ack, 9, :ok}
    assert Packet.decode(<<0x04, 0x02, 0x01, 9, 0x01>>) == {:ack, 9, :ok_delayed}
    assert Packet.decode(<<0x04, 0x02, 0x01, 9, 0x02>>) == {:ack, 9, :nak}

    assert {:status, 3, %{transceiver_type: 0x53, firmware: 0xF2}} =
             Packet.decode(<<0x14, 0x01, 0x00, 3, 0x02, 0x53, 0xF2, 0::8*14>>)

    assert {:unknown, 0x20, 0, 1, <<1, 2>>} = Packet.decode(<<0x05, 0x20, 0, 1, 1, 2>>)
  end

  test "next_seq wraps" do
    assert Packet.next_seq(0) == 1
    assert Packet.next_seq(255) == 0
  end
end
