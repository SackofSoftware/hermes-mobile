#!/usr/bin/env bash
#
# Run the SwiftUI snapshot tests (HermesMobileTests) on a simulator. These are an
# iOS XCTest bundle, separate from the HermesKit SPM suite (`make test`).
#
# Baselines are pinned to an iOS 26 simulator so renders match the app's newest target
# (Liquid Glass, the iOS 26 search presentation). Don't record on an older OS — the
# images drift.
#
# Usage:
#   scripts/snapshot.sh            # assert views against recorded baselines
#   RECORD=1 scripts/snapshot.sh   # re-record baselines (clears __Snapshots__ first)
# Env:
#   SIM_NAME   simulator to use (default: "iPhone 17 Pro")
#   SIM_OS     required iOS major version (default: 26) — guards against an older runtime
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCHEME="HermesMobile"
WORKSPACE="HermesMobile.xcworkspace"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
SIM_OS="${SIM_OS:-26}"
SNAP_DIR="HermesMobileTests/__Snapshots__"

[ -d "$WORKSPACE" ] || tuist generate --no-open

# Resolve a UDID for SIM_NAME running on an iOS SIM_OS.x runtime. Tracks the runtime
# header (`-- iOS 26.2 --`) so a same-named device on an older OS can't be picked.
read -r SIM_UDID SIM_RUNTIME < <(
  xcrun simctl list devices available \
    | awk -v n="$SIM_NAME" -v os="$SIM_OS" '
        /^-- iOS /            { rt = $3 }
        index($0, n" (") && rt ~ ("^" os "\\.") {
          match($0, /[0-9A-Fa-f-]{36}/); print substr($0, RSTART, RLENGTH), rt; exit
        }'
)
[ -n "${SIM_UDID:-}" ] || {
  echo "✗ No available '$SIM_NAME' simulator on iOS ${SIM_OS}.x." >&2
  echo "  Installed iOS runtimes:" >&2
  xcrun simctl list runtimes | grep -i ios >&2
  exit 1
}
echo "▸ Using $SIM_NAME on iOS $SIM_RUNTIME ($SIM_UDID)"

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
