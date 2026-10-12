#!/bin/sh
# Builds the Rust tapo-helper. When run from an Xcode build phase it also copies the binary
# into Contents/Helpers and signs it with the app's identity and hardened runtime.
set -eu

export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
export CARGO_TARGET_DIR="$ROOT/tapo-helper/target"
TRIPLE="aarch64-apple-darwin"

# Xcode exports an SDKROOT for the app target; let rustc find the SDK itself.
unset SDKROOT

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found. Run 'make bootstrap' first." >&2
  exit 1
fi

cargo build --release --locked --manifest-path "$ROOT/tapo-helper/Cargo.toml" --target "$TRIPLE"

if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${CONTENTS_FOLDER_PATH:-}" ]; then
  DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
  mkdir -p "$DEST"
  cp -f "$CARGO_TARGET_DIR/$TRIPLE/release/tapo-helper" "$DEST/tapo-helper"
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$DEST/tapo-helper"
fi
