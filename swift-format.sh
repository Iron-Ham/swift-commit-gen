#!/bin/bash

set -euo pipefail

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

# Ensure we run from the project root when invoked from Xcode build phases.
if [[ -n "${SRCROOT:-}" ]]; then
  cd "${SRCROOT}"
fi

# Verify dependencies are available before continuing.
command -v git >/dev/null 2>&1 || fatal "git is required but not installed."

SWIFT_FORMAT_TOOL=()
if command -v swift-format >/dev/null 2>&1; then
  SWIFT_FORMAT_TOOL=(swift-format)
elif command -v swift >/dev/null 2>&1 && swift format --version >/dev/null 2>&1; then
  SWIFT_FORMAT_TOOL=(swift format)
else
  fatal "swift-format (or swift format) is required but not installed."
fi

# Increase file descriptor limit for --parallel flag
# See: https://github.com/swiftlang/swift-format/issues/528
ulimit -Sn 1024 || log "Unable to raise ulimit; continuing with defaults."

if [[ -f .swiftformatignore ]]; then
  log "Found swiftformatignore file..."

  log "Running swift-format format..."
  tr '\n' '\0' < .swiftformatignore \
    | xargs -0 -I% printf '":(exclude)%" ' \
    | xargs git ls-files -z '*.swift' \
    | xargs -0 "${SWIFT_FORMAT_TOOL[@]}" format --parallel --in-place

  log "Running swift-format lint..."
  tr '\n' '\0' < .swiftformatignore \
    | xargs -0 -I% printf '":(exclude)%" ' \
    | xargs git ls-files -z '*.swift' \
    | xargs -0 "${SWIFT_FORMAT_TOOL[@]}" lint --strict --parallel
else
  log "Running swift-format format..."
  git ls-files -z '*.swift' | xargs -0 "${SWIFT_FORMAT_TOOL[@]}" format --parallel --in-place

  log "Running swift-format lint..."
  git ls-files -z '*.swift' | xargs -0 "${SWIFT_FORMAT_TOOL[@]}" lint --strict --parallel
fi

log "Checking for modified files..."

if GIT_PAGER='' git diff --quiet -- '*.swift'; then
  log "✅ Found no formatting issues."
else
  log "⚠️ Swift-format introduced Swift file changes; review and commit them when ready."
fi
