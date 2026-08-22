#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/build/MicShift.app"
ICON_PATH="$PROJECT_DIR/Assets/AppIcon/MicShift.icns"

if [[ -n "${RUST_TOOLCHAIN_DIR:-}" ]]; then
  export RUSTUP_HOME="$RUST_TOOLCHAIN_DIR/rustup"
  export CARGO_HOME="$RUST_TOOLCHAIN_DIR/cargo"
  CARGO_BIN="$CARGO_HOME/bin/cargo"
elif (( $+commands[cargo] )); then
  CARGO_BIN="$commands[cargo]"
elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
else
  CARGO_BIN=""
fi

if [[ ! -x "$CARGO_BIN" ]]; then
  print "A Rust toolchain is required to build the bundled DJI USB helper."
  print "Install Rust from https://rustup.rs, then run this script again."
  exit 1
fi

"$CARGO_BIN" build --release --manifest-path "$PROJECT_DIR/Cargo.toml" -p dji-link-monitor
swift build -c release --package-path "$PROJECT_DIR"

if [[ ! -f "$ICON_PATH" ]]; then
  print "App icon is missing: $ICON_PATH"
  exit 1
fi

if [[ -d "$APP_DIR" ]]; then
  case "$APP_DIR" in
    "$PROJECT_DIR"/build/MicShift.app) find "$APP_DIR" -depth -delete ;;
    *) print "Refusing to clean unexpected app path: $APP_DIR"; exit 1 ;;
  esac
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/.build/release/DJIMicAutoSwitch" "$APP_DIR/Contents/MacOS/MicShift"
cp "$PROJECT_DIR/target/release/dji-link-monitor" "$APP_DIR/Contents/Resources/dji-link-monitor"
cp "$ICON_PATH" "$APP_DIR/Contents/Resources/MicShift.icns"
chmod +x "$APP_DIR/Contents/MacOS/MicShift" "$APP_DIR/Contents/Resources/dji-link-monitor"
codesign --force --deep --sign - "$APP_DIR"

print "$APP_DIR"
