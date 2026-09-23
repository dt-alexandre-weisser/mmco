#!/bin/zsh
# One-shot install: builds mmco.app into ~/Applications, links the CLI onto your PATH, points the
# app at it and registers the app as the Chrome native-messaging host of the extension. Re-run
# after pulling changes.
#   ./install.sh                        links the CLI into ~/tools/bin if it exists, else /usr/local/bin
#   ./install.sh --bin <dir>            links the CLI into <dir> instead
#   ./install.sh --extension-id <id>    also allow that extension id (shown in chrome://extensions
#                                       and in the popup's error line) to reach the host
# Both options can be combined.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CLI="$ROOT/bin/mmco"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mmco"
CONFIG="$CONFIG_DIR/config.json"
HOST_NAME="com.aweisser.mmco"
APP_BINARY="$HOME/Applications/mmco.app/Contents/MacOS/mmco"

BIN_DIR=""
EXTRA_IDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bin) BIN_DIR="${2:?directory required}"; shift 2 ;;
    --extension-id) EXTRA_IDS+=("${2:?extension id required}"); shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
if [ -z "$BIN_DIR" ]; then
  if [ -d "$HOME/tools/bin" ]; then BIN_DIR="$HOME/tools/bin"; else BIN_DIR="/usr/local/bin"; fi
fi

for tool in git jq gh osascript swiftc shasum; do
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

# ---------------------------------------------------------------- native-messaging host

# An unpacked extension's id is derived from the absolute path Chrome loaded it from: the first
# 32 hex digits of sha256(path), each mapped 0-9a-f -> a-p. The physical path and the path with
# symlinks left in place can both be what the user picked, so both are allowed.
extension_id() { printf '%s' "$1" | shasum -a 256 | head -c 32 | tr '0-9a-f' 'a-p'; }
IDS=("$(extension_id "$ROOT/extension")")
PHYSICAL="$(cd "$ROOT/extension" && pwd -P)"
[ "$PHYSICAL" = "$ROOT/extension" ] || IDS+=("$(extension_id "$PHYSICAL")")
IDS+=("${EXTRA_IDS[@]}")

ORIGINS=$(printf '%s\n' "${IDS[@]}" | sort -u | jq -R 'select(length > 0) | "chrome-extension://\(.)/"' | jq -s .)
MANIFEST=$(jq -n --arg name "$HOST_NAME" --arg path "$APP_BINARY" --argjson origins "$ORIGINS" \
  '{ name: $name, description: "mmco: checkout progress for the Chrome extension", path: $path, type: "stdio", allowed_origins: $origins }')

HOST_DIRS=("$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts")
for other in "Google/Chrome Beta" "Google/Chrome Canary" "Chromium" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc" "Vivaldi"; do
  [ -d "$HOME/Library/Application Support/$other" ] && HOST_DIRS+=("$HOME/Library/Application Support/$other/NativeMessagingHosts")
done
for dir in "${HOST_DIRS[@]}"; do
  mkdir -p "$dir"
  printf '%s\n' "$MANIFEST" > "$dir/$HOST_NAME.json"
  echo "native host: $dir/$HOST_NAME.json"
done
echo "allowed extension ids: ${(j:, :)IDS}"

cat <<EOF

Chrome extension:
  1. chrome://extensions  ->  enable "Developer mode"  ->  "Load unpacked"  ->  pick  $ROOT/extension
     (already loaded: click its reload icon so the new background worker and permissions apply)
  2. on a GitHub PR, click "Checkout locally". The button spins while the run goes on.
  3. if the popup reports "host unreachable", the extension's id differs from the ones above:
     ./install.sh --extension-id <id shown in the popup>

Mapping table:  mmco --settings   (or the popup's "Settings…" link)
EOF
