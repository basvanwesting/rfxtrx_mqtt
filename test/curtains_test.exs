defmodule ForestShuttle.CurtainsTest do
  use ExUnit.Case, async: true
  alias ForestShuttle.Curtains

  @rooms %{"woonkamer" => %{id: 0x0A1B2C3, unit: 1}}

  defp start(opts \\ []) do
    me = self()

    opts =
      Keyword.merge(
        [
          name: nil,
          rooms: @rooms,
          travel_ms: 30,
          topic_prefix: "fs",
          transmit: fn id, unit, cmd ->
            send(me, {:tx, id, unit, cmd})
            :ok
          end,
          publish: fn topic, payload -> send(me, {:pub, topic, payload}) end
        ],
        opts
      )

    start_supervised!({Curtains, opts})
  end

  test "open transmits, publishes motion, then arrival" do
    pid = start()
    assert Curtains.command(pid, "woonkamer", :open) == :ok
    assert_receive {:tx, 0x0A1B2C3, 1, :open}
    assert_receive {:pub, "fs/woonkamer/target_position", "100"}
    assert_receive {:pub, "fs/woonkamer/position_state", "INCREASING"}
    assert Curtains.status(pid)["woonkamer"] == %{position: nil, state: :opening}
    assert_receive {:pub, "fs/woonkamer/current_position", "100"}, 200
    assert_receive {:pub, "fs/woonkamer/position_state", "STOPPED"}
    assert Curtains.status(pid)["woonkamer"] == %{position: 100, state: :stopped}
  end

  test "target position maps to open or close" do
    pid = start()
    assert Curtains.set_target(pid, "woonkamer", 0) == :ok
    assert_receive {:tx, _, _, :close}
    assert_receive {:pub, "fs/woonkamer/target_position", "0"}
    assert_receive {:pub, "fs/woonkamer/position_state", "DECREASING"}
    assert Curtains.set_target(pid, "woonkamer", 51) == :ok
    assert_receive {:tx, _, _, :open}
  end

  test "stop mid-travel lands on 50 and cancels arrival" do
    pid = start()
    :ok = Curtains.command(pid, "woonkamer", :open)
    :ok = Curtains.command(pid, "woonkamer", :stop)
    assert_receive {:tx, _, _, :stop}
    assert_receive {:pub, "fs/woonkamer/position_state", "STOPPED"}
    assert_receive {:pub, "fs/woonkamer/current_position", "50"}
    refute_receive {:pub, "fs/woonkamer/current_position", "100"}, 60
  end

  test "stop while stopped keeps position" do
    pid = start()
    Curtains.hydrate(pid, "woonkamer", 100)
    :ok = Curtains.command(pid, "woonkamer", :stop)
    assert_receive {:pub, "fs/woonkamer/current_position", "100"}
  end

  test "transmit failure leaves state untouched" do
    pid = start(transmit: fn _, _, _ -> {:error, :disconnected} end)
    assert Curtains.command(pid, "woonkamer", :open) == {:error, :disconnected}
    refute_receive {:pub, _, _}
    assert Curtains.status(pid)["woonkamer"] == %{position: nil, state: :stopped}
  end

  test "hydrate only fills an unknown position" do
    pid = start()
    Curtains.hydrate(pid, "woonkamer", 0)
    Curtains.hydrate(pid, "woonkamer", 100)
    assert Curtains.status(pid)["woonkamer"].position == 0
  end

  test "unknown room" do
    assert Curtains.command(start(), "zolder", :open) == {:error, :unknown_room}
  end
end
