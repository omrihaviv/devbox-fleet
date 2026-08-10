#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test_first_login_path_includes_user_local_bin() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  mkdir -p "$workdir/home/.local/bin"
  cat > "$workdir/home/.local/bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
exit 0
FAKE_CLAUDE
  chmod +x "$workdir/home/.local/bin/claude"

  sed '/^main "\$@"$/d' "$repo_root/scripts/devbox-onboard" \
    > "$workdir/devbox-onboard-functions"

  HOME="$workdir/home" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c 'set -euo pipefail; source "$1"; command -v claude >/dev/null' \
    _ "$workdir/devbox-onboard-functions" \
    || fail "devbox-onboard did not expose ~/.local/bin on first login"
}

# Extract just the cmux-notifications step so we can run it against a sandbox
# HOME without triggering the interactive onboarding steps.
extract_step() {
  local out="$1"
  sed -n '/^step_cmux_notifications()/,/^}/p' "$repo_root/scripts/devbox-onboard" > "$out"
  grep -q '^step_cmux_notifications()' "$out" || fail "could not extract step_cmux_notifications"
  grep -q '^}' "$out" || fail "extracted step_cmux_notifications is truncated"
}

run_step() {
  local home="$1"
  local fn="$2"
  HOME="$home" TMUX='' bash -c 'set -euo pipefail; source "'"$fn"'"; step_cmux_notifications' >/dev/null
}

extract_codex_mcp_step() {
  local out="$1"
  sed -n '/^step_codex_mcp_config()/,/^}/p' "$repo_root/scripts/devbox-onboard" > "$out"
  grep -q '^step_codex_mcp_config()' "$out" || fail "could not extract step_codex_mcp_config"
  grep -q '^}' "$out" || fail "extracted step_codex_mcp_config is truncated"
}

run_codex_mcp_step() {
  local workdir="$1"
  HOME="$workdir/home" PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "'"$workdir/codex-mcp.sh"'"; step_codex_mcp_config' >/dev/null
}

install_failing_codex_cli() {
  local workdir="$1"
  mkdir -p "$workdir/fake-bin" "$workdir/home/.fake-mcp"

  cat > "$workdir/fake-bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
[ -d "$HOME/.codex" ] || exit 3
printf '%s\n' "$*" >> "$HOME/.fake-mcp/codex-calls"
exit 99
FAKE_CODEX
  chmod +x "$workdir/fake-bin/codex"
}

test_fresh_install_and_idempotent_rerun() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  extract_step "$workdir/fn.sh"
  mkdir -p "$workdir/home"
  run_step "$workdir/home" "$workdir/fn.sh"

  [ -x "$workdir/home/bin/tmux-osc-notify.sh" ] || fail "helper not installed executable"
  grep -q "tr -d '\[:cntrl:\]'" "$workdir/home/bin/tmux-osc-notify.sh" || fail "helper is not the hardened version (control-char strip)"
  # shellcheck disable=SC2016
  grep -q 'list-clients -t "\$session"' "$workdir/home/bin/tmux-osc-notify.sh" || fail "helper is not session-scoped"
  grep -q 'timeout 1 bash' "$workdir/home/bin/tmux-osc-notify.sh" || fail "helper missing stalled-tty timeout guard"

  jq -e '.hooks.Stop[0].hooks[0].command | contains("tmux-osc-notify")' \
    "$workdir/home/.claude/settings.json" >/dev/null || fail "Stop hook not registered"
  jq -e '.hooks.Notification[0].hooks[0].command | contains("tmux-osc-notify")' \
    "$workdir/home/.claude/settings.json" >/dev/null || fail "Notification hook not registered"
  jq -e '[.hooks.SubagentStop[]?.hooks[]?.command // "" | contains("tmux-osc-notify")] | any | not' \
    "$workdir/home/.claude/settings.json" >/dev/null || fail "SubagentStop must not send notifications"
  grep -q '^notify = \["bash", "-c"' "$workdir/home/.codex/config.toml" || fail "codex notify not written"

  # Execute the generated TOML command exactly as Codex does: the configured
  # argv is followed by one JSON payload argument. Subagent completions have
  # no client and must be silent; user-facing TUI/exec turns have a client and
  # must each notify once.
  local -a notify_command=()
  mapfile -d '' -t notify_command < <(python3 - "$workdir/home/.codex/config.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    command = tomllib.load(config_file)["notify"]
for argument in command:
    sys.stdout.buffer.write(argument.encode() + b"\0")
PY
  )
  [ "${#notify_command[@]}" -ge 4 ] || fail "could not parse Codex notify command"

  cat > "$workdir/home/bin/tmux-osc-notify.sh" <<'LOGGER'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "$HOME/notify.log"
LOGGER
  chmod +x "$workdir/home/bin/tmux-osc-notify.sh"

  HOME="$workdir/home" "${notify_command[@]}" \
    '{"type":"agent-turn-complete","input-messages":[],"last-assistant-message":"4"}'
  [ ! -e "$workdir/home/notify.log" ] || fail "Codex subagent completion triggered a notification"

  HOME="$workdir/home" "${notify_command[@]}" \
    '{"type":"agent-turn-complete","client":"codex-tui","input-messages":["hi"],"last-assistant-message":"DONE"}'
  HOME="$workdir/home" "${notify_command[@]}" \
    '{"type":"agent-turn-complete","client":"codex_exec","input-messages":["hi"],"last-assistant-message":"BATCH"}'
  HOME="$workdir/home" "${notify_command[@]}" \
    '{"type":"something-else","client":"codex-tui"}'

  [ "$(wc -l < "$workdir/home/notify.log")" -eq 2 ] \
    || fail "Codex main-turn gate did not emit exactly two notifications"
  grep -q $'^Codex\tDONE$' "$workdir/home/notify.log" || fail "codex-tui completion did not notify"
  grep -q $'^Codex\tBATCH$' "$workdir/home/notify.log" || fail "codex_exec completion did not notify"

  # The hook commands must exit 0 outside tmux (notification plumbing may
  # never block Claude from stopping or fail a Codex turn).
  local cmd
  cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$workdir/home/.claude/settings.json")"
  echo '{"last_assistant_message":"x"}' | HOME="$workdir/home" TMUX='' bash -c "$cmd" \
    || fail "Stop hook command exited non-zero"

  cp -R "$workdir/home" "$workdir/before"
  run_step "$workdir/home" "$workdir/fn.sh"
  diff -r "$workdir/before" "$workdir/home" >/dev/null || fail "re-run was not a no-op"
}

test_merges_into_existing_configs() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  extract_step "$workdir/fn.sh"
  mkdir -p "$workdir/home/.claude" "$workdir/home/.codex"
  echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}' \
    > "$workdir/home/.claude/settings.json"
  printf 'model = "gpt"\n\n[mcp_servers.foo]\ncommand = "foo"\n' > "$workdir/home/.codex/config.toml"

  run_step "$workdir/home" "$workdir/fn.sh"

  jq -e '.model == "opus"' "$workdir/home/.claude/settings.json" >/dev/null \
    || fail "existing settings.json keys clobbered"
  jq -e '.hooks.Stop[0].hooks[0].command == "echo other"' "$workdir/home/.claude/settings.json" >/dev/null \
    || fail "pre-existing Stop hook entry clobbered"
  jq -e '[.hooks.Stop[].hooks[].command | contains("tmux-osc-notify")] | any' \
    "$workdir/home/.claude/settings.json" >/dev/null || fail "notify Stop hook not appended"

  # notify must land ABOVE the first [section] header (top-level TOML key).
  awk '/^notify = / {n=NR} /^\[/ {if (!s) s=NR} END {exit !(n && s && n < s)}' \
    "$workdir/home/.codex/config.toml" || fail "codex notify not inserted above first [section]"
  grep -q '^model = "gpt"' "$workdir/home/.codex/config.toml" || fail "existing toml content clobbered"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    python3 -c "import tomllib; tomllib.load(open('$workdir/home/.codex/config.toml','rb'))" \
      || fail "merged config.toml does not parse as TOML"
  fi
}

# Org connectors are delivered by the toolchain concern as JSON; the fixture
# names deliberately carry no company identifiers (release leak scan).
write_connectors_fixture() {
  local workdir="$1"
  cat > "$workdir/connectors.json" <<'CONNECTORS'
{"tracker":{"url":"https://mcp.tracker.example/mcp","http_headers":{}},
 "logs":{"url":"https://logs.example/mcp","http_headers":{"x-mcp-version":"v2"}}}
CONNECTORS
  export DEVBOX_CONNECTORS_FILE="$workdir/connectors.json"
}

test_codex_mcp_configs_are_versioned_and_idempotent() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  install_failing_codex_cli "$workdir"
  extract_codex_mcp_step "$workdir/codex-mcp.sh"
  write_connectors_fixture "$workdir"

  run_codex_mcp_step "$workdir"

  if grep -q 'claude mcp' "$workdir/codex-mcp.sh"; then
    fail "Codex MCP setup must not configure Claude MCP servers"
  fi
  [ ! -e "$workdir/home/.fake-mcp/codex-calls" ] \
    || fail "Codex CLI must not run because mcp add starts OAuth"

  python3 - "$workdir/home/.codex/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
assert config["mcp_servers"]["tracker"]["url"] == "https://mcp.tracker.example/mcp"
assert config["mcp_servers"]["logs"]["url"] == "https://logs.example/mcp"
assert config["mcp_servers"]["logs"]["http_headers"] == {"x-mcp-version": "v2"}
PY

  cp "$workdir/home/.codex/config.toml" "$workdir/codex-before"

  run_codex_mcp_step "$workdir"

  cmp -s "$workdir/codex-before" "$workdir/home/.codex/config.toml" \
    || fail "Codex MCP re-run changed config"
  unset DEVBOX_CONNECTORS_FILE
}

test_codex_mcp_preserves_existing_servers_and_config() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  install_failing_codex_cli "$workdir"
  extract_codex_mcp_step "$workdir/codex-mcp.sh"
  write_connectors_fixture "$workdir"
  mkdir -p "$workdir/home/.codex"
  cat > "$workdir/home/.codex/config.toml" <<'EXISTING_CODEX'
model = "kept"

[mcp_servers.tracker]
url = "https://custom-tracker.example/mcp"

[mcp_servers.other]
command = "other-server"
EXISTING_CODEX

  run_codex_mcp_step "$workdir"

  [ ! -e "$workdir/home/.fake-mcp/codex-calls" ] \
    || fail "Codex CLI must not run while preserving existing config"

  python3 - "$workdir/home/.codex/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
assert config["model"] == "kept"
assert config["mcp_servers"]["tracker"]["url"] == "https://custom-tracker.example/mcp"
assert config["mcp_servers"]["other"]["command"] == "other-server"
assert config["mcp_servers"]["logs"]["url"] == "https://logs.example/mcp"
assert config["mcp_servers"]["logs"]["http_headers"] == {"x-mcp-version": "v2"}
PY
  unset DEVBOX_CONNECTORS_FILE
}

test_codex_mcp_skips_without_connectors_file() {
  local workdir; workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' RETURN
  install_failing_codex_cli "$workdir"
  extract_codex_mcp_step "$workdir/codex-mcp.sh"
  export DEVBOX_CONNECTORS_FILE="$workdir/absent.json"
  run_codex_mcp_step "$workdir"
  [ ! -e "$workdir/home/.codex/config.toml" ] \
    || [ ! -s "$workdir/home/.codex/config.toml" ] \
    || fail "step must be a no-op without a connectors file"
  # The path dies with $workdir: leaking the export would let a later test pass
  # vacuously against a connectors file that no longer exists.
  unset DEVBOX_CONNECTORS_FILE
}

# A connector name is DATA, not a TOML path: unquoted, "logs.us" would nest the
# table under a "logs" server (registering nothing under that name) and then
# collide with itself on the next run, failing the step forever.
test_codex_mcp_quotes_dotted_connector_names() {
  local workdir; workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' RETURN
  install_failing_codex_cli "$workdir"
  extract_codex_mcp_step "$workdir/codex-mcp.sh"
  cat > "$workdir/connectors.json" <<'CONNECTORS'
{"logs.us":{"url":"https://logs.us.example/mcp","http_headers":{"x-mcp-version":"v2"}}}
CONNECTORS
  export DEVBOX_CONNECTORS_FILE="$workdir/connectors.json"

  run_codex_mcp_step "$workdir"

  python3 - "$workdir/home/.codex/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
servers = config["mcp_servers"]
assert set(servers) == {"logs.us"}, servers
assert servers["logs.us"]["url"] == "https://logs.us.example/mcp"
assert servers["logs.us"]["http_headers"] == {"x-mcp-version": "v2"}
PY

  cp "$workdir/home/.codex/config.toml" "$workdir/codex-before"

  # Re-run must recognise the server as present; a nested table would be
  # re-appended here and make the config unparseable.
  run_codex_mcp_step "$workdir"

  cmp -s "$workdir/codex-before" "$workdir/home/.codex/config.toml" \
    || fail "dotted connector name was re-registered on re-run"
  unset DEVBOX_CONNECTORS_FILE
}

# JSON's default non-BMP escaping emits UTF-16 surrogate pairs (for example,
# an emoji becomes two \uXXXX escapes), but TOML strings reject surrogate code
# points. Connector values must be written as real Unicode instead.
test_codex_mcp_supports_non_bmp_values() {
  local workdir; workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' RETURN
  install_failing_codex_cli "$workdir"
  extract_codex_mcp_step "$workdir/codex-mcp.sh"
  cat > "$workdir/connectors.json" <<'CONNECTORS'
{"unicode":{"url":"https://mcp.example/😀","http_headers":{"x-label":"launch-🚀"}}}
CONNECTORS
  export DEVBOX_CONNECTORS_FILE="$workdir/connectors.json"

  run_codex_mcp_step "$workdir"

  python3 - "$workdir/home/.codex/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    server = tomllib.load(f)["mcp_servers"]["unicode"]
assert server["url"] == "https://mcp.example/😀"
assert server["http_headers"] == {"x-label": "launch-🚀"}
PY
  unset DEVBOX_CONNECTORS_FILE
}

test_codex_mcp_preserves_symlinked_config() {
  local workdir target xattr_supported=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  install_failing_codex_cli "$workdir"
  extract_codex_mcp_step "$workdir/codex-mcp.sh"
  write_connectors_fixture "$workdir"
  mkdir -p "$workdir/home/.codex" "$workdir/home/dotfiles"
  target="$workdir/home/dotfiles/codex.toml"
  printf 'model = "kept-through-symlink"\n' > "$target"
  chmod 0640 "$target"
  ln -s ../dotfiles/codex.toml "$workdir/home/.codex/config.toml"
  if python3 - "$target" <<'PY' 2>/dev/null
import os
import sys

os.setxattr(sys.argv[1], b"user.devbox-onboard-test", b"kept")
PY
  then
    xattr_supported=1
  fi

  run_codex_mcp_step "$workdir"

  [ -L "$workdir/home/.codex/config.toml" ] || fail "Codex config symlink was replaced"
  [ "$(stat -c %a "$target")" = 640 ] || fail "Codex config mode was not preserved"
  python3 - "$target" "$xattr_supported" <<'PY'
import os
import sys
import tomllib

with open(sys.argv[1], "rb") as config_file:
    config = tomllib.load(config_file)
assert config["model"] == "kept-through-symlink"
assert config["mcp_servers"]["tracker"]["url"] == "https://mcp.tracker.example/mcp"
assert config["mcp_servers"]["logs"]["http_headers"] == {"x-mcp-version": "v2"}
if sys.argv[2] == "1":
    assert os.getxattr(sys.argv[1], b"user.devbox-onboard-test") == b"kept"
PY
  unset DEVBOX_CONNECTORS_FILE
}

test_first_login_path_includes_user_local_bin
test_fresh_install_and_idempotent_rerun
test_merges_into_existing_configs
test_codex_mcp_configs_are_versioned_and_idempotent
test_codex_mcp_preserves_existing_servers_and_config
test_codex_mcp_skips_without_connectors_file
test_codex_mcp_quotes_dotted_connector_names
test_codex_mcp_supports_non_bmp_values
test_codex_mcp_preserves_symlinked_config

echo "devbox-onboard tests passed"
