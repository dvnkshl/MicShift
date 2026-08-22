# Protocol discovery and new-device contributions

MicShift supports a receiver only when it has a clean, repeatable hardware
state signal. Receiver USB presence or audio silence is not enough: a supported
decoder must distinguish an active transmitter from one that is docked,
powered off, empty, or out of range, and it must recover on reconnection.

## Contributor workflow

Open **Help Add a Microphone…** in the status-bar menu, select the USB receiver,
and enter the product name printed by the manufacturer. If a readable
vendor-status endpoint exists, start the read-only scan.

Place the hardware in each available state, wait at least two seconds for the
status stream to settle, and then mark the state:

1. Receiver connected with no transmitter.
2. TX1 linked and active.
3. TX1 in the charging case.
4. TX1 powered off.
5. TX1 out of range / link lost.
6. TX1 reconnected.
7. TX2 linked, if supported.
8. One transmitter charging while another remains active, if supported.
9. Low-battery and charging states, if practical.

Stop and save the JSON report. Review it locally before attaching it to a
public issue. Include the exact receiver/transmitter model and firmware in the
issue text; do not post a photographed serial-number label.

## Scanner safety boundary

The discovery helper:

- enumerates USB descriptors without exporting the USB serial string;
- claims only class `0xff` vendor-specific interfaces;
- reads only Bulk IN or Interrupt IN endpoints;
- never claims USB Audio class `0x01` streaming interfaces;
- never submits Bulk OUT, Interrupt OUT, or control commands;
- limits each capture to 2,000 packet records;
- never requests macOS microphone permission or records audio.

Printable ASCII runs of six or more bytes inside packets are replaced with
zero bytes. The report retains only the redacted byte range. This catches the
ordinary serial/product strings seen in current DJI protocols. It cannot prove
that an unknown protocol has no non-ASCII or encrypted identifier, so the UI
and JSON both require review before public sharing.

## JSON bundle

The top-level report includes:

- schema, app version, macOS version, and CPU architecture;
- the contributor-entered model label;
- USB VID/PID, device version, manufacturer/product strings, interfaces, and
  endpoint descriptors;
- ordered state markers with timestamps and capture-record indexes;
- privacy flags;
- redacted, timestamped vendor-IN packet records.

It intentionally excludes USB serial strings, Core Audio UIDs, usernames,
filesystem paths, microphone audio, and network information.

## Maintainer acceptance gate

A report is evidence for reverse engineering, not proof of compatibility. A
new receiver model should be added only after:

- its USB identity and vendor interface are stable across reconnects;
- an authoritative TX-presence or link-state field is identified;
- charging/docked, power-off, battery depletion, range loss, and reconnection
  transitions are differentiated where the hardware exposes them;
- multiple-TX behavior is correct;
- packet fixtures are redacted and covered by decoder tests;
- automatic Core Audio switching is tested on physical hardware;
- the supported firmware range and unavailable fields are documented.

If the receiver exposes no clean host-visible status, it can be listed as
descriptor-only or unsupported. Audio-silence guessing should not be presented
as equivalent to verified protocol support.
