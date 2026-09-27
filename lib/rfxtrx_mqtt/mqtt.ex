defmodule RfxtrxMqtt.Mqtt do
  @moduledoc "MQTT connection (Tortoise311) and the handler routing messages to Covers."

  require Logger

  @client_id "rfxtrx_mqtt"

  def child_spec(_opts) do
    mqtt = Application.fetch_env!(:rfxtrx_mqtt, :mqtt)
    prefix = Application.fetch_env!(:rfxtrx_mqtt, :topic_prefix)

    opts =
      [
        client_id: @client_id,
        server: {Tortoise311.Transport.Tcp, host: to_charlist(mqtt[:host]), port: mqtt[:port]},
        handler: {__MODULE__.Handler, prefix: prefix},
        subscriptions: [
          {"#{prefix}/+/set", 0},
          {"#{prefix}/+/target_position/set", 0},
          {"#{prefix}/+/current_position", 0}
        ],
        will: %Tortoise311.Package.Publish{
          topic: "#{prefix}/status",
          payload: "offline",
          retain: true
        }
      ]
      |> maybe_put(:user_name, mqtt[:user_name])
      |> maybe_put(:password, mqtt[:password])

    Tortoise311.Connection.child_spec(opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc "Publishes a retained message; fire and forget."
  def publish(topic, payload) do
    case Tortoise311.publish(@client_id, topic, payload, qos: 0, retain: true) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("mqtt: publish #{topic} failed: #{inspect(reason)}")
    end
  end

  defmodule Handler do
    @moduledoc false
    use Tortoise311.Handler
    require Logger
    alias RfxtrxMqtt.Covers

    @impl true
    def init(opts), do: {:ok, %{prefix: Keyword.fetch!(opts, :prefix)}}

    @impl true
    def connection(:up, state) do
      Logger.info("mqtt: connected")
      RfxtrxMqtt.Mqtt.publish("#{state.prefix}/status", "online")
      {:ok, state}
    end

    def connection(:down, state) do
      Logger.warning("mqtt: connection down")
      {:ok, state}
    end

    @impl true
    def handle_message([prefix, device, "set"], payload, %{prefix: prefix} = state) do
      case Covers.parse_command(payload) do
        {:ok, cmd} -> log_result(device, cmd, Covers.command(device, cmd))
        {:error, reason} -> Logger.warning("mqtt: #{device}/set #{inspect(reason)}")
      end

      {:ok, state}
    end

    def handle_message(
          [prefix, device, "target_position", "set"],
          payload,
          %{prefix: prefix} = state
        ) do
      case Integer.parse(payload) do
        {target, ""} when target in 0..100 ->
          log_result(device, target, Covers.set_target(device, target))

        _ ->
          Logger.warning("mqtt: #{device}/target_position/set bad payload #{inspect(payload)}")
      end

      {:ok, state}
    end

    def handle_message([prefix, device, "current_position"], payload, %{prefix: prefix} = state) do
      case Integer.parse(payload) do
        {position, ""} -> Covers.hydrate(device, position)
        _ -> :ok
      end

      {:ok, state}
    end

    def handle_message(topic, _payload, state) do
      Logger.debug("mqtt: ignoring #{Enum.join(topic, "/")}")
      {:ok, state}
    end

    @impl true
    def subscription(status, topic, state) do
      Logger.debug("mqtt: subscription #{topic} #{inspect(status)}")
      {:ok, state}
    end

    @impl true
    def terminate(_reason, _state), do: :ok

    defp log_result(_device, _what, :ok), do: :ok

    defp log_result(device, what, {:error, reason}),
      do: Logger.warning("mqtt: #{device} #{inspect(what)} failed: #{inspect(reason)}")
  end
end
