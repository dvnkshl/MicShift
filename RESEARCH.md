# DJI Mic Mini 2 USB-state findings

Audited 2026-08-12 against the current `main` branch and release 1.1.0 of
[ShadowBitBasher/DJI-Mic-Control](https://github.com/ShadowBitBasher/DJI-Mic-Control/tree/9ba76880807a71d4eaba74c785dbee186a98f43b),
commit `9ba76880807a71d4eaba74c785dbee186a98f43b`.

## Exact state path

The receiver is USB vendor `0x2ca3`, product `0x4011`. The control protocol is
on vendor interface 6, Bulk OUT endpoint `0x06`, Bulk IN endpoint `0x86`. This
is separate from the receiver's standard USB audio interface.

The project detects a v2 device from heartbeat byte 11 (`0x03`). On v2
firmware, the receiver emits three kinds of periodic status data:

1. A status push at roughly 10 Hz.
2. An identity push containing firmware, serial, and an ASCII product name
   such as `DJI Mic Mini 2` (record tag `0x06`).
3. A live audio-level push at roughly 10 Hz (record tag `0x05`).

The decisive transmitter-presence value is **status-packet byte 44**:

- bit `0x01` = TX1 linked;
- bit `0x02` = TX2 linked.

The upstream decoder explicitly calls this bitmask authoritative. It creates a
`TxInfo` only while that physical transmitter's bit is set, and removes the
entry on the next status push after the bit clears. It does not infer presence
from sound level, identity data, or packet length.

Each linked transmitter also contributes a 32-byte slot starting at packet
offset 52. Slot byte `+1` identifies the physical transmitter (`1` or `2`), so
a lone TX is never misidentified by array position. Slot byte `+7` contains:

- bit `0x02`: that TX is docked/charging;
- bits `0x1c`: battery gauge, decoded as `(byte >> 2) & 0x07`.

The observed practical gauge is `1` (full) through `7` (terminal/empty); `6`
is the official-app low-battery warning. Charging and battery are independent
per TX. The charging bit clears within one or two status ticks after undocking.

On 2026-08-19, a live fully charged in-case capture produced a continuous
0-TX status push with the physical mask at byte 44 cleared. No TX slot was
present, so the per-slot charging bit was not available. There is no decoded
receiver-level dock flag that separates this state from power-off or radio
loss.

The receiver itself is considered live only if a decoded heartbeat arrived in
the last 1.5 seconds. That protects against a USB receiver which still
enumerates but has stopped streaming vendor status.

Relevant upstream evidence:

- [Protocol: v2 status push](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/9ba76880807a71d4eaba74c785dbee186a98f43b/PROTOCOL.md#v2-status-push)
- [Decoder: authoritative connected mask and per-TX state](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/9ba76880807a71d4eaba74c785dbee186a98f43b/crates/protocol/src/models/mic_mini.rs#L363-L450)
- [Receiver heartbeat liveness window](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/9ba76880807a71d4eaba74c785dbee186a98f43b/crates/device/src/manager.rs#L15-L31)

## Switching rule implemented

| Protocol state | System default input |
| --- | --- |
| Receiver heartbeat live; any TX linked and not charging | Selected/automatic DJI input |
| All linked TX units charging | Fallback input |
| No TX presence bits | Fallback input |
| TX battery dies and its presence bit clears | Fallback input |
| Link is lost/out of range | Fallback input |
| Receiver unplugged, stopped, inaccessible, or helper stopped | Fallback input |
| Any TX reconnects and is not charging | DJI input again |

Audio level is retained for diagnostics but intentionally not used for the
decision. Digital silence is valid when the room is quiet or the transmitter is
muted.

On v1 firmware, transmitter presence is still explicit (`TX flags & 0x20`),
but the current open-source decoder does not expose charging. The v2 firmware
path is therefore required for immediate charging-case fallback.

## Why the receiver is not hidden

Core Audio describes three relevant hardware properties:
`DeviceIsAlive`, `DeviceCanBeDefaultDevice`, and `IsHidden`. `IsHidden` means a
device is omitted from the normal device list and cannot become default, but
the property is provided by the audio driver that publishes that device.

An app can ask
[AudioObjectIsPropertySettable](https://developer.apple.com/documentation/coreaudio/audioobjectispropertysettable%28_%3A_%3A_%3A%29)
whether a particular driver property can be written. On this Mac, the built-in
microphone reports all three properties as non-settable. A connected DJI device
was not available for a direct settable-state check, but Core Audio offers no
general API for one app to change the visibility/aliveness of a physical device
owned by another driver. An Audio Server plug-in controls the virtual devices
it creates; it does not suppress an unrelated physical USB device.

The supported system action is changing
[the default input device](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultinputdevice),
which is what this utility does. It leaves the DJI receiver visible in Sound
Settings and Audio MIDI Setup.

## Application boundary

The macOS default is advisory to applications. Apps configured to use “System
Default” normally follow it. Apps with a fixed input selection can ignore it,
and an app may keep an already-open audio session on the old device until that
session restarts.
