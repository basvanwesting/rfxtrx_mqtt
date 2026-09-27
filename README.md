# forest_shuttle

Drives Forest Shuttle curtain motors through an RFXCOM RFXtrx433XL and
exposes them over MQTT, for Homebridge (`homebridge-mqttthing`) or anything
else that speaks MQTT. Replaces the old node `forest-shuttle-server`.

## Protocol

RFXtrx frames are `<<len, type, subtype, seq, payload>>`. On connect the
server sends reset (14 bytes), waits 300 ms, flushes, requests status, and
sends start receiver; the "Copyright RFXCOM" answer marks it ready. Without
the start the device ACKs transmit commands but sends nothing. A curtain command is one
Blinds1 packet, subtype 0x07 (T7 Forest): `<<0x09, 0x19, 0x07, seq,
id::28, unit::4, cmnd, 0x00>>` with cmnd 0 open, 1 close, 2 stop, 3 confirm
(pairing). Every command is answered by a transmitter response
(`<<0x04, 0x02, 0x01, seq, code>>`), matched on `seq`. Commands are
serialised, one in flight.

The XL only transmits to Forest motors, so position is emulated: travel is
assumed complete after `FOREST_SHUTTLE_TRAVEL_MS`; a stop mid-travel reports 50.

## MQTT topics

    forest_shuttle/status                    online | offline (last will), retained
    forest_shuttle/<room>/set                  <- OPEN | CLOSE | STOP
    forest_shuttle/<room>/target_position/set  <- 0..100  (<= 50 closes, > 50 opens)
    forest_shuttle/<room>/target_position      -> 0 | 100, retained
    forest_shuttle/<room>/current_position     -> 0 | 50 | 100, retained
    forest_shuttle/<room>/position_state       -> INCREASING | DECREASING | STOPPED, retained

Command topics (`.../set`) and state topics are disjoint on purpose: the
retained state echo must never come back as a command.

Retained `current_position` doubles as persistence: on start the server
subscribes to it and adopts the broker's value.

    mosquitto_pub -t forest_shuttle/woonkamer/set -m OPEN
    mosquitto_sub -v -t 'forest_shuttle/#'

## Configuration

Environment, see `deploy/env.example`. Rooms: `room=0xID/unit,...`; id is a
28-bit number, unit 0..15 (0 = all units of that id).

## Pairing a motor

Put the motor in learn mode, then from `bin/forest_shuttle remote`:

    ForestShuttle.pair(0x0A1B2C3, 1)

## Run

    mix test
    MIX_ENV=prod mix release
    cp deploy/forest_shuttle.service ~/.config/systemd/user/
    systemctl --user daemon-reload && systemctl --user enable --now forest_shuttle
    journalctl --user -u forest_shuttle -f

Needs the user in group `uucp` for `/dev/ttyUSB0`, and `loginctl enable-linger`.
