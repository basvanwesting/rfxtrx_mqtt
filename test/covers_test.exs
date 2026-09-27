defmodule RfxtrxMqtt.CoversTest do
  use ExUnit.Case, async: true
  alias RfxtrxMqtt.Covers
  alias RfxtrxMqtt.Devices.Device

  @devices %{
    "woonkamer" => %Device{
      name: "woonkamer",
      protocol: :blinds_t7,
      id: 0x0A1B2C3,
      unit: 1,
      travel_ms: 30
    },
    "markiezen" => %Device{
      name: "markiezen",
      protocol: :rfy,
      id: 0x012345,
      unit: 1,
      travel_ms: 30
    }
  }

  defp start(opts \\ []) do
    me = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          devices: @devices,
          topic_prefix: "fs",
          transmit: fn protocol, id, unit, cmd ->
            send(me, {:tx, protocol, id, unit, cmd})
            :ok
          end,
          publish: fn topic, payload -> send(me, {:pub, topic, payload}) end
        ],
        opts
      )

    start_supervised!({Covers, opts})
  end

  test "open transmits, publishes motion, then arrival" do
    pid = start()
    assert Covers.command(pid, "woonkamer", :open) == :ok
    assert_receive {:tx, :blinds_t7, 0x0A1B2C3, 1, :open}
    assert_receive {:pub, "fs/woonkamer/target_position", "100"}
    assert_receive {:pub, "fs/woonkamer/position_state", "INCREASING"}
    assert Covers.status(pid)["woonkamer"] == %{position: nil, state: :opening}
    assert_receive {:pub, "fs/woonkamer/current_position", "100"}, 200
    assert_receive {:pub, "fs/woonkamer/position_state", "STOPPED"}
    assert Covers.status(pid)["woonkamer"] == %{position: 100, state: :stopped}
  end

  test "cover commands map to each protocol's own commands" do
    pid = start()

    for {cmd, t7, rfy} <- [{:open, :open, :up}, {:close, :close, :down}, {:stop, :stop, :stop}] do
      :ok = Covers.command(pid, "woonkamer", cmd)
      :ok = Covers.command(pid, "markiezen", cmd)
      assert_receive {:tx, :blinds_t7, _, _, ^t7}
      assert_receive {:tx, :rfy, 0x012345, 1, ^rfy}
    end
  end

  test "pair sends the protocol's pairing command and leaves state alone" do
    pid = start()
    assert Covers.pair(pid, "woonkamer") == :ok
    assert_receive {:tx, :blinds_t7, _, _, :confirm}
    assert Covers.pair(pid, "markiezen") == :ok
    assert_receive {:tx, :rfy, _, _, :program}
    refute_receive {:pub, _, _}
    assert Covers.pair(pid, "zolder") == {:error, :unknown_device}
  end

  test "target position maps to open or close" do
    pid = start()
    assert Covers.set_target(pid, "woonkamer", 0) == :ok
    assert_receive {:tx, _, _, _, :close}
    assert_receive {:pub, "fs/woonkamer/target_position", "0"}
    assert_receive {:pub, "fs/woonkamer/position_state", "DECREASING"}
    assert Covers.set_target(pid, "woonkamer", 51) == :ok
    assert_receive {:tx, _, _, _, :open}
  end

  test "travel time is per device" do
    devices = put_in(@devices["markiezen"].travel_ms, 150)
    pid = start(devices: devices)
    :ok = Covers.command(pid, "woonkamer", :open)
    :ok = Covers.command(pid, "markiezen", :open)
    assert_receive {:pub, "fs/woonkamer/current_position", "100"}, 100
    refute_received {:pub, "fs/markiezen/current_position", _}
    assert_receive {:pub, "fs/markiezen/current_position", "100"}, 300
  end

  test "stop mid-travel lands on 50 and cancels arrival" do
    pid = start()
    :ok = Covers.command(pid, "woonkamer", :open)
    :ok = Covers.command(pid, "woonkamer", :stop)
    assert_receive {:tx, _, _, _, :stop}
    assert_receive {:pub, "fs/woonkamer/position_state", "STOPPED"}
    assert_receive {:pub, "fs/woonkamer/current_position", "50"}
    refute_receive {:pub, "fs/woonkamer/current_position", "100"}, 60
  end

  test "stop while stopped keeps position" do
    pid = start()
    Covers.hydrate(pid, "woonkamer", 100)
    :ok = Covers.command(pid, "woonkamer", :stop)
    assert_receive {:pub, "fs/woonkamer/current_position", "100"}
  end

  test "transmit failure leaves state untouched" do
    pid = start(transmit: fn _, _, _, _ -> {:error, :disconnected} end)
    assert Covers.command(pid, "woonkamer", :open) == {:error, :disconnected}
    refute_receive {:pub, _, _}
    assert Covers.status(pid)["woonkamer"] == %{position: nil, state: :stopped}
  end

  test "hydrate only fills an unknown position" do
    pid = start()
    Covers.hydrate(pid, "woonkamer", 0)
    Covers.hydrate(pid, "woonkamer", 100)
    assert Covers.status(pid)["woonkamer"].position == 0
  end

  test "unknown device" do
    assert Covers.command(start(), "zolder", :open) == {:error, :unknown_device}
  end
end
