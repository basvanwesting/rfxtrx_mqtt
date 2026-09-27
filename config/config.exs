import Config

config :rfxtrx_mqtt,
  start_children: true,
  topic_prefix: "rfxtrx",
  devices_file: "~/.config/rfxtrx_mqtt/devices.json",
  rfxtrx_port: "/dev/serial/by-id/usb-RFXCOM_RFXtrx433XL_*",
  mqtt: [host: "localhost", port: 1883]

import_config "#{config_env()}.exs"
