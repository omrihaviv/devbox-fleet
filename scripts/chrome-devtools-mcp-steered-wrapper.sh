#!/bin/bash
# Pinned by cloud-init. Do not edit on the running box — bump terraform.tfvars
# toolchain pins and rebuild instead.
#
# Sibling of chrome-devtools-mcp-wrapper.sh (the ephemeral, per-session
# launcher). This wrapper instead ATTACHES the MCP server to the long-lived
# chrome-steered.service on 127.0.0.1:9222. The agent shares the steered
# Chrome's --user-data-dir (cookies, logged-in sessions, extensions) rather
# than spinning up an isolated profile each invocation.
#
# Trust model: the steered Chrome holds whatever the dev has logged into via
# `chrome://inspect`. Any tool that can drive it has full session access.
# That is intentional — this MCP server is for "use my Slack", "use my
# Linear" style tasks. Use the regular `chrome-devtools` MCP for
# unauthenticated work.
#
# NOTE on the --browser-url flag (kebab-case): chrome-devtools-mcp accepts
# both --browserUrl and --browser-url; kebab-case matches upstream's current
# examples and is the form documented in dev-quickstart.

set -euo pipefail

NODE_BIN="/usr/bin/node"
MCP_BIN="/usr/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
CDP_URL="http://127.0.0.1:9222"

for f in "$NODE_BIN" "$MCP_BIN"; do
  [ -e "$f" ] || { echo "chrome-devtools-mcp-steered-wrapper: missing pinned binary: $f" >&2; exit 1; }
done

# Readiness: confirm chrome-steered.service is actually serving CDP at the
# expected endpoint. /json/version is the canonical liveness probe — it
# returns 200 with a JSON body containing webSocketDebuggerUrl as soon as
# Chrome's CDP listener is fully up. Retry briefly to cover the case where
# Chrome is mid-restart (Restart=always cycle).
for _ in $(seq 1 5); do
  if curl -fsS --max-time 1 "$CDP_URL/json/version" 2>/dev/null \
       | grep -q '"webSocketDebuggerUrl"'; then
    exec "$NODE_BIN" "$MCP_BIN" --browser-url="$CDP_URL" "$@"
  fi
  sleep 1
done

cat >&2 <<EOM
chrome-devtools-mcp-steered-wrapper: chrome-steered.service is not serving CDP at $CDP_URL.
Check:  systemctl status chrome-steered
Logs:   journalctl -u chrome-steered --since '5 min ago'
EOM
exit 1
