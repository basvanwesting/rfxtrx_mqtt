# rfxtrx_mqtt

Drives cover motors through an RFXCOM RFXtrx433XL and exposes them over MQTT,
for Homebridge (`homebridge-mqttthing`) or anything else that speaks MQTT.
Supported: Forest Shuttle curtains (Blinds1 T7) and Somfy RTS (RFY).
Somfy io-homecontrol is 868 MHz and out of reach. Formerly `forest_shuttle`,
which replaced the node `forest-shuttle-server`.

## Protocol

RFXtrx frames are `<<len, type, subtype, seq, payload>>`. On connect the
server sends reset (14 bytes), waits 300 ms, flushes, requests status, and
sends start receiver; the "Copyright RFXCOM" answer marks it ready. Without
the start the device ACKs transmit commands but sends nothing.

A port that was absent or lost is left alone for 10 s after it appears: a
freshly powered RFXtrx is in its bootloader for its first seconds, and serial
traffic in that window kept it there (LED steady red, no answer; seen with
firmware 1052, cured by a power cycle with the server stopped). A handshake
that is not ready within 5 s is dropped and retried, with a warning in the log.

| Protocol | Packet | Commands |
|---|---|---|
| `blinds_t7` (Forest) | `<<0x09, 0x19, 0x07, seq, id::28, unit::4, cmnd, 0>>` | 0 open, 1 close, 2 stop, 3 confirm (pair) |
| `rfy` (Somfy RTS) | `<<0x0C, 0x1A, 0x00, seq, id::24, unit, cmnd, 0::32>>` | 0 stop, 1 up, 3 down, 7 program (pair) |

Every command is answered by a transmitter response `<<0x04, 0x02, 0x01, seq,
code>>`, matched on `seq`; an RFY id never programmed into this RFXtrx is
answered by interface response subtype 0x01 instead. Commands are
serialised, one in flight. An ACK means the RFXtrx took the command, not that
a motor heard it.

Neither protocol can be received by this RFXtrx (Forest: transmit only per the
RFXCOM guide; Somfy: never implemented, deliberately). Position is emulated:
travel is assumed complete after the device's `travel_ms`; a stop mid-travel
reports 50. Use of the original remotes is not seen.

## Devices

`~/.config/rfxtrx_mqtt/devices.json`, see `deploy/devices.example.json`:

    {"<name>": {"protocol": "blinds_t7" | "rfy", "id": "0x...", "unit": n, "travel_ms": 20000}}

| Protocol | id | unit |
|---|---|---|
| `blinds_t7` | 1..0x0FFFFFFF (28 bit) | 0..15, 0 = all units of the id |
| `rfy` | 1..0x0FFFFF (20 bit) | 0..4 |

Ids are made up, then paired. The RFXtrx becomes an extra remote; it never
copies an original one (Somfy rolling codes would desync the original).

## Pairing

1. Put the motor in learn mode. Forest: per its manual. Somfy RTS: hold PROG
   on an original remote (paperclip) until the motor jogs.
2. `bin/rfxtrx_mqtt remote`, then `RfxtrxMqtt.pair("markiezen")`.
3. The motor jogs to confirm. For RFY the RFXtrx now stores the rolling code
   for this id; resetting or replacing the RFXtrx means pairing again.

## MQTT topics

    rfxtrx/status                          -> online | offline, retained
    rfxtrx/<device>/set                    <- OPEN | CLOSE | STOP
    rfxtrx/<device>/target_position/set    <- 0..100  (<= 50 closes, > 50 opens)
    rfxtrx/<device>/target_position        -> 0 | 100, retained
    rfxtrx/<device>/current_position       -> 0 | 50 | 100, retained
    rfxtrx/<device>/position_state         -> INCREASING | DECREASING | STOPPED, retained

Command topics (`.../set`) and state topics are disjoint on purpose: the
retained state echo must never come back as a command. Retained
`current_position` doubles as persistence: on start the server subscribes to
it and adopts the broker's value.

`status` is online only while the RFXtrx is ready to transmit; an unplugged
or unanswering RFXtrx is offline, as is a stopped server (last will).

For `rfy`, open is up and close is down.

    docker exec mosquitto mosquitto_pub -t rfxtrx/woonkamer/set -m OPEN
    docker exec mosquitto mosquitto_sub -v -t 'rfxtrx/#'

## Run

    mix test
    MIX_ENV=prod mix release --overwrite
    cp deploy/rfxtrx_mqtt.service ~/.config/systemd/user/
    systemctl --user daemon-reload && systemctl --user enable --now rfxtrx_mqtt
    journalctl --user -u rfxtrx_mqtt -f

Needs the user in group `uucp` for `/dev/ttyUSB0`, and `loginctl enable-linger`.

## License

MIT, see `LICENSE`.
