#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMOTE="$repo_root/scripts/gcp/promote-runtime.sh"
SYNC="$repo_root/scripts/gcp/sync-converge.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$PROMOTE" ] || fail "scripts/gcp/promote-runtime.sh missing or not executable"
[ -x "$SYNC" ] || fail "scripts/gcp/sync-converge.sh missing or not executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Fake gcloud: records args; `storage objects describe` succeeds only for
# the "known" sha; `storage cp` records the copy.
known_sha="1111111111111111111111111111111111111111111111111111111111111111"
cat > "$work/bin/gcloud" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$work/gcloud-args"
case "\$*" in
  *"objects describe"*"$known_sha"*) exit 0 ;;
  *"objects describe"*) exit 1 ;;
  *"cp gs://"*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$work/bin/gcloud"

# Unknown sha → refuse, no copy.
if PATH="$work/bin:$PATH" DEVBOX_RUNTIME_BUCKET=fake-bucket \
   bash "$PROMOTE" "2222222222222222222222222222222222222222222222222222222222222222" >/dev/null 2>&1; then
  fail "must refuse a sha with no matching candidate object"
fi
if grep -q "cp gs://" "$work/gcloud-args" 2>/dev/null; then
  fail "must not copy when the candidate is missing"
fi

# Malformed sha → usage error before any gcloud call.
rm -f "$work/gcloud-args"
if PATH="$work/bin:$PATH" DEVBOX_RUNTIME_BUCKET=fake-bucket bash "$PROMOTE" "not-a-sha" >/dev/null 2>&1; then
  fail "must reject a malformed sha"
fi
[ ! -f "$work/gcloud-args" ] || fail "malformed sha must fail before any gcloud call"

# Known sha → exactly one copy candidate → pointer.
PATH="$work/bin:$PATH" DEVBOX_RUNTIME_BUCKET=fake-bucket bash "$PROMOTE" "$known_sha" \
  || fail "promotion of a known candidate failed"
grep -q "cp gs://fake-bucket/runtime/manifest/$known_sha.json gs://fake-bucket/runtime/manifest.json" "$work/gcloud-args" \
  || fail "expected candidate→pointer copy"

# sync-converge plumbs --manifest-sha through Tailscale SSH.
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "\$@" > "$work/ssh-args"
exit 0
EOF
chmod 0755 "$work/bin/ssh"
PATH="$work/bin:$PATH" bash "$SYNC" alice --manifest-sha "$known_sha" || fail "sync-converge failed"
grep -q "dev@alice-devbox" "$work/ssh-args" || fail "sync must target dev@<machine>-devbox"
grep -q -- "--manifest-sha $known_sha" "$work/ssh-args" || fail "sync must plumb --manifest-sha through"

# No-flag path (the documented primary usage). The empty converge_args array
# must expand safely under `set -u` — on stock bash 3.2 (macOS) `${arr[*]}`
# of an empty array aborts with "unbound variable", so the fix uses :-.
rm -f "$work/ssh-args"
PATH="$work/bin:$PATH" bash "$SYNC" somemachine || fail "sync-converge must succeed with no flags"
grep -q "dev@somemachine-devbox" "$work/ssh-args" || fail "no-flag sync must target dev@<machine>-devbox"
grep -q "sudo /usr/local/bin/devbox-converge" "$work/ssh-args" || fail "no-flag sync must invoke devbox-converge"

echo "PASS: promote-runtime-test"
