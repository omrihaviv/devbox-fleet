#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONCERN="$repo_root/scripts/gcp/devbox-bedrock-config"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$CONCERN" ] || fail "scripts/gcp/devbox-bedrock-config missing or not executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state" "$work/home" "$work/etc" \
  "$work/usr/local/bin" "$work/home/.local/bin"

run_concern() {
  DEVBOX_RUNTIME_STATE_DIR="$work/state" \
  DEVBOX_DEV_HOME="$work/home" \
  DEVBOX_BEDROCK_CONFIG="$work/etc/bedrock.json" \
  DEVBOX_CLAUDE_MANAGED_SETTINGS="$work/etc/claude-managed-settings.json" \
  DEVBOX_CLAUDE_SUCCESS_FILE="$work/state/claude-code-installed" \
  DEVBOX_CLAUDE_BIN="$work/home/.local/bin/claude" \
  DEVBOX_BCLAUDE_BIN="$work/usr/local/bin/bclaude" \
  DEVBOX_BDCC_BIN="$work/usr/local/bin/bdcc" \
  DEVBOX_PASEO_CONFIG_FILE="$work/home/.paseo/config.json" \
  DEVBOX_SKIP_ROOT_CHECK=1 \
  bash "$CONCERN"
}

# Run the rendered wrapper with a stub `claude` on PATH and echo the
# environment that stub actually received. We report ONLY the stub's captured
# environment: keying off the stub's own env is what catches a wrapper whose
# env handling split, leaving the real claude to run without the toggle.
bclaude_runtime_env() {
  local launcher="${1:-$work/usr/local/bin/bclaude}"
  local out
  out="$(mktemp "$work/claude-env.XXXXXX")"
  cat > "$work/home/.local/bin/claude" <<STUB
#!/usr/bin/env bash
env > "$out"
printf '%s\n' "\$@" > "$work/claude-last-args"
STUB
  chmod +x "$work/home/.local/bin/claude"
  # POISON every credential selector: the wrapper must strip all of them so
  # the awsCredentialExport hook stays claude's only credential source.
  env -i PATH="/usr/bin:/bin" HOME="$work/home" \
    AWS_PROFILE=poison-profile \
    AWS_DEFAULT_PROFILE=poison-default-profile \
    AWS_ACCESS_KEY_ID=POISONKEY \
    AWS_SECRET_ACCESS_KEY=poisonsecret \
    AWS_SESSION_TOKEN=poisontoken \
    AWS_SECURITY_TOKEN=poisonsecurity \
    AWS_CREDENTIAL_EXPIRATION=poisonexpiry \
    AWS_BEARER_TOKEN_BEDROCK=poisonbearer \
    "$launcher" >/dev/null 2>&1
  cat "$out"
}

# The credential-selector set is read out of the concern itself, so adding a
# variable there cannot silently skip its assertion here.
credential_selectors() {
  sed -n '/^CREDENTIAL_SELECTORS=(/,/^)/p' "$CONCERN" \
    | sed -e '1d' -e '$d' -e 's/[[:space:]]//g' \
    | grep -v '^$'
}

# If the `^CREDENTIAL_SELECTORS=(` anchor above ever stops matching (a
# rename, a reindent, the array collapsed to one line), `sed` emits nothing,
# its exit status is discarded by the pipeline, and every assertion below
# that depends on this reader would silently vanish with the suite still
# green. Make the invariant real, once, and reuse the checked result instead
# of re-invoking the reader.
mapfile -t sels < <(credential_selectors)
[ "${#sels[@]}" -eq 8 ] \
  || fail "credential_selectors() read ${#sels[@]} selectors out of the concern, expected 8"

# 1. No manifest / no bedrock keys → clean no-op.
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {}}
EOF
run_concern || fail "must exit 0 when bedrock keys are absent"
[ ! -f "$work/etc/bedrock.json" ] || fail "must not write bedrock.json without manifest keys"
[ ! -f "$work/home/.bashrc" ] || fail "must not create .bashrc without manifest keys"
[ ! -e "$work/usr/local/bin/bclaude" ] || fail "must not publish bclaude without manifest keys"
[ ! -e "$work/usr/local/bin/bdcc" ] || fail "must not publish bdcc without manifest keys"

# 2. Full config: profile + bclaude/bdcc wrappers published; personal content preserved.
# Pre-seed managed settings with an unrelated key (must survive the additive
# merge) AND the legacy v2 awsAuthRefresh key (must be removed).
printf '%s' '{"someOtherManagedSetting": true, "awsAuthRefresh": "/usr/local/bin/devbox-aws-refresh"}' \
  > "$work/etc/claude-managed-settings.json"
cat > "$work/home/.bashrc" <<'EOF'
# my personal stuff
alias ll='ls -la'
EOF
mkdir -p "$work/home/.aws"
cat > "$work/home/.aws/config" <<'EOF'
[default]
region = il-central-1
EOF
# Pre-seed a personal codex config: user keys must survive below the
# prepended managed block, and a stale v1 profile file must be removed.
mkdir -p "$work/home/.codex"
printf 'personal_key = "kept"\n' > "$work/home/.codex/config.toml"
printf 'model_provider = "amazon-bedrock"\n' > "$work/home/.codex/bedrock.config.toml"

cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation",
   "model_env": {
     "CLAUDE_CODE_USE_MANTLE": "1",
     "ANTHROPIC_MODEL": "anthropic.claude-fable-5[1m]",
     "ANTHROPIC_DEFAULT_OPUS_MODEL": "global.anthropic.claude-opus-5[1m]"
   },
   "available_models": ["anthropic.claude-fable-5[1m]", "global.anthropic.claude-opus-5[1m]"],
   "codex_config": {"model": "openai.gpt-5.6-terra", "model_reasoning_effort": "xhigh"}
 }}
EOF
: > "$work/state/claude-code-installed"
run_concern || fail "concern failed on full config"

jq -e '.role_arn and .region and .audience' "$work/etc/bedrock.json" >/dev/null \
  || fail "bedrock.json not written correctly"

grep -q '^\[default\]' "$work/home/.aws/config" || fail "default AWS profile must survive"
grep -q '^\[profile devbox-bedrock\]' "$work/home/.aws/config" || fail "devbox-bedrock profile missing"
grep -q 'credential_process = /usr/local/bin/devbox-aws-creds' "$work/home/.aws/config" \
  || fail "profile must use the credential_process helper"

grep -q "alias ll='ls -la'" "$work/home/.bashrc" || fail "personal .bashrc content must survive"
# The bashrc block no longer exists at all -- bclaude/bdcc are executables now.
grep -q '>>> devbox bedrock >>>' "$work/home/.bashrc" \
  && fail "the retired bashrc block start marker must not be re-rendered"
grep -q '<<< devbox bedrock <<<' "$work/home/.bashrc" \
  && fail "the retired bashrc block end marker must not be re-rendered"
grep -q 'bclaude() {' "$work/home/.bashrc" \
  && fail "the bclaude shell function must not exist -- it would shadow the wrapper"
grep -q 'bdcc() {' "$work/home/.bashrc" \
  && fail "the bdcc shell function must not exist -- it would shadow the wrapper"

# The wrapper: one `-u` per credential selector, read out of the concern
# itself so a new selector there cannot silently skip its assertion here.
for selector in "${sels[@]}"; do
  grep -q -- "-u $selector" "$work/usr/local/bin/bclaude" \
    || fail "wrapper must strip inherited $selector before launching claude"
done
# No AWS profile ASSIGNMENT may reach claude (the `-u AWS_PROFILE` flag above
# has no `=`, so it cannot false-positive this check).
grep -q 'AWS_PROFILE=' "$work/usr/local/bin/bclaude" \
  && fail "no AWS profile may reach claude — the awsCredentialExport hook is its only credential source"
# Managed settings: awsCredentialExport wired to the helper, legacy
# awsAuthRefresh removed, unrelated keys survive (additive merge).
jq -re '.awsCredentialExport == "/usr/local/bin/devbox-aws-creds"' "$work/etc/claude-managed-settings.json" >/dev/null \
  || fail "managed settings must wire awsCredentialExport to devbox-aws-creds"
jq -re 'has("awsAuthRefresh") | not' "$work/etc/claude-managed-settings.json" >/dev/null \
  || fail "legacy v2 awsAuthRefresh key must be removed from managed settings"
jq -re '.someOtherManagedSetting == true' "$work/etc/claude-managed-settings.json" >/dev/null \
  || fail "pre-existing managed settings keys must survive the merge"
grep -q 'CLAUDE_CODE_USE_BEDROCK=1' "$work/usr/local/bin/bclaude" || fail "bedrock toggle missing"
grep -qF 'ANTHROPIC_MODEL=anthropic.claude-fable-5\[1m\]' "$work/usr/local/bin/bclaude" || fail "1M model_env not rendered"
grep -qxF '  ANTHROPIC_DEFAULT_OPUS_MODEL=global.anthropic.claude-opus-5\[1m\] \' "$work/usr/local/bin/bclaude" \
  || fail "default Opus model_env assignment not rendered"
# The %q-escaped form of the --settings JSON, computed the same way the
# renderer computes it, must appear verbatim in the wrapper.
expected_settings_q="$(printf '%q' '{"availableModels":["anthropic.claude-fable-5[1m]","global.anthropic.claude-opus-5[1m]"]}')"
grep -qF -- "--settings $expected_settings_q" "$work/usr/local/bin/bclaude" \
  || fail "bclaude must carry the availableModels --settings JSON from the manifest"
if grep -q 'claude-opus-4-8' "$work/usr/local/bin/bclaude"; then
  fail "rendered Claude Bedrock config must not retain Claude Opus 4.8"
fi
bash -n "$work/usr/local/bin/bclaude" || fail "rendered wrapper (full config) is not valid bash"

# Runtime: `bclaude` must hand the bedrock toggle and a model pin to `claude`,
# and must strip every poisoned AWS credential variable -- publishing the
# wrapper file is not enough.
rt_full="$(bclaude_runtime_env)"
if printf '%s\n' "$rt_full" | grep -q '^AWS_PROFILE='; then
  fail "inherited AWS_PROFILE leaked into claude's env — it can abort claude's credential chain"
fi
if printf '%s\n' "$rt_full" | grep -qE '^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)='; then
  fail "inherited static AWS keys leaked into claude's env — they would mask the awsCredentialExport hook"
fi
printf '%s\n' "$rt_full" | grep -q '^CLAUDE_CODE_USE_BEDROCK=1$' \
  || fail "bclaude must export CLAUDE_CODE_USE_BEDROCK=1 to claude (full config)"
printf '%s\n' "$rt_full" | grep -q '^ANTHROPIC_MODEL=anthropic\.claude-fable-5\[1m\]$' \
  || fail "bclaude must export the 1M Fable model_env pin to claude (full config)"
printf '%s\n' "$rt_full" | grep -qxF 'ANTHROPIC_DEFAULT_OPUS_MODEL=global.anthropic.claude-opus-5[1m]' \
  || fail "bclaude must export the 1M default Opus model_env pin to claude (full config)"
# The --settings JSON must reach claude as exactly two argv entries — this is
# what proves the single-quote embedding in the rendered wrapper parses.
[ "$(sed -n 1p "$work/claude-last-args")" = "--settings" ] \
  || fail "claude must receive --settings as its first argument"
[ "$(sed -n 2p "$work/claude-last-args")" = '{"availableModels":["anthropic.claude-fable-5[1m]","global.anthropic.claude-opus-5[1m]"]}' ] \
  || fail "claude must receive the availableModels JSON as one argument"

# bdcc: bclaude with permission prompts disabled — must inherit the full
# bedrock env and add exactly the skip-permissions flag.
[ -x "$work/usr/local/bin/bdcc" ] || fail "bdcc was not published"
rt_bdcc="$(bclaude_runtime_env "$work/usr/local/bin/bdcc")"
printf '%s\n' "$rt_bdcc" | grep -q '^CLAUDE_CODE_USE_BEDROCK=1$' \
  || fail "bdcc must inherit bclaude's bedrock env"
if printf '%s\n' "$rt_bdcc" | grep -q '^AWS_PROFILE='; then
  fail "inherited AWS_PROFILE leaked into claude's env via bdcc"
fi
grep -qx -- '--dangerously-skip-permissions' "$work/claude-last-args" \
  || fail "bdcc must pass --dangerously-skip-permissions to claude"

# codex: Bedrock by default via a SEEDED block PREPENDED to config.toml —
# hash-gated: the devbox-render line records the machine-written body's
# sha256, and converge re-renders only while the body still matches it.
codex_cfg="$work/home/.codex/config.toml"
codex_block() { awk '/>>> devbox codex >>>/{f=1;next} /<<< devbox codex <<</{f=0} f' "$codex_cfg"; }
codex_body() { codex_block | grep -v '^# devbox-render: '; }
head -1 "$codex_cfg" | grep -q '>>> devbox codex >>>' \
  || fail "codex block must be PREPENDED (top-level keys after a user table would join it)"
[ "$(codex_body | sha256sum | cut -d' ' -f1)" = "$(codex_block | sed -n 's/^# devbox-render: //p')" ] \
  || fail "devbox-render hash must match the rendered body (machine-state contract)"
for line in \
  'model_provider = "amazon-bedrock"' \
  'model = "openai.gpt-5.6-terra"' \
  'model_reasoning_effort = "xhigh"' \
  'model_providers.amazon-bedrock.aws.profile = "devbox-bedrock"' \
  'model_providers.amazon-bedrock.aws.region = "us-east-1"'; do
  codex_body | grep -qxF "$line" || fail "codex block missing: $line"
done
grep -q '^personal_key = "kept"$' "$codex_cfg" \
  || fail "user content in codex config.toml must survive"
[ ! -f "$work/home/.codex/bedrock.config.toml" ] \
  || fail "v1 profile-file variant must be removed"
if grep -q 'bcodex' "$work/home/.bashrc"; then
  fail "bcodex must no longer be rendered — plain codex defaults to Bedrock"
fi

# 3. Idempotence: second run changes nothing.
before="$(sha256sum "$work/home/.bashrc" "$work/home/.aws/config" "$work/home/.codex/config.toml" \
  "$work/usr/local/bin/bclaude" "$work/usr/local/bin/bdcc" | sha256sum)"
run_concern || fail "second run failed"
after="$(sha256sum "$work/home/.bashrc" "$work/home/.aws/config" "$work/home/.codex/config.toml" \
  "$work/usr/local/bin/bclaude" "$work/usr/local/bin/bdcc" | sha256sum)"
[ "$before" = "$after" ] || fail "second run must be a byte-identical no-op"

# 4. Changed pins re-render ONLY the wrapper.
jq '.bedrock.model_env.ANTHROPIC_MODEL = "anthropic.claude-fable-6"' \
  "$work/state/manifest.json" > "$work/state/manifest2.json"
mv "$work/state/manifest2.json" "$work/state/manifest.json"
run_concern || fail "re-render run failed"
grep -q 'anthropic.claude-fable-6' "$work/usr/local/bin/bclaude" || fail "wrapper not re-rendered on pin change"
grep -q "alias ll='ls -la'" "$work/home/.bashrc" || fail "personal content lost on re-render"

# 5. Bedrock WITHOUT model_env: still a supported manifest shape. In the
#    retired bashrc design, an empty model_env expansion left a bare
#    (unescaped) blank line in the CLAUDE_BEDROCK_ENV `\`-continuation
#    chain, terminating the value early and truncating the env so `bclaude`
#    ran `claude` without the bedrock toggle. The wrapper renders one `%q`-
#    escaped `env` argument per pin with no intermediate variable and no
#    continuation, so that failure mode is gone by construction; still
#    assert the rendered wrapper is intact AND that `claude` actually
#    receives the bedrock toggle (and no leaked AWS vars) at runtime.
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation"
 }}
EOF
codex_before_bare="$(cat "$work/home/.codex/config.toml")"
run_concern || fail "concern failed on bedrock config without model_env"
# No codex_config in the manifest -> the codex config is left alone
# (existing managed block included; removal is not the concern's job).
[ "$(cat "$work/home/.codex/config.toml")" = "$codex_before_bare" ] \
  || fail "codex config.toml must be untouched when the manifest has no codex_config"
grep -q 'CLAUDE_CODE_USE_BEDROCK=1' "$work/usr/local/bin/bclaude" \
  || fail "bedrock toggle missing without model_env"
# The renderer builds the wrapper with one `printf %q` per value and no
# `\`-continuation inside a quoted string, so the old failure mode (an empty
# model_env expansion leaving a bare blank line that truncated the env) is
# gone by construction. The generalised check: the rendered wrapper must
# still be syntactically valid bash.
bash -n "$work/usr/local/bin/bclaude" || fail "rendered wrapper (no model_env) is not valid bash"
rt_bare="$(bclaude_runtime_env)"
if printf '%s\n' "$rt_bare" | grep -q '^AWS_PROFILE='; then
  fail "inherited AWS_PROFILE leaked into claude's env (no model_env)"
fi
printf '%s\n' "$rt_bare" | grep -q '^CLAUDE_CODE_USE_BEDROCK=1$' \
  || fail "bclaude must export CLAUDE_CODE_USE_BEDROCK=1 to claude (no model_env)"
if grep -q -- '--settings' "$work/usr/local/bin/bclaude"; then
  fail "bclaude must omit --settings when the manifest has no available_models"
fi
# 6. Codex block edit semantics: fleet updates re-render an untouched
#    block; ANY dev edit inside it freezes the whole file; deleting the
#    block opts back in (re-seeds); the legacy bedrock-marker first ship
#    migrates to the seeded block.
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation",
   "codex_config": {"model": "openai.gpt-6"}
 }}
EOF
run_concern || fail "codex fleet-update run failed"
codex_body | grep -qxF 'model = "openai.gpt-6"' \
  || fail "a fleet config update must re-render an untouched codex block"
grep -q '^personal_key = "kept"$' "$codex_cfg" || fail "user content lost on codex re-render"

sed -i 's/^model_provider = "amazon-bedrock"$/model_provider = "openai"/' "$codex_cfg"
frozen="$(cat "$codex_cfg")"
run_concern || fail "run after dev edit failed"
[ "$(cat "$codex_cfg")" = "$frozen" ] || fail "a dev-edited codex block must never be rewritten"
jq '.bedrock.codex_config.model = "openai.gpt-7"' "$work/state/manifest.json" > "$work/state/m2.json"
mv "$work/state/m2.json" "$work/state/manifest.json"
run_concern || fail "fleet-update run after dev edit failed"
[ "$(cat "$codex_cfg")" = "$frozen" ] \
  || fail "fleet updates must not clobber a dev-edited codex block"

awk '/>>> devbox codex >>>/{f=1;next} /<<< devbox codex <<</{f=0;next} !f' "$codex_cfg" > "$codex_cfg.tmp"
mv "$codex_cfg.tmp" "$codex_cfg"
run_concern || fail "re-seed run failed"
head -1 "$codex_cfg" | grep -q '>>> devbox codex >>>' || fail "a deleted codex block must re-seed"
codex_body | grep -qxF 'model = "openai.gpt-7"' \
  || fail "a re-seeded block must carry the current fleet config"

cat > "$codex_cfg" <<'EOF'
# >>> devbox bedrock >>> (managed by devbox-bedrock-config; edits inside are overwritten)
model_provider = "amazon-bedrock"
old = "stuff"
# <<< devbox bedrock <<<
user_key = "still-here"
EOF
run_concern || fail "legacy migration run failed"
if grep -q 'devbox bedrock' "$codex_cfg"; then
  fail "the legacy bedrock-marker block must be stripped from codex config"
fi
head -1 "$codex_cfg" | grep -q '>>> devbox codex >>>' || fail "migration must seed the codex block"
grep -q '^user_key = "still-here"$' "$codex_cfg" || fail "user content lost in legacy migration"

echo "== re-seed the canonical manifest for the wrapper/provider sections"
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation",
   "model_env": {
     "CLAUDE_CODE_USE_MANTLE": "1",
     "ANTHROPIC_MODEL": "anthropic.claude-fable-5[1m]",
     "ANTHROPIC_DEFAULT_OPUS_MODEL": "global.anthropic.claude-opus-5[1m]"
   },
   "available_models": ["anthropic.claude-fable-5[1m]", "global.anthropic.claude-opus-5[1m]"],
   "codex_config": {"model": "openai.gpt-5.6-terra", "model_reasoning_effort": "xhigh"}
 }}
EOF

# The fail-safe case. Without this gate a failed claude install strips a
# working bclaude function and publishes a wrapper pointing at nothing.
echo "== gate: no claude marker -> nothing is published or removed"
# Establish the "never verified yet" precondition: earlier sections above
# ran with the marker present (that is required to exercise the wrapper at
# all), so clear what they published before proving a fresh, unverified box
# gets nothing.
rm -f "$work/usr/local/bin/bclaude" "$work/usr/local/bin/bdcc"
rm -f "$work/state/claude-code-installed"
printf '# my personal stuff\n' > "$work/home/.bashrc"
run_concern >/dev/null
[ ! -e "$work/usr/local/bin/bclaude" ] || fail "wrapper published without a claude marker"
[ ! -e "$work/usr/local/bin/bdcc" ] || fail "bdcc published without a claude marker"
[ "$(cat "$work/home/.bashrc")" = "# my personal stuff" ] \
  || fail "bashrc was modified without a claude marker"
# The other concerns must still converge -- they do not depend on claude.
[ -f "$work/etc/bedrock.json" ] || fail "bedrock.json was skipped by the gate"
grep -q 'devbox-bedrock' "$work/home/.aws/config" \
  || fail "aws profile was skipped by the gate"

echo "== wrapper strips every credential selector"
: > "$work/state/claude-code-installed"
run_concern >/dev/null
[ -x "$work/usr/local/bin/bclaude" ] || fail "bclaude was not published"
runtime_env="$(bclaude_runtime_env)"
grep -qx 'CLAUDE_CODE_USE_BEDROCK=1' <<< "$runtime_env" \
  || fail "wrapper did not set CLAUDE_CODE_USE_BEDROCK"
grep -qx 'AWS_REGION=us-east-1' <<< "$runtime_env" \
  || fail "wrapper did not set AWS_REGION"
grep -qxF 'ANTHROPIC_MODEL=anthropic.claude-fable-5[1m]' <<< "$runtime_env" \
  || fail "wrapper did not set the 1M model pin"
for selector in "${sels[@]}"; do
  if grep -q "^$selector=" <<< "$runtime_env"; then
    fail "wrapper leaked $selector to claude"
  fi
done

echo "== bdcc adds exactly the skip-permissions flag"
bdcc_env="$(bclaude_runtime_env "$work/usr/local/bin/bdcc")"
grep -qx 'CLAUDE_CODE_USE_BEDROCK=1' <<< "$bdcc_env" \
  || fail "bdcc lost the bedrock toggle"
grep -qxF -- '--dangerously-skip-permissions' "$work/claude-last-args" \
  || fail "bdcc did not pass --dangerously-skip-permissions"

echo "== the bashrc block is gone and personal content survives"
grep -qF 'my personal stuff' "$work/home/.bashrc" \
  || fail "personal bashrc content was lost"
grep -qF 'devbox bedrock' "$work/home/.bashrc" \
  && fail "the managed bashrc block was re-rendered"
grep -qF 'bclaude()' "$work/home/.bashrc" \
  && fail "the bclaude shell function survived and would shadow the wrapper"

# The real migration case: a box whose ~/.bashrc ALREADY has the old
# marker-delimited block (this is the one-way door in the rollout -- every
# other test above starts from personal-content-only, so this is the only
# place the actual strip-in-place migration is exercised).
echo "== migration: an existing old-style bashrc block is retired, personal content survives"
cat > "$work/home/.bashrc" <<'EOF'
# personal alias above the block
alias gs='git status'
# >>> devbox bedrock >>> (managed by devbox-bedrock-config; edits inside are overwritten)
CLAUDE_BEDROCK_ENV="AWS_REGION=us-east-1 \
CLAUDE_CODE_USE_BEDROCK=1"

bclaude() {
  env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE -u AWS_ACCESS_KEY_ID \
    -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    $CLAUDE_BEDROCK_ENV claude "$@"
}

bdcc() {
  bclaude --dangerously-skip-permissions "$@"
}
# <<< devbox bedrock <<<
# personal alias below the block
alias gl='git log --oneline'
EOF
: > "$work/state/claude-code-installed"
run_concern >/dev/null || fail "migration run failed"
expected_after_migration="$(cat <<'EXPECTED'
# personal alias above the block
alias gs='git status'
# personal alias below the block
alias gl='git log --oneline'
EXPECTED
)"
[ "$(cat "$work/home/.bashrc")" = "$expected_after_migration" ] \
  || fail "personal content above and below the legacy block must survive byte-for-byte"
grep -qF 'devbox bedrock' "$work/home/.bashrc" \
  && fail "the legacy bashrc block must be stripped during migration"
[ "$(grep -c 'devbox bedrock' "$work/home/.bashrc")" -eq 0 ] \
  || fail "no marker line may remain after migration"

# A manifest whose .bedrock.model_env is present but not an object (a
# string, here -- `// {}` only covers null/absent) must make jq fail. That
# failure must propagate and fail the concern outright, not just render a
# wrapper missing its model pins while the concern still prints "converged".
echo "== a non-object model_env fails the concern instead of publishing a pin-less wrapper"
good_wrapper_before="$(cat "$work/usr/local/bin/bclaude")"
jq '.bedrock.model_env = "not-an-object"' "$work/state/manifest.json" > "$work/state/manifest-bad.json"
mv "$work/state/manifest-bad.json" "$work/state/manifest.json"
if run_concern >/dev/null 2>&1; then
  fail "concern must fail when .bedrock.model_env is not an object"
fi
[ "$(cat "$work/usr/local/bin/bclaude")" = "$good_wrapper_before" ] \
  || fail "a bad manifest must not overwrite a good wrapper with a degraded one"
grep -qF 'ANTHROPIC_MODEL=anthropic.claude-fable-5\[1m\]' "$work/usr/local/bin/bclaude" \
  || fail "the previously published wrapper lost its model pins after a failed run"

# Re-seed: this is a linear script, and the next section (were one added)
# must not read the broken fixture above.
echo "== re-seed the canonical manifest after the bad-model_env fixture"
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation",
   "model_env": {
     "CLAUDE_CODE_USE_MANTLE": "1",
     "ANTHROPIC_MODEL": "anthropic.claude-fable-5[1m]",
     "ANTHROPIC_DEFAULT_OPUS_MODEL": "global.anthropic.claude-opus-5[1m]"
   },
   "available_models": ["anthropic.claude-fable-5[1m]", "global.anthropic.claude-opus-5[1m]"],
   "codex_config": {"model": "openai.gpt-5.6-terra", "model_reasoning_effort": "xhigh"}
 }}
EOF

# A manifest whose .bedrock.model_env sets a credential selector (AWS_PROFILE
# here) must make the concern fail loudly, not render a wrapper that re-sets,
# on the very command line that just stripped it, the variable Claude Code
# prefers over env credentials (verified on-box, 2.1.207 -- setting
# AWS_PROFILE aborts the whole credential chain even with valid keys
# injected). This enforces the hazard rather than merely documenting it, the
# same posture as the non-object model_env fix above.
echo "== a model_env credential-selector collision fails the concern instead of publishing a compromised wrapper"
good_wrapper_before="$(cat "$work/usr/local/bin/bclaude")"
jq '.bedrock.model_env.AWS_PROFILE = "devbox-bedrock"' "$work/state/manifest.json" \
  > "$work/state/manifest-bad-selector.json"
mv "$work/state/manifest-bad-selector.json" "$work/state/manifest.json"
if run_concern >/dev/null 2>&1; then
  fail "concern must fail when .bedrock.model_env sets a credential selector"
fi
[ "$(cat "$work/usr/local/bin/bclaude")" = "$good_wrapper_before" ] \
  || fail "a model_env credential-selector collision must not overwrite a good wrapper"

echo "== re-seed the canonical manifest after the bad-selector fixture"
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation",
   "model_env": {
     "CLAUDE_CODE_USE_MANTLE": "1",
     "ANTHROPIC_MODEL": "anthropic.claude-fable-5[1m]",
     "ANTHROPIC_DEFAULT_OPUS_MODEL": "global.anthropic.claude-opus-5[1m]"
   },
   "available_models": ["anthropic.claude-fable-5[1m]", "global.anthropic.claude-opus-5[1m]"],
   "codex_config": {"model": "openai.gpt-5.6-terra", "model_reasoning_effort": "xhigh"}
 }}
EOF

echo "== paseo provider: merged, siblings preserved, mode restored"
mkdir -p "$work/home/.paseo"
cat > "$work/home/.paseo/config.json" <<'JSON'
{
  "version": 1,
  "daemon": {"listen": "100.1.2.3:6767", "relay": {"enabled": false}},
  "features": {"webUi": {"enabled": false}},
  "agents": {"providers": {"claude": {"enabled": true}}}
}
JSON
chmod 0600 "$work/home/.paseo/config.json"
: > "$work/state/claude-code-installed"
run_concern >/dev/null

cfg="$work/home/.paseo/config.json"
jq -e '.agents.providers.bclaude.extends == "claude"' "$cfg" >/dev/null \
  || fail "provider does not extend claude"
jq -e '.agents.providers.bclaude.label == "Claude (Bedrock)"' "$cfg" >/dev/null \
  || fail "provider label is wrong"
jq -e --arg bin "$work/usr/local/bin/bclaude" \
  '.agents.providers.bclaude.command == [$bin]' "$cfg" >/dev/null \
  || fail "provider command does not point at the wrapper"
jq -e '.daemon.listen == "100.1.2.3:6767"' "$cfg" >/dev/null \
  || fail "daemon config was clobbered"
jq -e '.agents.providers.claude.enabled == true' "$cfg" >/dev/null \
  || fail "sibling provider was clobbered"
[ "$(stat -c %a "$cfg")" = 600 ] || fail "config mode was not restored to 0600"

echo "== paseo provider: models carry labels and the default flag"
# The canonical fixture's available_models has exactly two entries:
# anthropic.claude-fable-5[1m] and global.anthropic.claude-opus-5[1m].
jq -e '.agents.providers.bclaude.models
       | length == 2
       and all(.[]; has("id") and has("label"))' "$cfg" >/dev/null \
  || fail "models list is missing ids or labels"
jq -e '.agents.providers.bclaude.models
       | map(.id) == ["anthropic.claude-fable-5[1m]", "global.anthropic.claude-opus-5[1m]"]' \
  "$cfg" >/dev/null \
  || fail "models list does not mirror available_models in order"
jq -e '.agents.providers.bclaude.models
       | map(select(.isDefault == true)) | length == 1' "$cfg" >/dev/null \
  || fail "exactly one model should be flagged default"
jq -e '.agents.providers.bclaude.models
       | map(select(.isDefault == true))[0].id == "anthropic.claude-fable-5[1m]"' \
  "$cfg" >/dev/null \
  || fail "isDefault is not on the ANTHROPIC_MODEL entry"

echo "== paseo provider: friendly labels and thinking ladders on the canonical models"
# Labels and thinking options are derived from the model id itself -- still
# no new fleet variable. Ladders mirror Paseo's builtin claude catalog,
# WITHOUT "ultracode": Bedrock does not support Ultra Code.
jq -e '.agents.providers.bclaude.models
       | map(.label) == ["Fable 5 (1M)", "Opus 5 (global, 1M)"]' "$cfg" >/dev/null \
  || fail "known Claude 1M ids must render friendly labels (family, version, routing, context)"
jq -e '.agents.providers.bclaude.models
       | all(.[]; .thinkingOptions | map(.id) == ["low","medium","high","xhigh","max"])' \
  "$cfg" >/dev/null \
  || fail "Fable 5 and Opus 5 must carry the full xhigh thinking ladder"
jq -e '.agents.providers.bclaude.models[0].thinkingOptions
       | map(.label) == ["Low","Medium","High","Extra High","Max"]' "$cfg" >/dev/null \
  || fail "thinking option labels must match Paseo's builtin wording"
jq -e '[.agents.providers.bclaude.models[] | .. | strings]
       | any(. == "ultracode") | not' "$cfg" >/dev/null \
  || fail "ultracode must never be rendered -- Bedrock does not support it"

echo "== paseo provider: label/ladder derivation across model shapes"
# haiku gets NO thinking options (matching the builtin catalog); a pre-xhigh
# model gets the standard ladder; an id that does not parse as an Anthropic
# Claude Bedrock id keeps the id verbatim and gets no thinking options.
jq '.bedrock.available_models = [
      "global.anthropic.claude-haiku-4-5-20251001-v1:0",
      "us.anthropic.claude-sonnet-4-6-20260220-v1:0",
      "custom.model-x"
    ]' "$work/state/manifest.json" > "$work/state/manifest-shapes.json"
mv "$work/state/manifest-shapes.json" "$work/state/manifest.json"
run_concern >/dev/null
jq -e '.agents.providers.bclaude.models | map(.label)
       == ["Haiku 4.5 (global)", "Sonnet 4.6 (us)", "custom.model-x"]' "$cfg" >/dev/null \
  || fail "labels wrong across haiku/dated/unknown id shapes"
jq -e '.agents.providers.bclaude.models[0] | has("thinkingOptions") | not' "$cfg" >/dev/null \
  || fail "haiku must not carry thinking options"
jq -e '.agents.providers.bclaude.models[1].thinkingOptions
       | map(.id) == ["low","medium","high","max"]' "$cfg" >/dev/null \
  || fail "a pre-xhigh model must get the standard ladder (no xhigh)"
jq -e '.agents.providers.bclaude.models[2] | has("thinkingOptions") | not' "$cfg" >/dev/null \
  || fail "an unrecognized id must not carry thinking options"
jq -e '[.agents.providers.bclaude.models[] | select(.isDefault == true)] | length == 0' \
  "$cfg" >/dev/null \
  || fail "no default flag when ANTHROPIC_MODEL is not in the list"

# Restore the canonical fixture and re-render for the sections below.
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation",
   "model_env": {
     "CLAUDE_CODE_USE_MANTLE": "1",
     "ANTHROPIC_MODEL": "anthropic.claude-fable-5[1m]",
     "ANTHROPIC_DEFAULT_OPUS_MODEL": "global.anthropic.claude-opus-5[1m]"
   },
   "available_models": ["anthropic.claude-fable-5[1m]", "global.anthropic.claude-opus-5[1m]"],
   "codex_config": {"model": "openai.gpt-5.6-terra", "model_reasoning_effort": "xhigh"}
 }}
EOF
run_concern >/dev/null

echo "== paseo provider: only ProviderOverrideSchema keys (strict config)"
jq -e '.agents.providers.bclaude | keys
       - ["extends","label","description","command","env","params","models","additionalModels","disallowedTools","enabled","order"]
       | length == 0' "$cfg" >/dev/null \
  || fail "provider carries a key outside ProviderOverrideSchema"

echo "== paseo provider: idempotent"
before="$(cat "$cfg")"
run_concern >/dev/null
[ "$before" = "$(cat "$cfg")" ] || fail "second run changed the paseo config"

echo "== paseo provider: absent config is skipped, malformed is refused"
rm -f "$cfg"
run_concern >/dev/null
[ ! -e "$cfg" ] || fail "concern created a paseo config that did not exist"
printf 'not json at all\n' > "$cfg"
run_concern >/dev/null 2>&1 || true
[ "$(cat "$cfg")" = "not json at all" ] \
  || fail "concern overwrote a malformed paseo config"

echo "== paseo provider: empty available_models omits the models key"
# Writing [] would replace Paseo's inherited model list with nothing and
# blank the dev's model picker -- the key must be OMITTED entirely. Seed a
# config that already carries a populated models list (as a real prior
# render would leave behind), so this proves an omission, not merely an
# absence that was already true before the run.
cat > "$cfg" <<'JSON'
{
  "version": 1,
  "daemon": {"listen": "100.1.2.3:6767", "relay": {"enabled": false}},
  "features": {"webUi": {"enabled": false}},
  "agents": {"providers": {
    "claude": {"enabled": true},
    "bclaude": {
      "extends": "claude",
      "label": "Claude (Bedrock)",
      "description": "Claude Code on Amazon Bedrock via the shared workload role",
      "command": ["/usr/local/bin/bclaude"],
      "models": [
        {"id": "anthropic.claude-fable-5", "label": "anthropic.claude-fable-5", "isDefault": true},
        {"id": "global.anthropic.claude-opus-5", "label": "global.anthropic.claude-opus-5"}
      ]
    }
  }}
}
JSON
chmod 0600 "$cfg"
jq '.bedrock.available_models = []' "$work/state/manifest.json" > "$work/state/manifest-empty-models.json"
mv "$work/state/manifest-empty-models.json" "$work/state/manifest.json"
run_concern >/dev/null

jq -e '.agents.providers.bclaude | has("models") | not' "$cfg" >/dev/null \
  || fail "empty available_models must omit the models key entirely, not [] or a stale list"
jq -e '.agents.providers.bclaude.extends == "claude"' "$cfg" >/dev/null \
  || fail "provider extends lost when available_models is empty"
jq -e '.agents.providers.bclaude.label == "Claude (Bedrock)"' "$cfg" >/dev/null \
  || fail "provider label lost when available_models is empty"
jq -e --arg bin "$work/usr/local/bin/bclaude" \
  '.agents.providers.bclaude.command == [$bin]' "$cfg" >/dev/null \
  || fail "provider command lost when available_models is empty"
jq -e '.daemon.listen == "100.1.2.3:6767"' "$cfg" >/dev/null \
  || fail "daemon config was clobbered when available_models is empty"
jq -e '.features.webUi.enabled == false' "$cfg" >/dev/null \
  || fail "features config was clobbered when available_models is empty"
jq -e '.agents.providers.claude.enabled == true' "$cfg" >/dev/null \
  || fail "sibling provider was clobbered when available_models is empty"

echo "== re-seed the canonical manifest after the empty-available_models fixture"
cat > "$work/state/manifest.json" <<'EOF'
{"schema": 1, "scripts": {}, "env": {},
 "bedrock": {
   "role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload",
   "region": "us-east-1",
   "audience": "devbox-fleet-aws-federation",
   "model_env": {
     "CLAUDE_CODE_USE_MANTLE": "1",
     "ANTHROPIC_MODEL": "anthropic.claude-fable-5[1m]",
     "ANTHROPIC_DEFAULT_OPUS_MODEL": "global.anthropic.claude-opus-5[1m]"
   },
   "available_models": ["anthropic.claude-fable-5[1m]", "global.anthropic.claude-opus-5[1m]"],
   "codex_config": {"model": "openai.gpt-5.6-terra", "model_reasoning_effort": "xhigh"}
 }}
EOF

echo "== paseo provider: valid JSON that is not an object is refused (type guard)"
# 'not json at all' above fails to PARSE, so it is refused at the render
# step's own jq call regardless of the 'type == object' guard -- that case
# alone cannot prove the guard exists. A literal `null` is the case that
# actually discriminates it: jq's `.foo = x` assignment auto-vivifies an
# object out of `null`, so without the guard this would be silently
# rendered into a full provider object instead of refused.
printf 'null\n' > "$cfg"
run_concern >/dev/null 2>&1 || true
[ "$(cat "$cfg")" = "null" ] \
  || fail "concern overwrote a config that was valid JSON but not an object (e.g. null)"

echo "PASS: devbox-bedrock-config-test"
