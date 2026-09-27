defmodule RfxtrxMqtt.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.fetch_env!(:rfxtrx_mqtt, :start_children),
        do: [RfxtrxMqtt.Rfxtrx, RfxtrxMqtt.Covers, RfxtrxMqtt.Mqtt],
        else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: RfxtrxMqtt.Supervisor)
  end
end
