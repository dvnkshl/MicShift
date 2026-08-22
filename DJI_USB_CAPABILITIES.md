# DJI Mic Mini / Mic Mini 2 USB capabilities

Supported models: **DJI Mic Mini** and **DJI Mic Mini 2**. Both use the same
USB receiver identity and Mic Mini protocol family. Verified 2026-08-12
against DJI Mic Control 1.1.0, commit
`9ba76880807a71d4eaba74c785dbee186a98f43b`, its documented v1/v2 USB
protocol, and a live DJI Mic Mini 2 receiver on v2 firmware.

This is an independent interoperability record. DJI Mic Control is an
unofficial open-source project, and the protocol is not an official DJI API.

## Live result on this Mac

The connected receiver identifies as:

- USB receiver id: `XSP12345678B`
- Core Audio name: `Wireless Mic Rx`
- Core Audio vendor: `DJI Technology Co., Ltd.`
- protocol: v2
- input format: two channels at 48 kHz

With the transmitter in the charging case, a direct six-second USB capture
repeatedly reported a live receiver with an empty transmitter list. The app
selected `MacBook Pro Microphone` as the macOS default input. The clean signal
on this firmware is therefore the transmitter-presence mask clearing; audio
silence is not needed.

A second live capture on 2026-08-19 with a fully charged transmitter in the
case produced the same 0-TX status push: byte 44 was `0x00`, there was no TX
slot, and therefore no charging bit. The protocol can report **active**
charging while a TX slot exists, but once this firmware removes a fully charged
TX slot, the current packet cannot distinguish “fully charged in case” from
powered off, depleted, or out of range. The menu describes that ambiguity
instead of inventing a charging state; automatic fallback remains correct in
all of those cases.

Core Audio reports the receiver as alive, visible, and eligible to be the
default input, but all three properties are **not settable** by this app:

```text
Wireless Mic Rx | alive=true settable=false | canDefault=true settable=false | hidden=false settable=false
```

The receiver cannot be hidden or made non-viable by an ordinary menu-bar app.
Changing the system default input is the supported path.

## Readable receiver and link state

| State | Available | Notes |
| --- | --- | --- |
| USB receiver present | Yes | USB vendor `0x2ca3`, product `0x4011` |
| USB control interface accessible | Yes | Detects contention with another control app |
| Receiver heartbeat live | Yes | Considered stale after 1.5 seconds without a valid heartbeat |
| Receiver/device id | Yes | Stable receiver id used by the USB manager |
| Protocol generation | Yes | v1 or v2, inferred from heartbeat byte 11 |
| Receiver serial | Yes | Learned from heartbeat/identity data |
| Receiver firmware | Yes | Four-component firmware version |
| Physical gain dial | v2 only | Signed dB value: `+12`, `+6`, `0`, `-6`, or `-12` |
| Current receiver settings | Yes | See the writable-settings table below |
| Standard USB audio availability | Yes, via Core Audio | Separate from the vendor control interface |

## Readable state for each transmitter

| State | Available | Notes |
| --- | --- | --- |
| TX1/TX2 linked presence | Yes | Authoritative v2 bitmask at status byte 44; v1 has explicit present flags |
| Physical transmitter slot | Yes | A lone transmitter is still identified as TX1 or TX2 correctly |
| Charging/docked | v2 decoded | Per-TX bit; not decoded by the current v1 path |
| Battery | v2 decoded | Ordinal gauge `1` full through `7` terminal/empty; not a percentage |
| Live audio level | Yes | Raw device unit at about 10 Hz; useful for a meter, not for availability |
| Product name | v2 | For example `DJI Mic Mini 2` |
| Serial number | Yes | Learned from identity data |
| Firmware version | Yes | Learned from identity data |
| Voice Tone | Mic Mini 2, v2 | `Standard`, `Rich`, or `Bright`, independently per transmitter |
| Noise cancellation active | Yes | Current active state, separate from Basic/Strong mode |

The battery gauge is the only battery value currently available. It provides
useful bands, but not exact percent or remaining minutes:

| Raw gauge | Safe UI meaning |
| --- | --- |
| `1` | Full |
| `2`–`3` | High |
| `4` | Medium |
| `5`–`6` | Low (`6` is the official-app warning point) |
| `7` | Empty/terminal; shutdown follows |
| `0`/missing | Unknown |

The device can skip an intermediate value while charging. A time-left estimate
would require observing a particular transmitter over many discharge cycles
and would still depend on gain, noise cancellation, temperature, battery age,
and radio conditions. The app therefore does not invent an hours/minutes value.

## Settings the USB protocol can read and change

| Setting | Scope | Values | Firmware support / behavior |
| --- | --- | --- | --- |
| Noise Cancel mode | All TX | Basic, Strong | v1 + v2 |
| Noise Cancelling power | All TX | Off, On | v2 |
| Toggle NC via TX power button | All TX | Off, On | v2; permission for the physical shortcut |
| Low Cut | All TX | Off, On | v1 + v2 |
| Audio Channels | Receiver | Mono, Stereo | v1 + v2; mutually exclusive with Safety Track |
| Safety Track | Receiver | Off, On | v1 + v2; mutually exclusive with Stereo |
| Clipping Control | Receiver | Off, On | v1 + v2 |
| Auto Off RX after 15 minutes | Receiver | Off, On | v1 + v2 |
| Auto Off TX after 15 minutes | All TX | Off, On | v2 |
| RX power follows camera | Receiver | Off, On | v1 + v2 |
| Plug-Free external speaker | Receiver | Off, On | v1 + v2; changing it reboots the receiver |
| Mic LEDs | All TX | Off, On | v1 + v2 |
| Voice Tone | One TX | Standard, Rich, Bright | v2; Mic Mini 2 only; independently targeted |

All transmitter settings except Voice Tone are broadcast/mirrored across the
connected transmitters. Commands receive an acknowledgement packet, so the
control library can distinguish an acknowledged change from a failed write.

The auto-switch utility currently reads only the minimum safe subset:
receiver present/access/live, protocol version, TX presence, charging, battery,
raw level, and product name. The vendored library already decodes the broader
identity, gain, and settings surface above, so those can be added later without
reverse-engineering a new transport.

## Data present but not fully modelled

- A six-character hex-like identity record (`0x04`) is visible in v2 identity
  pushes but is not currently modelled.
- Several constant or unknown bytes remain in the v2 status header and TX slot.
- v1 likely carries more state than the current decoder exposes, but charging,
  battery, and receiver gain have not been located or validated there.
- Product names are reported by the hardware and should be treated as device
  identity, not as a stable public-app brand contract.

## Not available from the decoded protocol

- exact battery percentage, capacity, health, charge rate, or time remaining;
- charging-case battery level;
- radio RSSI, range remaining, packet-loss percentage, or a link-quality score;
- a reliable `person is speaking` boolean (only a raw audio-level meter exists);
- a command that removes the USB audio device from macOS;
- a command that forces another application to abandon an already-open audio
  stream;
- official compatibility guarantees for future DJI firmware.

## Automatic-switching rule

The utility intentionally uses protocol state, never audio silence:

| Observed state | macOS default input |
| --- | --- |
| Heartbeat live + at least one linked, non-charging TX | Designated wireless receiver |
| No linked TX | Fallback microphone |
| Every linked TX is charging | Fallback microphone |
| Fully charged TX disappears from the status mask | Fallback microphone; shown as offline because no charging bit remains |
| TX powers off, runs empty, or loses radio link | Fallback microphone after presence clears |
| Receiver disconnects, becomes inaccessible, or heartbeat expires | Fallback microphone |
| Any usable TX reconnects | Designated wireless receiver |

Changing the macOS default affects apps set to `System Default` (or equivalent).
An app with a manually selected receiver can ignore the change. An app may also
keep an audio stream it opened before the default changed until that recording
session stops and restarts. The menu now reports the actual macOS default so
this boundary is visible.

## Sources

- [DJI Mic Control repository](https://github.com/ShadowBitBasher/DJI-Mic-Control)
- [DJI Mic Control 1.1.0 release](https://github.com/ShadowBitBasher/DJI-Mic-Control/releases/tag/1.1.0)
- [Reverse-engineered protocol specification](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/9ba76880807a71d4eaba74c785dbee186a98f43b/PROTOCOL.md)
