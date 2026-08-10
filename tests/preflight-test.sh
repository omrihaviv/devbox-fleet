#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$repo_root/scripts/preflight"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -x "$PREFLIGHT" ] || fail "scripts/preflight missing or not executable"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Sentinels — none of these may ever appear in --support output.
S_PROJECT="sentinel-project-482"
S_BUCKET="sentinel-bucket-tfstate-482"
S_TAILNET="sentinel-tailnet.example.net"
S_EMAIL="sentinel-admin@corp.test"
S_ADMIN_GROUP="sentinel-admins-group@corp.test"

make_fixture() { # $1 = fixture dir, $2 = "placeholders" | "filled"
  local dir="$1" flavor="$2"
  mkdir -p "$dir/gcp" "$dir/scripts"
  if [ "$flavor" = placeholders ]; then
    printf 'bucket = "your-tfstate-bucket"\n' > "$dir/gcp/backend.hcl"
    printf 'gcp_project_id = "your-project-id"\ntailscale_oauth_client_id = "REPLACE"\ntailscale_oauth_client_secret = "REPLACE"\ntailscale_tailnet = "example.com"\ntailscale_admin_emails = ["ops@example.com"]\n' \
      > "$dir/gcp/terraform.tfvars"
  else
    printf 'bucket = "%s"\n' "$S_BUCKET" > "$dir/gcp/backend.hcl"
    # Every assignment preflight's REQUIRED_TFVARS audit demands (the
    # defaultless variables in gcp/variables.tf), with sentinel values.
    {
      printf 'gcp_project_id = "%s"\n' "$S_PROJECT"
      printf 'ubuntu_2404_image = "ubuntu-2404-sentinel-v20260101"\n'
      printf 'toolchain = { gh_version = "latest" }\n'
      printf 'ops_agent_version = "2.55.0"\n'
      printf 'tailscale_admin_emails = ["%s"]\n' "$S_EMAIL"
      printf 'tailscale_oauth_client_id = "k123abc"\n'
      printf 'tailscale_oauth_client_secret = "tskey-secret-482"\n'
      printf 'tailscale_tailnet = "%s"\n' "$S_TAILNET"
      printf 'devbox_admins_group = "%s"\n' "$S_ADMIN_GROUP"
    } > "$dir/gcp/terraform.tfvars"
  fi
}

make_fake_bin() { # stub gcloud/terraform so no real cloud/CLI is needed
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/gcloud" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"application-default print-access-token"*) echo fake-token ;;
  *"storage buckets describe"*) echo "name: bucket" ;;
  *"services list"*)
    for s in compute iam iap storage monitoring logging cloudresourcemanager; do
      echo "${s}.googleapis.com"
    done ;;
  *) exit 0 ;;
esac
EOF
  cat > "$fake_bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "Terraform v1.9.5"
EOF
  chmod +x "$fake_bin/gcloud" "$fake_bin/terraform"
}

fake_bin="$workdir/bin"
make_fake_bin "$fake_bin"

# --- Case 1: placeholder config → config-tfvars FAIL, ok=false, exit != 0
fx1="$workdir/fx1"; make_fixture "$fx1" placeholders
json1="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx1" "$PREFLIGHT" --json)" \
  && fail "placeholders: expected non-zero exit"
json1="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx1" "$PREFLIGHT" --json || true)"
echo "$json1" | jq -e '.ok == false' >/dev/null || fail "placeholders: ok must be false"
echo "$json1" | jq -e '.checks[] | select(.id == "config-tfvars") | select(.status == "FAIL")' >/dev/null \
  || fail "placeholders: config-tfvars must FAIL"

# --- Case 2: filled config + stubs → ok=true, exit 0, repos-default WARN
fx2="$workdir/fx2"; make_fixture "$fx2" filled
snapshot="$workdir/fx2.orig"; cp -a "$fx2" "$snapshot"
json2="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx2" "$PREFLIGHT" --json)" \
  || fail "filled: expected exit 0"
echo "$json2" | jq -e '.ok == true' >/dev/null || fail "filled: ok must be true"
echo "$json2" | jq -e '.checks[] | select(.id == "repos-default") | select(.status == "WARN")' >/dev/null \
  || fail "filled: repos-default must WARN when the file is absent"
echo "$json2" | jq -e '.scope | type == "string" and (length > 0)' >/dev/null \
  || fail "filled: scope field missing"

# --- Case 3: --json stdout is pure JSON
echo "$json2" | jq . >/dev/null || fail "--json stdout must parse as JSON"

# --- Case 4: --support leaks no sentinel values
support="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx2" "$PREFLIGHT" --support 2>&1)" \
  || fail "--support: expected exit 0 on filled fixture"
for s in "$S_PROJECT" "$S_BUCKET" "$S_TAILNET" "$S_EMAIL" "$S_ADMIN_GROUP" "tskey-secret-482" "k123abc"; do
  if printf '%s' "$support" | rg -q --fixed-strings "$s"; then
    fail "--support leaked sentinel: $s"
  fi
done
printf '%s' "$support" | rg -q "repos-default" || fail "--support must list check ids"

# --- Case 5: read-only — fixture untouched
diff -r "$fx2" "$snapshot" >/dev/null || fail "preflight mutated the fixture (must be read-only)"

# --- Case 6: missing terraform → cli-terraform FAIL
no_tf="$workdir/bin-no-tf"; mkdir -p "$no_tf"; cp "$fake_bin/gcloud" "$no_tf/gcloud"
json3="$(PATH="$no_tf:/usr/bin:/bin" DEVBOX_PREFLIGHT_ROOT="$fx2" "$PREFLIGHT" --json || true)"
echo "$json3" | jq -e '.checks[] | select(.id == "cli-terraform") | select(.status == "FAIL")' >/dev/null \
  || fail "missing terraform must FAIL cli-terraform"

# --- Case 7: filled config with a commented-out example line → config-tfvars
# must still PASS (a real tfvars made by `cp terraform.tfvars.example
# terraform.tfvars` keeps instructional comments like this one).
fx7="$workdir/fx7"; make_fixture "$fx7" filled
printf '#     tailscale_email = "alice@example.com"\n' >> "$fx7/gcp/terraform.tfvars"
json4="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx7" "$PREFLIGHT" --json)" \
  || fail "filled-with-comment: expected exit 0"
echo "$json4" | jq -e '.ok == true' >/dev/null \
  || fail "filled-with-comment: ok must be true despite a commented example.com line"
echo "$json4" | jq -e '.checks[] | select(.id == "config-tfvars") | select(.status == "PASS")' >/dev/null \
  || fail "filled-with-comment: config-tfvars must PASS — placeholder check must ignore comment lines"

# --- Case 8: backend.hcl present but no bucket field → config-backend FAIL
# (a file with no recognized placeholders must not read as ready)
fx8="$workdir/fx8"; make_fixture "$fx8" filled
printf '# bucket intentionally missing\n' > "$fx8/gcp/backend.hcl"
json8="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx8" "$PREFLIGHT" --json || true)"
echo "$json8" | jq -e '.ok == false' >/dev/null || fail "no-bucket-field: ok must be false"
echo "$json8" | jq -e '.checks[] | select(.id == "config-backend") | select(.status == "FAIL")' >/dev/null \
  || fail "no-bucket-field: config-backend must FAIL, not PASS"

# --- Case 9: tfvars present but no gcp_project_id → config-tfvars FAIL
fx9="$workdir/fx9"; make_fixture "$fx9" filled
printf 'tailscale_oauth_client_id = "k123abc"\ntailscale_oauth_client_secret = "tskey-secret-482"\ntailscale_tailnet = "%s"\n' \
  "$S_TAILNET" > "$fx9/gcp/terraform.tfvars"
json9="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx9" "$PREFLIGHT" --json || true)"
echo "$json9" | jq -e '.ok == false' >/dev/null || fail "no-project-field: ok must be false"
echo "$json9" | jq -e '.checks[] | select(.id == "config-tfvars") | select(.status == "FAIL")' >/dev/null \
  || fail "no-project-field: config-tfvars must FAIL, not PASS"

# --- Case 10: terraform present but broken (exits nonzero) → cli-terraform
# FAIL and the report must still be emitted (script must not die silently).
broken="$workdir/bin-broken-tf"; mkdir -p "$broken"; cp "$fake_bin/gcloud" "$broken/gcloud"
printf '#!/usr/bin/env bash\nexit 1\n' > "$broken/terraform"; chmod +x "$broken/terraform"
json10="$(PATH="$broken:/usr/bin:/bin" DEVBOX_PREFLIGHT_ROOT="$fx2" "$PREFLIGHT" --json || true)"
[ -n "$json10" ] || fail "broken-terraform: --json output must not be empty"
echo "$json10" | jq -e '.checks[] | select(.id == "cli-terraform") | select(.status == "FAIL")' >/dev/null \
  || fail "broken-terraform: cli-terraform must FAIL"

# --- Case 11: version floors — a git below the floor FAILs cli-git; the stub
# gcloud (unparseable version output) WARNs rather than passing silently.
oldgit="$workdir/bin-old-git"; mkdir -p "$oldgit"
cp "$fake_bin/gcloud" "$oldgit/gcloud"; cp "$fake_bin/terraform" "$oldgit/terraform"
printf '#!/usr/bin/env bash\necho "git version 1.0.0"\n' > "$oldgit/git"; chmod +x "$oldgit/git"
json11="$(PATH="$oldgit:/usr/bin:/bin" DEVBOX_PREFLIGHT_ROOT="$fx2" "$PREFLIGHT" --json || true)"
echo "$json11" | jq -e '.checks[] | select(.id == "cli-git") | select(.status == "FAIL")' >/dev/null \
  || fail "old-git: cli-git must FAIL below the version floor"
echo "$json11" | jq -e '.checks[] | select(.id == "cli-gcloud") | select(.status == "WARN")' >/dev/null \
  || fail "stub-gcloud: unparseable gcloud version must WARN"

# --- Case 12: tfvars missing required defaultless assignments (beyond
# gcp_project_id) → config-tfvars FAIL even with no placeholders present.
fx12="$workdir/fx12"; make_fixture "$fx12" filled
grep -Ev '^(toolchain|ubuntu_2404_image)[[:space:]]*=' "$fx12/gcp/terraform.tfvars" \
  > "$fx12/gcp/terraform.tfvars.tmp" && mv "$fx12/gcp/terraform.tfvars.tmp" "$fx12/gcp/terraform.tfvars"
json12="$(PATH="$fake_bin:$PATH" DEVBOX_PREFLIGHT_ROOT="$fx12" "$PREFLIGHT" --json || true)"
echo "$json12" | jq -e '.ok == false' >/dev/null || fail "missing-required: ok must be false"
echo "$json12" | jq -e '.checks[] | select(.id == "config-tfvars") | select(.status == "FAIL") | select(.detail | contains("required assignment"))' >/dev/null \
  || fail "missing-required: config-tfvars must FAIL naming the required-assignment audit"

# --- Case 13: jq present but broken → --json must still emit valid JSON
# (the static fallback), not die with no output.
[ -x /usr/bin/jq ] || fail "test environment needs /usr/bin/jq"
bjq="$workdir/bin-broken-jq"; mkdir -p "$bjq"
cp "$fake_bin/gcloud" "$bjq/gcloud"; cp "$fake_bin/terraform" "$bjq/terraform"
printf '#!/usr/bin/env bash\nexit 3\n' > "$bjq/jq"; chmod +x "$bjq/jq"
json13="$(PATH="$bjq:/usr/bin:/bin" DEVBOX_PREFLIGHT_ROOT="$fx2" "$PREFLIGHT" --json || true)"
[ -n "$json13" ] || fail "broken-jq: --json output must not be empty"
echo "$json13" | /usr/bin/jq -e '.ok == false' >/dev/null \
  || fail "broken-jq: fallback output must be valid JSON with ok=false"
echo "$json13" | /usr/bin/jq -e '.checks[] | select(.id == "cli-jq")' >/dev/null \
  || fail "broken-jq: fallback output must name cli-jq"

# --- Case 14: gcloud present but broken (version command exits nonzero) →
# cli-gcloud FAIL, not the unparseable-output WARN.
bgc="$workdir/bin-broken-gcloud"; mkdir -p "$bgc"
cp "$fake_bin/terraform" "$bgc/terraform"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bgc/gcloud"; chmod +x "$bgc/gcloud"
json14="$(PATH="$bgc:/usr/bin:/bin" DEVBOX_PREFLIGHT_ROOT="$fx2" "$PREFLIGHT" --json || true)"
echo "$json14" | jq -e '.checks[] | select(.id == "cli-gcloud") | select(.status == "FAIL")' >/dev/null \
  || fail "broken-gcloud: cli-gcloud must FAIL when its version command cannot run"

echo "PASS: preflight-test"
