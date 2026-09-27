defmodule ForestShuttle.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:forest_shuttle, :start_children),
        do: [ForestShuttle.Rfxtrx, ForestShuttle.Curtains, ForestShuttle.Mqtt],
        else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: ForestShuttle.Supervisor)
  end
end
