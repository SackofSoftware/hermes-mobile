#!/usr/bin/env bash
#
# Run the HermesKit test suite with live (unbuffered) output.
# `swift test` buffers stdout when piped; a pseudo-TTY via `script` streams it.
#
# Usage:
#   scripts/test.sh [extra swift test args]   e.g. --filter ChatFeatureTests
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec script -q /dev/null swift test --package-path HermesKit "$@"
