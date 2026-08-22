# Contributing to MicShift

MicShift is intentionally small: it reads link and battery state from a
supported wireless receiver, then keeps the macOS default input correct.

## Build and test

Requirements:

- macOS 13 or later
- Xcode command-line tools
- the stable Rust toolchain, including `rustfmt` and `clippy`

Run the complete local check:

```sh
./Scripts/check.sh
```

Build the menu-bar app:

```sh
./Scripts/build-app.sh
open "build/MicShift.app"
```

## Add support for another microphone

Do not infer availability from audio silence. A quiet room, muted transmitter,
or noise gate must never trigger fallback.

Use **Help Add a Microphone…** in MicShift to create a privacy-redacted USB
report, then open a **New microphone protocol report** issue. Before support is
merged, the following transitions must be decoded and reproduced on real
hardware:

- transmitter linked and usable;
- transmitter placed in its charging case;
- transmitter powered off;
- transmitter battery depleted;
- link lost by range or interference;
- transmitter reconnected;
- two-transmitter behavior, when supported by the receiver.

Read [PROTOCOL_DISCOVERY.md](PROTOCOL_DISCOVERY.md) before capturing or sharing
unknown USB traffic. Never post a photographed serial label or an unreviewed
capture.

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Add tests for protocol parsing and switching decisions.
- Run `./Scripts/check.sh` before opening the pull request.
- Preserve attribution and licensing for files under `Vendor/`.
- Do not add analytics, networking, or audio capture without an explicit
  product and privacy review.
