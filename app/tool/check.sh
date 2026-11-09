#!/usr/bin/env bash
# Run the same checks as GitHub CI, on this computer: analyzer + all tests.
#   app/tool/check.sh            analyze + test
#   app/tool/check.sh --build    also build the desktop app for this computer
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get
flutter analyze
flutter test
if [[ "${1:-}" == "--build" ]]; then
  case "$(uname -s)" in
    Darwin) flutter build macos --release ;;
    *) flutter build linux --release ;;
  esac
fi
echo "All checks passed."
