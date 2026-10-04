defmodule RfxtrxMqtt.Mqtt.HandlerTest do
  use ExUnit.Case, async: true
  alias RfxtrxMqtt.{Covers, Mqtt.Handler}
  alias RfxtrxMqtt.Devices.Device

  # The handler calls the globally named Covers; start one with a fake transmitter.
  setup do
    me = self()

    start_supervised!(
      {Covers,
       devices: %{
         "woonkamer" => %Device{
           name: "woonkamer",
           protocol: :blinds_t7,
           id: 1,
           unit: 1,
           travel_ms: 10_000
         }
       },
       topic_prefix: "fs",
       transmit: fn _, _, _, cmd ->
         send(me, {:tx, cmd})
         :ok
       end,
       ready?: fn -> true end,
       publish: fn topic, payload -> send(me, {:pub, topic, payload}) end}
    )

    {:ok, state} = Handler.init(prefix: "fs")
    %{state: state}
  end

  test "a new connection republishes availability", %{state: state} do
    assert {:ok, _} = Handler.connection(:up, state)
    assert_receive {:pub, "fs/status", "online"}
  end

  test "set and target_position/set are commands", %{state: state} do
    assert {:ok, _} = Handler.handle_message(["fs", "woonkamer", "set"], "CLOSE", state)
    assert_receive {:tx, :close}

    assert {:ok, _} =
             Handler.handle_message(["fs", "woonkamer", "target_position", "set"], "100", state)

    assert_receive {:tx, :open}
  end

  test "published state topics are not commands (no feedback loop)", %{state: state} do
    for topic <- ["target_position", "position_state"] do
      assert {:ok, _} = Handler.handle_message(["fs", "woonkamer", topic], "100", state)
    end

    assert {:ok, _} =
             Handler.handle_message(["fs", "woonkamer", "current_position"], "100", state)

    refute_receive {:tx, _}
    assert Covers.status()["woonkamer"].position == 100, "current_position only hydrates"
  end

  test "bad payloads are ignored", %{state: state} do
    assert {:ok, _} = Handler.handle_message(["fs", "woonkamer", "set"], "HALF", state)

    assert {:ok, _} =
             Handler.handle_message(["fs", "woonkamer", "target_position", "set"], "abc", state)

    assert {:ok, _} =
             Handler.handle_message(["fs", "woonkamer", "target_position", "set"], "101", state)

    refute_receive {:tx, _}
  end
end
