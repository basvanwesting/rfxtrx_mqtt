import Config

# FOREST_SHUTTLE_ROOMS="woonkamer=0x0A1B2C3/1,slaapkamer=0x0A1B2C3/2"
if rooms = System.get_env("FOREST_SHUTTLE_ROOMS") do
  config :forest_shuttle, rooms: ForestShuttle.Config.parse_rooms!(rooms)
end

if travel = System.get_env("FOREST_SHUTTLE_TRAVEL_MS") do
  config :forest_shuttle, travel_ms: String.to_integer(travel)
end

if port = System.get_env("RFXTRX_PORT") do
  config :forest_shuttle, rfxtrx_port: port
end

config :forest_shuttle,
  mqtt: [
    host: System.get_env("MQTT_HOST", "localhost"),
    port: String.to_integer(System.get_env("MQTT_PORT", "1883")),
    user_name: System.get_env("MQTT_USER"),
    password: System.get_env("MQTT_PASSWORD")
  ]
