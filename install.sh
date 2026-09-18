#!/bin/zsh
# One-shot install: builds mmco.app into ~/Applications, links the CLI onto your PATH and points
# the app at it. Re-run after pulling changes.
#   ./install.sh                 links the CLI into ~/tools/bin if it exists, else /usr/local/bin
#   ./install.sh --bin <dir>     links the CLI into <dir> instead
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CLI="$ROOT/bin/mmco"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mmco"
CONFIG="$CONFIG_DIR/config.json"

BIN_DIR=""
if [ "${1:-}" = "--bin" ]; then BIN_DIR="${2:?directory required}"; fi
if [ -z "$BIN_DIR" ]; then
  if [ -d "$HOME/tools/bin" ]; then BIN_DIR="$HOME/tools/bin"; else BIN_DIR="/usr/local/bin"; fi
fi

for tool in git jq gh osascript swiftc; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool" >&2; MISSING=1; }
done
[ -z "${MISSING:-}" ] || { echo "install the missing tools first (brew install jq gh; xcode-select --install)" >&2; exit 1; }

chmod +x "$CLI"
mkdir -p "$BIN_DIR"
ln -sfn "$CLI" "$BIN_DIR/mmco"
echo "CLI linked: $BIN_DIR/mmco -> $CLI"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: $BIN_DIR is not on your PATH" ;; esac

mkdir -p "$CONFIG_DIR"
[ -f "$CONFIG" ] || echo '{ "version": 1, "mappings": [] }' > "$CONFIG"
tmp=$(mktemp)
jq --arg cli "$CLI" '.cli = $cli' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
echo "config: $CONFIG (cli = $CLI)"

"$ROOT/app/build.sh" --install

cat <<EOF

Chrome extension (one-time):
  1. chrome://extensions  ->  enable "Developer mode"  ->  "Load unpacked"
  2. pick  $ROOT/extension
  3. on a GitHub PR, click "Checkout locally"; tick "Always allow" in Chrome's "Open mmco?" prompt

Mapping table:  mmco --settings   (or the popup's "Settings…" link)
EOF
