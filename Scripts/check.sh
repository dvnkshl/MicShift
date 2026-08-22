#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"

if [[ -n "${RUST_TOOLCHAIN_DIR:-}" ]]; then
  export RUSTUP_HOME="$RUST_TOOLCHAIN_DIR/rustup"
  export CARGO_HOME="$RUST_TOOLCHAIN_DIR/cargo"
  CARGO_BIN="$CARGO_HOME/bin/cargo"
  RUSTFMT_BIN="$CARGO_HOME/bin/rustfmt"
elif (( $+commands[cargo] )); then
  CARGO_BIN="$commands[cargo]"
  RUSTFMT_BIN="${commands[rustfmt]:-}"
elif [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  CARGO_BIN="$HOME/.cargo/bin/cargo"
  RUSTFMT_BIN="$HOME/.cargo/bin/rustfmt"
else
  print "Rust is required. Install it from https://rustup.rs."
  exit 1
fi

if [[ ! -x "$RUSTFMT_BIN" ]]; then
  print "rustfmt is required. Run: rustup component add rustfmt clippy"
  exit 1
fi

swift test --package-path "$PROJECT_DIR"
"$CARGO_BIN" test --manifest-path "$PROJECT_DIR/Cargo.toml" --workspace --all-targets
"$CARGO_BIN" clippy --manifest-path "$PROJECT_DIR/Cargo.toml" \
  --workspace --all-targets -- -D warnings -A clippy::manual_is_multiple_of
"$RUSTFMT_BIN" --check "$PROJECT_DIR/Helper/src/main.rs"
zsh -n "$PROJECT_DIR/Scripts/build-app.sh" "$PROJECT_DIR/Scripts/build-release.sh"
plutil -lint "$PROJECT_DIR/Info.plist"

print "MicShift checks passed."
