import Config

if file = System.get_env("RFXTRX_MQTT_DEVICES") do
  config :rfxtrx_mqtt, devices_file: file
end

if port = System.get_env("RFXTRX_PORT") do
  config :rfxtrx_mqtt, rfxtrx_port: port
end

config :rfxtrx_mqtt,
  mqtt: [
    host: System.get_env("MQTT_HOST", "localhost"),
    port: String.to_integer(System.get_env("MQTT_PORT", "1883")),
    user_name: System.get_env("MQTT_USER"),
    password: System.get_env("MQTT_PASSWORD")
  ]
