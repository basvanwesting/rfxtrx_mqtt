defmodule ForestShuttle.Rfxtrx.Packet do
  @moduledoc """
  Encoding and decoding of RFXtrx frames.

  Wire format: `<<length_of_rest, packet_type, subtype, seqnbr, payload::binary>>`.
  Only what the Forest Shuttle needs: interface control (0x00), interface
  response (0x01), transmitter response (0x02) and Blinds1 (0x19).
  """

  import Bitwise

  @interface_control 0x00
  @interface_response 0x01
  @transmitter_response 0x02
  @blinds1 0x19
  @blinds_t7_forest 0x07

  @commands %{open: 0x00, close: 0x01, stop: 0x02, confirm: 0x03}

  @type command :: :open | :close | :stop | :confirm

  @doc "Interface control: reset. The device answers nothing; wait 300 ms and flush."
  def reset(seq \\ 0), do: <<0x0D, @interface_control, 0x00, seq, 0x00, 0::72>>

  @doc "Interface control: get status. Answered by an interface response (type 0x01)."
  def status_request(seq), do: <<0x0D, @interface_control, 0x00, seq, 0x02, 0::72>>

  @doc """
  Interface control: start receiver. Puts the device in operating mode; until
  then it ACKs transmit commands without sending them. Answered by an
  interface response with subtype 0x07 carrying "Copyright RFXCOM".
  """
  def start_receiver(seq), do: <<0x0D, @interface_control, 0x00, seq, 0x07, 0::72>>

  @doc """
  Blinds1 subtype T7 (Forest). The 28-bit id and the 4-bit unit code share
  four bytes: `<<id::28, unit::4>>`. Unit 0 addresses all units of the id.
  """
  def blinds1(id, unit, command, seq, subtype \\ @blinds_t7_forest)
      when id in 0..0x0FFFFFFF and unit in 0..15 and seq in 0..255 do
    <<0x09, @blinds1, subtype, seq, id::28, unit::4, Map.fetch!(@commands, command), 0x00>>
  end

  @doc "Splits a receive buffer into complete frames; returns the unparsed tail."
  @spec split(binary()) :: {[binary()], binary()}
  def split(buffer), do: split(buffer, [])

  # A zero length byte cannot start a frame: skip it to resynchronise.
  defp split(<<0, rest::binary>>, acc), do: split(rest, acc)

  defp split(<<len, body::binary-size(len), rest::binary>>, acc),
    do: split(rest, [<<len, body::binary>> | acc])

  defp split(rest, acc), do: {Enum.reverse(acc), rest}

  @doc "Decodes one complete frame."
  def decode(<<0x04, @transmitter_response, 0x01, seq, code>>),
    do: {:ack, seq, ack_code(code)}

  def decode(<<_len, @interface_response, 0x07, seq, _cmnd, text::binary-size(16), _::binary>>),
    do: {:started, seq, text}

  def decode(<<_len, @interface_response, 0xFF, seq, _rest::binary>>),
    do: {:not_understood, seq}

  def decode(<<_len, @interface_response, 0x00, seq, _cmnd, type, fw, rest::binary>>),
    do: {:status, seq, %{transceiver_type: type, firmware: fw, raw: rest}}

  def decode(<<_len, type, subtype, seq, payload::binary>>),
    do: {:unknown, type, subtype, seq, payload}

  defp ack_code(0x00), do: :ok
  defp ack_code(0x01), do: :ok_delayed
  defp ack_code(0x02), do: :nak
  defp ack_code(0x03), do: :nak_invalid_ac_address
  defp ack_code(other), do: {:unknown, other}

  @doc "Next sequence number, wrapping at 255."
  def next_seq(seq), do: seq + 1 &&& 0xFF
end
