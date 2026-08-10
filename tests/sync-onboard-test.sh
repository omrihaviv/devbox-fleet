#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$ROOT_DIR/scripts/sync-onboard.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

make_stubs() { # $1 = workdir
  mkdir -p "$1/bin"
  cat > "$1/bin/scp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/scp-args"
EOF
  cat > "$1/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/ssh-args"
EOF
  cat > "$1/bin/terraform" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/tf-args"
echo '{"alice":"alice-devbox","bob-big":"bob-big-devbox"}'
EOF
  chmod +x "$1/bin/"*
}

# Save any pre-existing local repos list (it's gitignored org config) and
# restore it on exit, whatever happens.
REPOS="$ROOT_DIR/scripts/devbox-repos.default"
restore_repos() {
  if [ -f "$REPOS.testbak" ]; then mv -- "$REPOS.testbak" "$REPOS"; else rm -f "$REPOS"; fi
}
[ ! -f "$REPOS" ] || mv -- "$REPOS" "$REPOS.testbak"
trap 'restore_repos' EXIT

# 1. Explicit machine, repos file present: pushes onboard + repos.
work="$(mktemp -d)"
make_stubs "$work"
printf 'org/repo\n' > "$REPOS"
PATH="$work/bin:$PATH" bash "$SYNC" alice || fail "explicit sync failed"
grep -q 'devbox-onboard' "$work/scp-args" || fail "must scp devbox-onboard"
grep -q 'devbox-repos.default' "$work/scp-args" || fail "must scp repos when present"
grep -q 'dev@alice-devbox' "$work/scp-args" || fail "must target dev@alice-devbox"
grep -q 'install -o root -g root -m 0755 /tmp/devbox-onboard' "$work/ssh-args" || fail "must install onboard"
grep -q 'install -o root -g root -m 0644 /tmp/devbox-repos.default' "$work/ssh-args" || fail "repos install must be root-owned 0644"
[ ! -e "$work/tf-args" ] || fail "explicit mode must not call terraform"

# 2. Repos file absent: pushes only onboard, still succeeds.
rm -f "$REPOS"
work2="$(mktemp -d)"
make_stubs "$work2"
PATH="$work2/bin:$PATH" bash "$SYNC" alice || fail "sync without repos file failed"
grep -q 'devbox-onboard' "$work2/scp-args" || fail "must still scp onboard"
grep -q 'devbox-repos.default' "$work2/scp-args" && fail "must NOT scp missing repos file" || true

# 3. No-arg mode: discovers machines from the GCP root.
work3="$(mktemp -d)"
make_stubs "$work3"
PATH="$work3/bin:$PATH" bash "$SYNC" || fail "no-arg sync failed"
grep -qE -- '-chdir=.*/gcp output -json devbox_hostnames' "$work3/tf-args" || fail "must read gcp devbox_hostnames"
grep -q 'dev@alice-devbox' "$work3/scp-args" || fail "discovery must reach alice"
grep -q 'dev@bob-big-devbox' "$work3/scp-args" || fail "discovery must reach bob-big"

rm -rf "$work" "$work2" "$work3"
echo "PASS sync-onboard-test"
