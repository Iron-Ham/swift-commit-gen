#!/bin/sh
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DESTINATION=${1:-"$HOME/.local/bin"}

printf 'Building scg (release)...\n'
cd "$PROJECT_ROOT"
swift build -c release

BIN_SOURCE="$PROJECT_ROOT/.build/release/scg"
if [ ! -f "$BIN_SOURCE" ]; then
  printf 'error: expected binary %s not found.\n' "$BIN_SOURCE" >&2
  exit 1
fi

printf 'Installing to %s...\n' "$DESTINATION"
install -d "$DESTINATION"
install "$BIN_SOURCE" "$DESTINATION/"

cat <<'EOF'
Installation complete.
Ensure the destination directory is on your PATH, for example:

  export PATH="$HOME/.local/bin:$PATH"

You can now run `scg generate` inside a Git repository.
EOF
