#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONCERN="$repo_root/scripts/gcp/devbox-vercel-gateway"
CONVERGE="$repo_root/scripts/gcp/devbox-converge"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$CONCERN" ] || fail "scripts/gcp/devbox-vercel-gateway missing or not executable"
rg -q --fixed-strings 'run_concern "vercel-gateway" "devbox-vercel-gateway"' "$CONVERGE" \
  || fail "devbox-converge must dispatch devbox-vercel-gateway"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state" "$work/home/.local/bin" "$work/home/.paseo" "$work/usr/local/bin"

# Stub paseo: same contract as the bedrock test (help advertises reload;
# `reload --json` is logged).
cat > "$work/home/.local/bin/paseo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$*" = --help ]; then
  if [ "${DEVBOX_TEST_PASEO_LEGACY:-0}" = 1 ]; then
    printf 'Commands:\n  daemon [options]  Manage the daemon\n'
  else
    printf 'Commands:\n  reload [options]  Reload the daemon configuration\n'
  fi
  exit 0
fi
[ "$*" = 'reload --json' ] || exit 2
printf '%s\n' "$*" >> "$DEVBOX_TEST_PASEO_LOG"
[ "${DEVBOX_TEST_PASEO_RELOAD_FAIL:-0}" != 1 ] || exit 1
printf '{"appliedPaths":["agents.providers"],"restartRequiredPaths":[],"overrideControlledPaths":[]}\n'
EOF
chmod +x "$work/home/.local/bin/paseo"

# Stub claude/codex: dump env + args so wrapper behaviour is observable.
for tool in claude codex; do
  cat > "$work/home/.local/bin/$tool" <<STUB
#!/usr/bin/env bash
env > "$work/$tool-env"
printf '%s\n' "\$@" > "$work/$tool-args"
STUB
  chmod +x "$work/home/.local/bin/$tool"
done

run_concern() {
  DEVBOX_RUNTIME_STATE_DIR="$work/state" \
  DEVBOX_DEV_HOME="$work/home" \
  DEVBOX_CLAUDE_BIN="$work/home/.local/bin/claude" \
  DEVBOX_CODEX_BIN="$work/home/.local/bin/codex" \
  DEVBOX_VCLAUDE_BIN="$work/usr/local/bin/vclaude" \
  DEVBOX_VCODEX_BIN="$work/usr/local/bin/vcodex" \
  DEVBOX_PASEO_BIN="$work/home/.local/bin/paseo" \
  DEVBOX_PASEO_CONFIG_FILE="$work/home/.paseo/config.json" \
  DEVBOX_TEST_PASEO_LOG="$work/paseo.log" \
  DEVBOX_SKIP_ROOT_CHECK=1 \
  bash "$CONCERN"
}

key_file="$work/home/.config/vercel-ai-gateway/api-key"
enabled_manifest='{"schema":1,"scripts":{},"env":{},"vercel_ai_gateway":{"codex_model":"openai/custom-model"}}'
disabled_manifest='{"schema":1,"scripts":{},"env":{}}'
paseo_seed='{"version":1,"agents":{"providers":{"opencode":{"enabled":true}}},"features":{"webUi":{"enabled":false}}}'

# 1. No manifest → no-op.
run_concern || fail "must exit 0 without a manifest"
[ ! -e "$work/usr/local/bin/vclaude" ] || fail "must not publish vclaude without a manifest"
[ ! -e "$key_file" ] || fail "must not create the key file without a manifest"

# 2. Manifest without the object → clean no-op.
printf '%s\n' "$disabled_manifest" > "$work/state/manifest.json"
printf '%s\n' "$paseo_seed" > "$work/home/.paseo/config.json"
run_concern || fail "must exit 0 when vercel_ai_gateway is absent"
[ ! -e "$work/usr/local/bin/vclaude" ] || fail "must not publish vclaude when disabled"
[ ! -e "$work/usr/local/bin/vcodex" ] || fail "must not publish vcodex when disabled"
[ ! -e "$key_file" ] || fail "must not create the key file when disabled"
[ ! -e "$work/paseo.log" ] || fail "must not reload paseo when nothing changed"

# 3. Enabled → wrappers, key file, paseo providers.
printf '%s\n' "$enabled_manifest" > "$work/state/manifest.json"
run_concern || fail "enabled converge must succeed"
[ -x "$work/usr/local/bin/vclaude" ] || fail "vclaude not published"
[ -x "$work/usr/local/bin/vcodex" ] || fail "vcodex not published"
[ "$(stat -c %a "$work/usr/local/bin/vclaude")" = 755 ] || fail "vclaude must be 0755"
[ -f "$key_file" ] || fail "key file not created"
[ "$(stat -c %a "$key_file")" = 600 ] || fail "key file must be 0600"
[ ! -s "$key_file" ] || fail "key file must be created empty"
[ "$(stat -c %a "$(dirname "$key_file")")" = 700 ] || fail "key dir must be 0700"
grep -q 'ai-gateway.vercel.sh/claude-code' "$work/usr/local/bin/vclaude" || fail "vclaude lacks the Claude Code endpoint"
grep -q 'ai-gateway.vercel.sh/codex/v1' "$work/usr/local/bin/vcodex" || fail "vcodex lacks the Codex endpoint"
grep -q -- "-c 'model=\"openai/custom-model\"'" "$work/usr/local/bin/vcodex" || fail "vcodex must pin the manifest codex_model"
grep -q 'Managed by devbox-vercel-gateway' "$work/usr/local/bin/vclaude" || fail "vclaude lacks the managed header"
jq -e '.agents.providers.vclaude.extends == "claude"
  and .agents.providers.vclaude.command == ["'"$work"'/usr/local/bin/vclaude"]
  and .agents.providers.vcodex.extends == "codex"
  and .agents.providers.vcodex.command == ["'"$work"'/usr/local/bin/vcodex"]
  and .agents.providers.opencode.enabled == true
  and .features.webUi.enabled == false' "$work/home/.paseo/config.json" >/dev/null \
  || fail "paseo providers not merged additively"
[ "$(stat -c %a "$work/home/.paseo/config.json")" = 600 ] || fail "paseo config must stay 0600"
grep -qx 'reload --json' "$work/paseo.log" || fail "paseo must be reloaded after registering providers"

# 4a. Empty key file → wrapper refuses with a hint; underlying tool never runs.
rm -f "$work/claude-env"
if env -i PATH=/usr/bin:/bin HOME="$work/home" "$work/usr/local/bin/vclaude" >/dev/null 2>"$work/vclaude.err"; then
  fail "vclaude must exit non-zero without a key"
fi
grep -q "$key_file" "$work/vclaude.err" || fail "vclaude hint must name the key file"
[ ! -e "$work/claude-env" ] || fail "vclaude must not run claude without a key"

# 4b. Pasted key (with stray whitespace) → gateway env reaches claude; args pass through.
printf ' vck_test_key\n\n' > "$key_file"
env -i PATH=/usr/bin:/bin HOME="$work/home" ANTHROPIC_API_KEY=poison \
  "$work/usr/local/bin/vclaude" -p 'hello world' >/dev/null 2>&1 \
  || fail "vclaude must exec claude when a key exists"
grep -qx 'ANTHROPIC_AUTH_TOKEN=vck_test_key' "$work/claude-env" || fail "token must be trimmed and exported"
grep -qx 'ANTHROPIC_API_KEY=' "$work/claude-env" || fail "ANTHROPIC_API_KEY must be forced empty"
grep -qx 'ANTHROPIC_BASE_URL=https://ai-gateway.vercel.sh/claude-code' "$work/claude-env" || fail "base url missing"
grep -qx 'CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1' "$work/claude-env" || fail "model discovery flag missing"
[ "$(cat "$work/claude-args")" = $'-p\nhello world' ] || fail "vclaude must pass arguments through"

# 4c. AI_GATEWAY_API_KEY in the environment wins over the file; vcodex gets -c overrides.
env -i PATH=/usr/bin:/bin HOME="$work/home" AI_GATEWAY_API_KEY=vck_from_env \
  "$work/usr/local/bin/vcodex" exec 'say hi' >/dev/null 2>&1 || fail "vcodex must exec codex"
grep -qx 'AI_GATEWAY_API_KEY=vck_from_env' "$work/codex-env" || fail "env key must win over the file"
expected_codex_args=$'-c\nmodel_provider=vercel\n-c\nmodel_providers.vercel.name="Vercel AI Gateway"\n-c\nmodel_providers.vercel.base_url="https://ai-gateway.vercel.sh/codex/v1"\n-c\nmodel_providers.vercel.env_key="AI_GATEWAY_API_KEY"\n-c\nmodel_providers.vercel.wire_api="responses"\n-c\nmodel="openai/custom-model"\nexec\nsay hi'
[ "$(cat "$work/codex-args")" = "$expected_codex_args" ] || fail "vcodex argument list drifted: $(cat "$work/codex-args")"

# 5. Re-run is idempotent and never rewrites an existing key (content kept, mode enforced).
chmod 644 "$key_file"
: > "$work/paseo.log"
before="$(sha256sum "$work/usr/local/bin/vclaude" "$work/usr/local/bin/vcodex" "$work/home/.paseo/config.json")"
run_concern || fail "re-run must succeed"
[ "$before" = "$(sha256sum "$work/usr/local/bin/vclaude" "$work/usr/local/bin/vcodex" "$work/home/.paseo/config.json")" ] \
  || fail "re-run must not change wrappers or paseo config"
[ "$(tr -d '[:space:]' < "$key_file")" = vck_test_key ] || fail "existing key content must be preserved"
[ "$(stat -c %a "$key_file")" = 600 ] || fail "key file mode must be re-enforced to 0600"

# 6. Missing codex binary → vcodex withdrawn, vclaude and its provider remain.
mv "$work/home/.local/bin/codex" "$work/codex.hidden"
run_concern || fail "converge must succeed when codex is absent"
[ ! -e "$work/usr/local/bin/vcodex" ] || fail "vcodex must be withdrawn when codex is missing"
[ -x "$work/usr/local/bin/vclaude" ] || fail "vclaude must remain when only codex is missing"
jq -e '(.agents.providers | has("vcodex") | not) and .agents.providers.vclaude.extends == "claude"' \
  "$work/home/.paseo/config.json" >/dev/null || fail "paseo must drop vcodex when its binary is missing"
mv "$work/codex.hidden" "$work/home/.local/bin/codex"
run_concern || fail "converge must succeed once codex is back"
[ -x "$work/usr/local/bin/vcodex" ] || fail "vcodex must be republished"

# 7. Malformed codex_model → fatal, nothing rewritten.
before="$(sha256sum "$work/usr/local/bin/vcodex")"
printf '%s\n' '{"schema":1,"scripts":{},"env":{},"vercel_ai_gateway":{"codex_model":"gpt-6-astra"}}' > "$work/state/manifest.json"
if run_concern 2>/dev/null; then fail "codex_model without provider/ must be fatal"; fi
printf '%s\n' '{"schema":1,"scripts":{},"env":{},"vercel_ai_gateway":{"codex_model":"openai/x\" -c approval_policy=never"}}' > "$work/state/manifest.json"
if run_concern 2>/dev/null; then fail "codex_model with quotes must be fatal"; fi
[ "$before" = "$(sha256sum "$work/usr/local/bin/vcodex")" ] || fail "fatal input must leave vcodex unchanged"

# 8. Paseo reload failure is fatal; legacy CLI without reload only warns.
printf '%s\n' "$enabled_manifest" > "$work/state/manifest.json"
if DEVBOX_TEST_PASEO_RELOAD_FAIL=1 run_concern 2>/dev/null; then fail "paseo reload failure must be fatal"; fi
DEVBOX_TEST_PASEO_LEGACY=1 run_concern 2>"$work/legacy.err" || fail "legacy paseo must not fail the concern"
grep -q 'no reload command' "$work/legacy.err" || fail "legacy paseo must warn about restart"

# 9. Disable → wrappers and providers removed, unrelated config and key kept, paseo reloaded.
: > "$work/paseo.log"
printf '%s\n' "$disabled_manifest" > "$work/state/manifest.json"
run_concern || fail "disable must succeed"
[ ! -e "$work/usr/local/bin/vclaude" ] || fail "vclaude must be removed on disable"
[ ! -e "$work/usr/local/bin/vcodex" ] || fail "vcodex must be removed on disable"
jq -e '(.agents.providers | has("vclaude") or has("vcodex") | not)
  and .agents.providers.opencode.enabled == true
  and .features.webUi.enabled == false' "$work/home/.paseo/config.json" >/dev/null \
  || fail "disable must remove only the managed providers"
grep -qx 'reload --json' "$work/paseo.log" || fail "disable must reload paseo"
[ "$(tr -d '[:space:]' < "$key_file")" = vck_test_key ] || fail "disable must keep the dev's key file"
: > "$work/paseo.log"
run_concern || fail "second disable must succeed"
[ ! -s "$work/paseo.log" ] || fail "second disable must not reload paseo again"

# 10. Malformed manifest → fatal, state untouched.
printf 'not json\n' > "$work/state/manifest.json"
if run_concern 2>/dev/null; then fail "malformed manifest must be fatal"; fi

echo "PASS: devbox-vercel-gateway-test"
