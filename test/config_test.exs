defmodule ForestShuttle.ConfigTest do
  use ExUnit.Case, async: true
  doctest ForestShuttle.Config

  test "malformed spec raises" do
    assert_raise MatchError, fn -> ForestShuttle.Config.parse_rooms!("woonkamer") end
  end
end
