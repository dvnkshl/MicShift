# Security policy

## Reporting a vulnerability

Please report security or privacy issues through GitHub's private vulnerability
reporting for the `dvnkshl/MicShift` repository. Do not include receiver serial
numbers, unredacted USB captures, usernames, or filesystem paths in a public
issue.

Include the MicShift version, macOS version, receiver model and firmware, and
the smallest reproduction you can share safely.

## Privacy boundary

MicShift does not request microphone permission, record audio, send telemetry,
or contact a server. Protocol discovery reads only the selected vendor-control
endpoint and writes a local, user-reviewed report. Unknown binary fields can
still contain identifiers, so every discovery report must be reviewed before
public sharing.
