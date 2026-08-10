#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONVERGE="$repo_root/scripts/gcp/devbox-converge"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$CONVERGE" ] || fail "scripts/gcp/devbox-converge missing"
[ -x "$CONVERGE" ] || fail "scripts/gcp/devbox-converge not executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/install" "$work/state" "$work/gcs/runtime/manifest"

# --- fixture scripts the manifest points at ---
cat > "$work/payload-toolchain" <<'EOF'
#!/usr/bin/env bash
echo "toolchain ran with DEVBOX_SWAP_SIZE_GIB=$DEVBOX_SWAP_SIZE_GIB" >> "$DEVBOX_TEST_LOG"
EOF
cat > "$work/payload-memory" <<'EOF'
#!/usr/bin/env bash
echo "memory ran with DEVBOX_SWAP_SIZE_GIB=$DEVBOX_SWAP_SIZE_GIB" >> "$DEVBOX_TEST_LOG"
printf '%s\0%s\0%s\0%s\0' \
  "$DEVBOX_EARLYOOM_AVOID_REGEX" \
  "$DEVBOX_EARLYOOM_ENABLED" \
  "$DEVBOX_EARLYOOM_MEM_PCT" \
  "$DEVBOX_EARLYOOM_SWAP_PCT" \
  > "$DEVBOX_ENV_CAPTURE"
EOF
tool_sha="$(sha256sum "$work/payload-toolchain" | awk '{print $1}')"
mem_sha="$(sha256sum "$work/payload-memory" | awk '{print $1}')"
mkdir -p "$work/gcs/runtime/devbox-toolchain" "$work/gcs/runtime/devbox-memory-hotfix"
cp "$work/payload-toolchain" "$work/gcs/runtime/devbox-toolchain/$tool_sha"
cp "$work/payload-memory" "$work/gcs/runtime/devbox-memory-hotfix/$mem_sha"

cat > "$work/gcs/runtime/manifest.json" <<EOF
{
  "schema": 1,
  "scripts": {
    "devbox-toolchain": {"key": "runtime/devbox-toolchain/$tool_sha", "sha256": "$tool_sha"},
    "devbox-memory-hotfix": {"key": "runtime/devbox-memory-hotfix/$mem_sha", "sha256": "$mem_sha"}
  },
  "env": {
    "DEVBOX_SWAP_SIZE_GIB": "16",
    "DEVBOX_SWAPPINESS": "60",
    "DEVBOX_EARLYOOM_AVOID_REGEX": "^foo\\\\.bar$",
    "DEVBOX_EARLYOOM_ENABLED": "true",
    "DEVBOX_EARLYOOM_MEM_PCT": "8,4",
    "DEVBOX_EARLYOOM_SWAP_PCT": "15,8"
  }
}
EOF
manifest_sha="$(sha256sum "$work/gcs/runtime/manifest.json" | awk '{print $1}')"
cp "$work/gcs/runtime/manifest.json" "$work/gcs/runtime/manifest/$manifest_sha.json"
cp "$work/gcs/runtime/manifest.json" "$work/manifest.good.json"

# --- fake curl: serves gs objects from the fixture dir; serves metadata ---
cat > "$work/bin/curl" <<EOF
#!/usr/bin/env bash
# minimal fake: last arg is the URL; -o <file> writes output
out=""
url=""
args=("\$@")
for ((i=0; i<\${#args[@]}; i++)); do
  case "\${args[i]}" in
    -o) out="\${args[i+1]}" ;;
    http*) url="\${args[i]}" ;;
  esac
done
serve() { if [ -n "\$out" ]; then cat "\$1" > "\$out"; else cat "\$1"; fi; }
case "\$url" in
  *metadata*token*) echo '{"access_token":"fake-token","expires_in":3600}' ;;
  *metadata*devbox-swap-gib*) printf '24' ;;
  *storage.googleapis.com/fake-bucket/*)
    obj="\${url#*storage.googleapis.com/fake-bucket/}"
    [ -f "$work/gcs/\$obj" ] || exit 22
    serve "$work/gcs/\$obj"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$work/bin/curl"

for tool in logger flock; do
  cat > "$work/bin/$tool" <<'EOF'
#!/usr/bin/env bash
[ "${0##*/}" = "logger" ] && echo "logger: $*" >> "$DEVBOX_TEST_LOG"
exit 0
EOF
  chmod 0755 "$work/bin/$tool"
done
# flock fake must exec nothing — converge uses `flock -n 9` on an FD, which
# works natively; remove the fake so the real flock is used.
rm -f "$work/bin/flock"

export DEVBOX_TEST_LOG="$work/test.log"
export DEVBOX_ENV_CAPTURE="$work/env.capture"
touch "$DEVBOX_TEST_LOG"

run_converge() {
  PATH="$work/bin:$PATH" \
  DEVBOX_RUNTIME_BUCKET="fake-bucket" \
  DEVBOX_GCS_URL="https://storage.googleapis.com" \
  DEVBOX_METADATA_URL="http://metadata.google.internal/computeMetadata/v1" \
  DEVBOX_INSTALL_DIR="$work/install" \
  DEVBOX_RUNTIME_STATE_DIR="$work/state" \
  DEVBOX_SKIP_ROOT_CHECK=1 \
  bash "$CONVERGE" "$@"
}

# 1. Happy path: fetch, verify, install, run concerns with metadata override.
run_converge || fail "converge exited non-zero on happy path"
[ -x "$work/install/devbox-toolchain" ] || fail "devbox-toolchain not installed"
grep -q "memory ran with DEVBOX_SWAP_SIZE_GIB=24" "$DEVBOX_TEST_LOG" \
  || fail "metadata devbox-swap-gib=24 did not override manifest env (16)"
grep -q "devbox-converge-success manifest_sha=$manifest_sha" "$DEVBOX_TEST_LOG" \
  || fail "heartbeat log line with manifest sha missing"
printf '%s\0%s\0%s\0%s\0' '^foo\.bar$' true 8,4 15,8 > "$work/env.expected"
cmp -s "$work/env.expected" "$DEVBOX_ENV_CAPTURE" \
  || fail "manifest env values did not reach memory payload byte-for-byte"
[ -f "$work/state/manifest.json" ] || fail "manifest not saved to state dir"
[ -f "$work/state/converge.last-success" ] || fail "last-success marker missing"

# 2. --manifest-sha pins the candidate and self-verifies its content hash.
: > "$DEVBOX_TEST_LOG"
run_converge --manifest-sha "$manifest_sha" || fail "converge --manifest-sha failed"
grep -q "manifest_sha=$manifest_sha" "$DEVBOX_TEST_LOG" || fail "candidate run heartbeat missing"

# 3. Malformed env shape → jq failure is fatal; no stale-env dispatch/heartbeat.
jq '.env = 1' "$work/manifest.good.json" > "$work/gcs/runtime/manifest.json"
: > "$DEVBOX_TEST_LOG"
if run_converge >/tmp/gcp-converge-test.out 2>&1; then
  fail "converge must fail when manifest env cannot be encoded"
fi
if grep -q "devbox-converge-success" "$DEVBOX_TEST_LOG"; then
  fail "invalid manifest env must not emit a success heartbeat"
fi
cp "$work/manifest.good.json" "$work/gcs/runtime/manifest.json"

# 4. Corrupt script → converge refuses install and exits non-zero.
echo tampered >> "$work/gcs/runtime/devbox-toolchain/$tool_sha"
rm -f "$work/install/devbox-toolchain"
: > "$DEVBOX_TEST_LOG"
if run_converge; then fail "converge must exit non-zero when a script hash mismatches"; fi
[ ! -f "$work/install/devbox-toolchain" ] || fail "tampered script must not be installed"

echo "PASS: gcp-converge-test"
