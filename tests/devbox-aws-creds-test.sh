#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDS="$repo_root/scripts/gcp/devbox-aws-creds"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$CREDS" ] || fail "scripts/gcp/devbox-aws-creds missing or not executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

cat > "$work/bedrock.json" <<'EOF'
{"role_arn": "arn:aws:iam::123456789012:role/devbox-gcp-workload", "region": "us-east-1", "audience": "devbox-fleet-aws-federation"}
EOF

# Fake curl: asserts the pinned audience is in the identity-token request.
cat > "$work/bin/curl" <<EOF
#!/usr/bin/env bash
url=""
for a in "\$@"; do case "\$a" in http*) url="\$a";; esac; done
case "\$url" in
  *identity*audience=devbox-fleet-aws-federation*format=full*) printf 'FAKE.JWT.TOKEN' ;;
  *identity*) echo "wrong-or-missing-audience: \$url" >&2; exit 22 ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$work/bin/curl"

# Fake aws: asserts role-session-name=hostname and emits STS-shaped JSON.
# Also records whether a profile leaked into its environment (recursion guard).
cat > "$work/bin/aws" <<EOF
#!/usr/bin/env bash
echo "\$@" > "$work/aws-args"
echo "AWS_PROFILE=\${AWS_PROFILE:-UNSET}" > "$work/aws-env"
cat <<'JSON'
{"Credentials": {"AccessKeyId": "ASIAFAKE", "SecretAccessKey": "sk", "SessionToken": "st", "Expiration": "2026-07-13T12:00:00+00:00"}}
JSON
EOF
chmod 0755 "$work/bin/aws"

out="$(PATH="$work/bin:$PATH" DEVBOX_BEDROCK_CONFIG="$work/bedrock.json" \
  DEVBOX_METADATA_URL="http://metadata.google.internal/computeMetadata/v1" bash "$CREDS")"

echo "$out" | jq -e '.Version == 1 and .AccessKeyId == "ASIAFAKE" and .SessionToken == "st" and .Expiration' >/dev/null \
  || fail "output is not valid credential_process JSON: $out"

grep -q -- "--role-session-name $(hostname)" "$work/aws-args" \
  || fail "RoleSessionName must be the hostname (best-effort per-machine label)"
grep -q -- "--web-identity-token FAKE.JWT.TOKEN" "$work/aws-args" \
  || fail "identity token not passed to STS"
grep -q -- "--role-arn arn:aws:iam::123456789012:role/devbox-gcp-workload" "$work/aws-args" \
  || fail "role ARN not passed to STS"

# Recursion guard: SDKs invoke credential_process with the CALLER's env.
# If AWS_PROFILE (pointing back at this very helper's profile) reaches the
# inner aws call, it re-enters the helper and forks without bound — this
# wedged the first canary box with >1,300 concurrent helpers.
out="$(PATH="$work/bin:$PATH" AWS_PROFILE=devbox-bedrock AWS_DEFAULT_PROFILE=devbox-bedrock \
  DEVBOX_BEDROCK_CONFIG="$work/bedrock.json" bash "$CREDS")"
echo "$out" | jq -e '.Version == 1 and .AccessKeyId == "ASIAFAKE"' >/dev/null \
  || fail "helper must still emit credentials when the caller exports AWS_PROFILE"
grep -q '^AWS_PROFILE=UNSET$' "$work/aws-env" \
  || fail "AWS_PROFILE leaked into the inner aws call (recursion guard broken): $(cat "$work/aws-env")"

# Token fetch failure → non-zero exit, NOT empty/partial JSON.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod 0755 "$work/bin/curl"
if PATH="$work/bin:$PATH" DEVBOX_BEDROCK_CONFIG="$work/bedrock.json" bash "$CREDS" >/dev/null 2>&1; then
  fail "must exit non-zero when the token fetch fails"
fi

# Missing config file → non-zero with pointer to converge.
if PATH="$work/bin:$PATH" DEVBOX_BEDROCK_CONFIG="$work/nope.json" bash "$CREDS" >/dev/null 2>&1; then
  fail "must exit non-zero when bedrock.json is absent"
fi

echo "PASS: devbox-aws-creds-test"
