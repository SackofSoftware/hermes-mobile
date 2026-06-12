#!/usr/bin/env bash
#
# Run the SwiftUI snapshot tests (HermesMobileTests) on a simulator. These are an
# iOS XCTest bundle, separate from the HermesKit SPM suite (`make test`).
#
# Usage:
#   scripts/snapshot.sh            # assert views against recorded baselines
#   RECORD=1 scripts/snapshot.sh   # re-record baselines (clears __Snapshots__ first)
# Env:
#   SIM_NAME   simulator to use (default: "iPhone 17 Pro")
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCHEME="HermesMobile"
WORKSPACE="HermesMobile.xcworkspace"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
SNAP_DIR="HermesMobileTests/__Snapshots__"

[ -d "$WORKSPACE" ] || tuist generate --no-open

SIM_UDID="$(
  xcrun simctl list devices available \
    | awk -v n="$SIM_NAME" 'index($0, n" (") {print; exit}' \
    | grep -oE '[0-9A-Fa-f-]{36}' | head -1
)"
[ -n "${SIM_UDID:-}" ] || { echo "✗ No available simulator named '$SIM_NAME'." >&2; exit 1; }

run() {
  xcodebuild test \
    -workspace "$WORKSPACE" -scheme "$SCHEME" \
    -destination "id=$SIM_UDID" \
    -only-testing:HermesMobileTests \
    CODE_SIGNING_ALLOWED=NO
}

if [ "${RECORD:-0}" = "1" ]; then
  echo "▸ Record mode: clearing baselines in $SNAP_DIR"
  rm -rf "$SNAP_DIR"
  run || echo "▸ Baselines recorded (first-run assertion failures are expected)."
  echo "✓ Recorded → $SNAP_DIR"
else
  run
fi
