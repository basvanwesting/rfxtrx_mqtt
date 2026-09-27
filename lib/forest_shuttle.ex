defmodule ForestShuttle do
  @moduledoc """
  Forest Shuttle curtain motors via RFXtrx433XL, exposed over MQTT.

  Convenience API for the shell:

      ForestShuttle.open("woonkamer")
      ForestShuttle.close("woonkamer")
      ForestShuttle.stop("woonkamer")
      ForestShuttle.status()
  """

  alias ForestShuttle.Curtains

  defdelegate status(), to: Curtains
  def open(room), do: Curtains.command(room, :open)
  def close(room), do: Curtains.command(room, :close)
  def stop(room), do: Curtains.command(room, :stop)

  @doc """
  Pairing: put the motor in learn mode, then send confirm for the id/unit you
  chose. The id is any 28-bit number you make up; write it down.
  """
  def pair(id, unit), do: ForestShuttle.Rfxtrx.send_command(id, unit, :confirm)
end
