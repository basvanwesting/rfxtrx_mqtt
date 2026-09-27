defmodule RfxtrxMqtt do
  @moduledoc """
  Covers driven by an RFXCOM RFXtrx433XL, exposed over MQTT.

  Convenience API for the remote shell (`bin/rfxtrx_mqtt remote`):

      RfxtrxMqtt.status()
      RfxtrxMqtt.open("woonkamer")
      RfxtrxMqtt.close("woonkamer")
      RfxtrxMqtt.stop("woonkamer")
      RfxtrxMqtt.pair("markiezen")
  """

  alias RfxtrxMqtt.Covers

  defdelegate status(), to: Covers
  def open(device), do: Covers.command(device, :open)
  def close(device), do: Covers.command(device, :close)
  def stop(device), do: Covers.command(device, :stop)

  @doc """
  Registers the RFXtrx as an extra remote for a device from the devices file.
  First put the motor in learn mode: Forest per its manual, Somfy RTS by
  holding PROG on an original remote until the motor jogs. A successful pair
  makes the motor jog again.
  """
  def pair(device), do: Covers.pair(device)
end
