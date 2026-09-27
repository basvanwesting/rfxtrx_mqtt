defmodule RfxtrxMqtt.DevicesTest do
  use ExUnit.Case, async: true
  doctest RfxtrxMqtt.Devices
  alias RfxtrxMqtt.Devices

  test "parses both protocols with per-device travel time" do
    devices =
      Devices.parse!(~s({
        "woonkamer": {"protocol": "blinds_t7", "id": "0x0A1B2C3", "unit": 1, "travel_ms": 25000},
        "markiezen": {"protocol": "rfy", "id": "0X012345", "unit": 0}
      }))

    assert %{protocol: :blinds_t7, id: 0x0A1B2C3, unit: 1, travel_ms: 25000} =
             devices["woonkamer"]

    assert %{protocol: :rfy, id: 0x012345, unit: 0, travel_ms: 20000} = devices["markiezen"]
  end

  test "rejects bad devices with a message naming the device" do
    for {json, message} <- [
          {~s({"x": {"protocol": "rts", "id": "0x1", "unit": 1}}), "x: unknown protocol"},
          {~s({"x": {"protocol": "rfy", "id": "0x100000", "unit": 1}}), "x: id out of range"},
          {~s({"x": {"protocol": "rfy", "id": "0x1", "unit": 5}}), "x: unit 5 out of range"},
          {~s({"x": {"protocol": "blinds_t7", "id": 12, "unit": 1}}),
           "x: id must be a hex string"},
          {~s({"x": {"protocol": "rfy", "unit": 1}}), "x: protocol, id and unit are required"}
        ] do
      error = assert_raise ArgumentError, fn -> Devices.parse!(json) end
      assert error.message =~ message
    end
  end
end
