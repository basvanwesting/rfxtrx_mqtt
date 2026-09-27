defmodule RfxtrxMqtt.Devices do
  @moduledoc """
  The device list, read from a JSON file at startup.

      {
        "woonkamer": {"protocol": "blinds_t7", "id": "0x0A1B2C3", "unit": 1, "travel_ms": 20000},
        "markiezen": {"protocol": "rfy", "id": "0x012345", "unit": 1, "travel_ms": 30000}
      }

  Ids are made up once, then paired into the motor (`RfxtrxMqtt.pair/1`):
  the RFXtrx is an extra remote, it never copies the original one.
  """

  defmodule Device do
    @moduledoc false
    @enforce_keys [:name, :protocol, :id, :unit, :travel_ms]
    defstruct @enforce_keys
  end

  # protocol => {id range, unit range}
  @protocols %{
    "blinds_t7" => {:blinds_t7, 1..0x0FFFFFFF, 0..15},
    "rfy" => {:rfy, 1..0x0FFFFF, 0..4}
  }

  @default_travel_ms 20_000

  @doc "Reads and validates the devices file; raises on any error."
  def load!(path), do: path |> Path.expand() |> File.read!() |> parse!()

  @doc ~S"""
      iex> RfxtrxMqtt.Devices.parse!(~s({"w": {"protocol": "blinds_t7", "id": "0x0A1B2C3", "unit": 1}}))
      %{"w" => %RfxtrxMqtt.Devices.Device{name: "w", protocol: :blinds_t7, id: 0x0A1B2C3, unit: 1, travel_ms: 20000}}
  """
  def parse!(json) do
    json
    |> JSON.decode!()
    |> Map.new(fn {name, spec} -> {name, device!(name, spec)} end)
  end

  defp device!(name, %{"protocol" => protocol, "id" => id, "unit" => unit} = spec) do
    {atom, ids, units} =
      Map.get(@protocols, protocol) ||
        raise ArgumentError, "#{name}: unknown protocol #{inspect(protocol)}"

    id = parse_id!(name, id)
    unless id in ids, do: raise(ArgumentError, "#{name}: id out of range for #{protocol}")

    unless unit in units,
      do: raise(ArgumentError, "#{name}: unit #{unit} out of range for #{protocol}")

    %Device{
      name: name,
      protocol: atom,
      id: id,
      unit: unit,
      travel_ms: Map.get(spec, "travel_ms", @default_travel_ms)
    }
  end

  defp device!(name, _spec),
    do: raise(ArgumentError, "#{name}: protocol, id and unit are required")

  defp parse_id!(_name, "0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_id!(_name, "0X" <> hex), do: String.to_integer(hex, 16)

  defp parse_id!(name, other),
    do:
      raise(
        ArgumentError,
        "#{name}: id must be a hex string like \"0x1A2B\", got #{inspect(other)}"
      )
end
