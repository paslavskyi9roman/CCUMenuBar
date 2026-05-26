#!/usr/bin/env bash
# One-shot installer for Claude Code Usage.
#
# Checks dependencies, builds the release binary, wraps it in an ad-hoc-signed
# .app bundle, and launches it. After the app opens, walk through the Setup
# window: Install → Configure → Run test.

set -euo pipefail

# Anchor at repo root so this works regardless of where it's invoked from.
cd "$(dirname "$0")/.."

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }

if ! command -v swift >/dev/null 2>&1; then
  red "swift not found."
  echo "Install the Xcode command-line tools first:"
  echo "  xcode-select --install"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  red "jq not found."
  echo "The statusline bridge parses Claude Code's JSON with jq. Install it:"
  echo "  brew install jq"
  echo
  echo "Then re-run: ./scripts/install.sh"
  exit 1
fi

yellow "Building release binary…"
swift build -c release

yellow "Packaging .app bundle…"
./scripts/make-app.sh

yellow "Launching CCUMenuBar.app…"
open ./CCUMenuBar.app

green "Done."
echo
echo "A Setup window should be opening now. Walk through it:"
echo "  1. Install     — drops the statusline bridge into ~/.claude/scripts/"
echo "  2. Configure   — wires it into ~/.claude/settings.json"
echo "  3. Run test    — pipes a canary payload through the bridge end-to-end"
echo
echo "After Setup, run any \`claude\` command in a terminal and the menu bar"
echo "icon will start showing your usage."
