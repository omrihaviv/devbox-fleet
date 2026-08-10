#!/bin/bash
# Pinned by cloud-init. Do not edit on the running box — bump terraform.tfvars
# toolchain pins and rebuild instead.
#
# Runtime assumptions (set up by cloud-init step 8 + step 11):
#   /usr/bin/node                                          (NodeSource, root-owned)
#   /usr/lib/node_modules/chrome-devtools-mcp/dist/...     (root-owned, dev-unwritable)
#   /usr/bin/google-chrome-stable                          (Google apt repo, pinned)
#
# Chrome launch model: chrome-devtools-mcp spawns Chrome itself per session,
# using --executablePath + --headless + --user-data-dir. Per-session Chrome
# dies when the MCP session ends. Devs CANNOT pass flags through Claude's MCP
# launcher to override this — the wrapper sits between.
#
# NOTE: --headless is a boolean flag in chrome-devtools-mcp (yargs). Do NOT
# write --headless=new — yargs cannot parse a value into a boolean and silently
# falls back to the default (false → headful), which crashes on a server with
# no X display.

set -euo pipefail

NODE_BIN="/usr/bin/node"
MCP_BIN="/usr/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
CHROME_BIN="/usr/bin/google-chrome-stable"
USER_DATA_DIR="${HOME}/.local/share/chrome-devtools-mcp"

for f in "$NODE_BIN" "$MCP_BIN" "$CHROME_BIN"; do
  [ -e "$f" ] || { echo "chrome-devtools-mcp-wrapper: missing pinned binary: $f" >&2; exit 1; }
done

mkdir -p "$USER_DATA_DIR"

exec "$NODE_BIN" "$MCP_BIN" \
  --executablePath="$CHROME_BIN" \
  --headless \
  --user-data-dir="$USER_DATA_DIR" \
  "$@"
