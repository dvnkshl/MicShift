# Changelog

## [0.3.13] - 2026-08-26

### Changed

- MicShift now reacts to native USB and Core Audio events instead of continuously rescanning hardware.
- Unchanged receiver packets and live audio-level updates no longer re-enumerate inputs or redraw the menu.
- Slow watchdog scans, inaccessible-receiver retries, and helper restart recovery preserve automatic fallback and reconnection if an event is missed.
