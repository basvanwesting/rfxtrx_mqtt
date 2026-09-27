defmodule ForestShuttle.Config do
  @moduledoc "Parsing of runtime configuration."

  @doc ~S"""
  Parses `"room=0xID/unit,room2=0xID/unit"` into the rooms map.

      iex> ForestShuttle.Config.parse_rooms!("woonkamer=0x0A1B2C3/1, slaapkamer=0xA1B2C3/2")
      %{"woonkamer" => %{id: 0x0A1B2C3, unit: 1}, "slaapkamer" => %{id: 0xA1B2C3, unit: 2}}
  """
  def parse_rooms!(spec) when is_binary(spec) do
    spec
    |> String.split(",", trim: true)
    |> Map.new(fn entry ->
      [room, device] = entry |> String.trim() |> String.split("=", parts: 2)
      [id, unit] = String.split(device, "/", parts: 2)
      {room, %{id: parse_id!(id), unit: String.to_integer(unit)}}
    end)
  end

  defp parse_id!("0x" <> hex), do: parse_id!(hex)
  defp parse_id!("0X" <> hex), do: parse_id!(hex)
  defp parse_id!(hex), do: String.to_integer(hex, 16)
end
