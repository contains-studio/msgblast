#!/bin/bash
# Drive the actual msgblast agent Claude session with a deterministic stream-json stand-in. No live CLI/model calls.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
build="${1:-$root/build/contributor-tests}"
frameworks="$(cd -- "$build/Build/Products/Debug" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/msgblast-claude-agent.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$tmp/modules" \
    -target "$(uname -m)-apple-macos15.0" -I "$frameworks" -F "$frameworks" -framework msgblastCore \
    -Xlinker -rpath -Xlinker "$frameworks" \
    "$root/scripts/fixtures/claude_agent_session.swift" -o "$tmp/check"
mkdir -p "$tmp/config"
CLAUDE_CONFIG_DIR="$tmp/config" MSGBLAST_FIXTURE_CONFIG_DIR="$tmp/config" MSGBLAST_CLI_FIXTURE_LOG="$tmp/requests.jsonl" \
    "$tmp/check" "$root/scripts/fixtures/claude_agent_stream.py" "$tmp/workspace"
# Optional evidence export holds fixture arguments and inputs only, never user CLI configuration.
if [[ -n "${2:-}" ]]; then
    mkdir -p -- "$2"
    cp "$tmp/requests.jsonl" "$2/requests.jsonl"
fi
