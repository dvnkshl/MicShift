# Free public release checklist

## Recommended first release: direct download

Ship a signed and notarized DMG from a small website or GitHub Releases. This
fits the app's USB-control architecture, keeps the utility free, and avoids
forcing an App Store account on users.

The Mac App Store is not ruled out: Apple provides a sandbox USB entitlement.
It would require a separate sandboxed build, validation that the Rust USB
transport works under that entitlement, App Review, and a plan for the bundled
helper. Direct distribution is the lower-risk first path.

## One-time decisions before publishing

- Public name selected: `MicShift`. Use DJI only in factual compatibility copy
  such as “Works with DJI Mic Mini 2.”
- Stable bundle identifier selected: `com.dvnkshal.MicShift`.
- MicShift's original Swift/Rust wrapper code uses the MIT License. The vendored
  DJI Mic Control portion remains under the Unlicense and keeps its notice.
- Decide the seller identity. Apple Developer Program individual enrollment
  displays the person's legal name; organization enrollment requires a legal
  entity and D-U-N-S verification.

## Apple distribution requirements

1. Join the Apple Developer Program. Current price is USD 99 per membership
   year (regional pricing may vary).
2. Create a `Developer ID Application` certificate.
3. Sign the helper and app with Hardened Runtime and a secure timestamp.
4. Put the signed app in a DMG.
5. Submit the DMG with `xcrun notarytool`, wait for acceptance, then staple the
   ticket with `xcrun stapler`.
6. Verify the signature, notarization ticket, and Gatekeeper assessment on a
   clean macOS account before publishing.

`Scripts/build-app.sh` creates an ad-hoc-signed local development build. Public
artifacts are produced with `Scripts/build-release.sh`, then verified for a
Developer ID signature, notarization ticket, and Gatekeeper acceptance before
publication.

## Prepared release command

`Scripts/build-release.sh` builds, signs, creates a drag-to-Applications DMG,
submits it for notarization when credentials are configured, staples the
ticket, and performs final checks.

First store notary credentials in Keychain (one-time), then run:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'
export NOTARYTOOL_PROFILE='mic-auto-notary'
./Scripts/build-release.sh
```

The script refuses to overwrite an existing release DMG. It also remaps Rust
source paths so a crash string does not expose the build machine's home path.

## Product work still needed

- Validate the Finder appearance of the included `.icns` asset on a clean Mac.
- Add a first-launch explanation: choose wireless receiver, choose fallback,
  and set dictation apps to `System Default`.
- Validate the implemented `Launch at Login` option from a copy installed in
  `/Applications` before public release.
- Add an About window with version, compatibility, privacy statement, license,
  source notices, support link, and a link to this protocol documentation.
- Validate the included discovery-report issue template on the public GitHub
  repository. It requests the model/firmware and marked JSON bundle, reminds
  contributors to review it, and prohibits photographed serial labels.
- Test on current macOS plus the declared macOS 13 minimum, with Mic Mini and
  Mic Mini 2 if both are claimed.
- Produce both Apple Silicon and Intel builds, or clearly label the first
  release Apple-Silicon-only. The current artifact is arm64 only.
- Add an update channel later (for example Sparkle) or tell users to download
  new versions manually. An update system needs its own signing key and feed.

## Privacy and support copy

The present utility does not request microphone permission, record audio, send
telemetry, or contact a server. It reads local USB status and changes the local
Core Audio default. Optional protocol discovery exports a local, user-reviewed
JSON file: USB serial descriptors are omitted, long printable packet fields are
redacted, and the report warns that unknown binary fields may remain. A short
privacy page should say exactly that. If uploads, analytics, or automatic
updates are added later, update the statement before release.

Support documentation must call out the application boundary:

- apps set to a fixed microphone can ignore the macOS default;
- some apps keep an already-open audio stream until recording restarts;
- the physical receiver remains visible in Sound Settings because its driver
  does not let another app hide it;
- DJI Mic Control and this utility cannot own the same vendor USB interface at
  the same time.

## Release acceptance test

- Fresh Mac downloads the DMG with quarantine metadata intact.
- Gatekeeper opens it without a bypass command or “damaged” warning.
- Dragging to Applications and launching works.
- The receiver can be selected even under an unusual Core Audio name.
- TX out and linked selects the wireless receiver.
- TX in case, powered off, empty, or out of range selects fallback.
- Reconnection restores the wireless receiver automatically.
- Battery bands and charging state update without microphone permission.
- Two-TX behavior is correct when one charges and one remains active.
- Apps using `System Default` follow the switch on their next audio session.
- Fixed-input apps are documented as intentionally outside the app's control.
- Discovery finds the receiver, never requests microphone permission, captures
  vendor-IN traffic without USB writes, records all state markers, stops at its
  packet limit, exports valid JSON, and resumes normal switching after exit.

## Current authoritative Apple references

- [Apple Developer Program enrollment and price](https://developer.apple.com/programs/enroll/)
- [Signing Mac software with Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [macOS distribution comparison](https://developer.apple.com/macos/distribution/)
- [USB entitlement for sandboxed Mac apps](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb)
