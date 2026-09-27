import Config

config :forest_shuttle,
  start_children: true,
  topic_prefix: "forest_shuttle",
  # room => %{id: 28-bit Forest id, unit: 0..15 (0 = all units of that id)}
  rooms: %{},
  travel_ms: 20_000,
  rfxtrx_port: "/dev/serial/by-id/usb-RFXCOM_RFXtrx433XL_*",
  mqtt: [host: "localhost", port: 1883]

import_config "#{config_env()}.exs"
