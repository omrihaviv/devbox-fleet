#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The dev user in fixtures must be the CURRENT user: a non-root test run can
# only chown/sudo to itself, and CI runners have no 'dev' account.
test_user="$(id -un)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_fake_bin() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  echo 0
else
  /usr/bin/id "$@"
fi
EOF
  cat > "$fake_bin/dpkg" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--print-architecture" ]; then
  echo amd64
else
  exit 0
fi
EOF
  cat > "$fake_bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
package="${@: -1}"
case "$package" in
  tailscale) echo "$DEVBOX_TAILSCALE_VERSION" ;;
  gh) echo "$DEVBOX_GH_VERSION" ;;
  docker-ce|docker-ce-cli) echo "$DEVBOX_DOCKER_CE_VERSION" ;;
  nodejs) echo "$DEVBOX_SYSTEM_NODE_VERSION" ;;
  google-chrome-stable) echo "$DEVBOX_GOOGLE_CHROME_VERSION" ;;
  git|make|build-essential|jq|unzip|mosh|tmux|htop|ripgrep|fd-find|containerd.io|docker-compose-plugin|libnss3|libgbm1|libasound2t64|fonts-liberation) exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$fake_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$DEVBOX_TEST_LOG"
if [[ "$*" = *"install -y code"* ]] && [ "${DEVBOX_TEST_VSCODE_APT_FAIL:-0}" = 1 ]; then
  exit 47
fi
EOF
  cat > "$fake_bin/install" <<'EOF'
#!/usr/bin/env bash
dest="${@: -1}"
src=""
if [ "$#" -ge 2 ]; then
  src="${@: -2:1}"
fi
if [ "${DEVBOX_TEST_VSCODE_LAUNCHER_INSTALL_FAIL:-0}" = 1 ] \
    && [ -n "${VSCODE_LAUNCHER:-}" ] \
    && [ "$dest" = "$VSCODE_LAUNCHER" ]; then
  echo "install $src $dest" >> "$DEVBOX_TEST_VSCODE_INSTALL_LOG"
  exit 64
fi
if [ -n "${DEVBOX_TEST_PASEO_LAUNCHER_INSTALL_LOG:-}" ] \
    && { [ "$dest" = "${PASEO_BIN:-}" ] || [ "$dest" = "${PASEO_SYSTEM_BIN:-}" ]; }; then
  echo "install $*" >> "$DEVBOX_TEST_PASEO_LAUNCHER_INSTALL_LOG"
fi
/usr/bin/install "$@"
EOF
  cat > "$fake_bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = policy ] && [ "${2:-}" = code ]; then
  printf 'Candidate: 1.99.0\n'
fi
EOF
  cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
[ -n "$out" ] || exit 2
if [ -n "${DEVBOX_TEST_PASEO_TARBALL_SOURCE:-}" ] \
    && [[ "$url" == *"registry.npmjs.org/@getpaseo/cli"* ]]; then
  echo "download $url $out" >> "$DEVBOX_TEST_PASEO_DOWNLOAD_LOG"
  if [ "${DEVBOX_TEST_PASEO_DOWNLOAD_FAIL:-0}" = 1 ]; then
    exit 44
  fi
  cp "$DEVBOX_TEST_PASEO_TARBALL_SOURCE" "$out"
elif [ -n "${DEVBOX_TEST_CODEX_INSTALLER_SOURCE:-}" ]; then
  echo "download $out" >> "$DEVBOX_TEST_CODEX_DOWNLOAD_LOG"
  if [ "${DEVBOX_TEST_CODEX_DOWNLOAD_FAIL:-0}" = 1 ]; then
    exit 44
  fi
  cp "$DEVBOX_TEST_CODEX_INSTALLER_SOURCE" "$out"
else
  printf 'fake key\n' > "$out"
fi
EOF
  cat > "$fake_bin/gpg" <<'EOF'
#!/usr/bin/env bash
out=""
in=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    --batch|--yes|--dearmor)
      shift
      ;;
    *)
      in="$1"
      shift
      ;;
  esac
done
cp "$in" "$out"
EOF
  cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
if [ "$*" = "daemon-reload" ] && [ "${DEVBOX_TEST_DAEMON_RELOAD_FAIL:-0}" = 1 ]; then
  exit 58
fi
EOF
  cat > "$fake_bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
path="${@: -1}"
case "$path" in
  "$DEVBOX_DATA_MOUNT") exit 0 ;;
  "$DEVBOX_CONTAINERD_STATE_DIR") exit "${DEVBOX_TEST_CONTAINERD_MOUNTED_RC:-0}" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$fake_bin/mount" <<'EOF'
#!/usr/bin/env bash
echo "mount $*" >> "$DEVBOX_TEST_LOG"
EOF
  cat > "$fake_bin/chown" <<'EOF'
#!/usr/bin/env bash
# Tripwire log: the sudo fake rejects any run whose installer was chowned to
# the dev user, so a reintroduced ownership transfer fails loudly.
if [ -n "${DEVBOX_TEST_CODEX_CHOWN_LOG:-}" ] && [ "${1:-}" = "${DEV_USER:-}" ]; then
  echo "chown $*" >> "$DEVBOX_TEST_CODEX_CHOWN_LOG"
else
  echo "chown $*" >> "$DEVBOX_TEST_LOG"
fi
EOF
  cat > "$fake_bin/chmod" <<'EOF'
#!/usr/bin/env bash
if [ -n "${DEVBOX_TEST_CODEX_CHMOD_LOG:-}" ] && [ "${1:-}" = 0644 ]; then
  echo "chmod $*" >> "$DEVBOX_TEST_CODEX_CHMOD_LOG"
  if [ "${DEVBOX_TEST_CODEX_CHMOD_FAIL:-0}" = 1 ]; then
    exit 43
  fi
fi
/usr/bin/chmod "$@"
EOF
  cat > "$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ -n "${DEVBOX_TEST_CODEX_STATE_LOG:-}" ]; then
  echo "mv $*" >> "$DEVBOX_TEST_CODEX_STATE_LOG"
  if [ "${DEVBOX_TEST_CODEX_STATE_MOVE_FAIL:-0}" = 1 ]; then
    exit 46
  fi
fi
if [ -n "${DEVBOX_TEST_PASEO_STATE_LOG:-}" ] \
    && [ "$#" -eq 3 ] \
    && [ "$1" = -f ] \
    && [ "$2" = "$PASEO_REQUIRED_FILE" ] \
    && [ "$3" = "$PASEO_SUCCESS_FILE" ]; then
  echo "mv $*" >> "$DEVBOX_TEST_PASEO_STATE_LOG"
  if [ "${DEVBOX_TEST_PASEO_STATE_MOVE_FAIL:-0}" = 1 ]; then
    exit 56
  fi
fi
/usr/bin/mv "$@"
EOF
  cat > "$fake_bin/usermod" <<'EOF'
#!/usr/bin/env bash
echo "usermod $*" >> "$DEVBOX_TEST_LOG"
EOF
  cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "${DEVBOX_TEST_VSCODE_SUDO_FAIL:-0}" = 1 ]; then
  echo "unexpected sudo $*" >&2
  exit 48
fi
case "$*" in
  *"nvm --version"*)
    echo "$DEVBOX_NVM_VERSION"
    ;;
  *"nvm install"*)
    echo "sudo $*" >> "$DEVBOX_TEST_LOG"
    ;;
  *"CODEX_NON_INTERACTIVE=1"*)
    installer="${@: -1}"
    # The verified script must stay owned by the converge user (root in
    # production): a chown to $DEV_USER would hand the dev write access
    # between verification and execution.
    if [ -f "$DEVBOX_TEST_CODEX_CHOWN_LOG" ] \
        && grep -q "^chown $DEV_USER " "$DEVBOX_TEST_CODEX_CHOWN_LOG"; then
      echo "Codex installer ownership was transferred to the dev user: $installer" >&2
      exit 1
    fi
    if [ "$(stat -c '%a' "$installer")" != 644 ]; then
      echo "Codex installer is not read-only for dev (0644): $installer" >&2
      exit 1
    fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -u) shift 2 ;;
        -H) shift ;;
        *) break ;;
      esac
    done
    "$@"
    ;;
  *"${CODEX_BIN:-/__unset_codex__} --version"*)
    if [ "$#" -ne 7 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != "$CODEX_BIN" ] \
        || [ "$7" != --version ]; then
      echo "Codex verification did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    echo "verify $*" >> "$DEVBOX_TEST_CODEX_VERIFY_LOG"
    if [ "${DEVBOX_TEST_CODEX_VERIFY_FAIL:-0}" = 1 ]; then
      exit 45
    fi
    "$6" "$7"
    ;;
  *"${NPM_BIN:-/__unset_npm__} install -g "*"/paseo-cli.tgz"*)
    if [ "$#" -ne 10 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != "NPM_CONFIG_PREFIX=$PASEO_NPM_PREFIX" ] \
        || [ "$7" != "$NPM_BIN" ] \
        || [ "$8" != install ] \
        || [ "$9" != -g ]; then
      echo "Paseo install did not use the expected dev-user prefix boundary: $*" >&2
      exit 1
    fi
    case "${10}" in
      */paseo-cli.tgz) ;;
      *)
        echo "Paseo install target is not the verified local tarball: ${10}" >&2
        exit 1
        ;;
    esac
    echo "install $*" >> "$DEVBOX_TEST_PASEO_INSTALL_BOUNDARY_LOG"
    shift 3
    "$@"
    ;;
  *"${VSCODE_BIN:-/__unset_vscode__} --version"*)
    if [ "$#" -ne 7 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != "$VSCODE_BIN" ] \
        || [ "$7" != --version ]; then
      echo "VS Code version verification did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    echo "verify $*" >> "$DEVBOX_TEST_VSCODE_VERIFY_LOG"
    "$6" "$7"
    ;;
  *"${VSCODE_BIN:-/__unset_vscode__} serve-web --help"*)
    if [ "$#" -ne 8 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != "$VSCODE_BIN" ] \
        || [ "$7" != serve-web ] \
        || [ "$8" != --help ]; then
      echo "VS Code serve-web verification did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    echo "verify $*" >> "$DEVBOX_TEST_VSCODE_VERIFY_LOG"
    "$6" "$7" "$8"
    ;;
  *"${PASEO_BIN:-/__unset_paseo__} --version"*)
    if [ "$#" -ne 8 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != "NPM_CONFIG_PREFIX=$PASEO_NPM_PREFIX" ] \
        || [ "$7" != "$PASEO_BIN" ] \
        || [ "$8" != --version ]; then
      echo "Paseo verification did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    echo "verify $*" >> "$DEVBOX_TEST_PASEO_VERIFY_LOG"
    if [ "${DEVBOX_TEST_PASEO_VERIFY_FAIL:-0}" = 1 ]; then
      exit 52
    fi
    shift 3
    "$@"
    ;;
  *"${CODEX_BIN:-/__unset_codex__} login status"*)
    if [ "$#" -ne 8 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != "$CODEX_BIN" ] \
        || [ "$7" != login ] \
        || [ "$8" != status ]; then
      echo "Codex login check did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    if [ "$PWD" != "$DEV_HOME" ]; then
      echo "Codex login check did not start from the dev home: cwd=$PWD expected=$DEV_HOME" >&2
      exit 1
    fi
    shift 5
    "$@"
    ;;
  *" plugin "*)
    if [ "$#" -lt 7 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ]; then
      echo "Plugin command did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    if [ "$PWD" != "$DEV_HOME" ]; then
      echo "Plugin command did not start from the dev home: cwd=$PWD expected=$DEV_HOME" >&2
      exit 1
    fi
    shift 5
    "$@"
    ;;
  *"${TMUX_BIN:-/__unset_tmux__} source-file"*)
    if [ "$#" -ne 6 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != "$TMUX_BIN" ] \
        || [ "$5" != source-file ] \
        || [ "$6" != "$TMUX_CONF_FILE" ]; then
      echo "tmux reload did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    if [ "$PWD" != "$DEV_HOME" ]; then
      echo "tmux reload did not start from the dev home: cwd=$PWD expected=$DEV_HOME" >&2
      exit 1
    fi
    echo "reload $*" >> "$DEVBOX_TEST_TMUX_RELOAD_LOG"
    shift 3
    "$@"
    ;;
  *"${CLAUDE_BIN:-/__unset_claude__} --version"*)
    if [ "$#" -ne 7 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != "$CLAUDE_BIN" ] \
        || [ "$7" != --version ]; then
      echo "Claude verification did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    "$6" "$7"
    ;;
  *"HOME=$DEV_HOME bash "*" latest")
    if [ "$#" -ne 8 ] \
        || [ "$1" != -u ] \
        || [ "$2" != "$DEV_USER" ] \
        || [ "$3" != -H ] \
        || [ "$4" != env ] \
        || [ "$5" != "HOME=$DEV_HOME" ] \
        || [ "$6" != bash ] \
        || [ "$8" != latest ]; then
      echo "Claude installer did not use the expected dev-user boundary: $*" >&2
      exit 1
    fi
    # Same rule as the Codex branch: the verified script must stay owned by
    # the converge user and read-only for dev through execution.
    if [ -f "${DEVBOX_TEST_LOG:-}" ] && grep -q "^chown $DEV_USER " "$DEVBOX_TEST_LOG"; then
      echo "Claude installer ownership was transferred to the dev user: $7" >&2
      exit 1
    fi
    if [ "$(stat -c '%a' "$7")" != 644 ]; then
      echo "Claude installer is not read-only for dev (0644): $7" >&2
      exit 1
    fi
    if [ "$PWD" != "$DEV_HOME" ]; then
      echo "Claude installer did not start from the dev home: cwd=$PWD expected=$DEV_HOME" >&2
      exit 1
    fi
    shift 5
    HOME="$DEV_HOME" "$@"
    ;;
  *)
    echo "unexpected sudo $*" >&2
    exit 1
    ;;
esac
EOF
  cat > "$fake_bin/node" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  *"chrome-devtools-mcp"*)
    echo "$DEVBOX_CHROME_DEVTOOLS_MCP_VERSION"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  cat > "$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$DEVBOX_TEST_LOG"
case "$*" in "install -g "*"/paseo-cli.tgz")
  if [ ! -f "$3" ]; then
    echo "Paseo npm install target tarball is missing: $3" >&2
    exit 59
  fi
  if [ "${NPM_CONFIG_PREFIX:-}" != "$PASEO_NPM_PREFIX" ]; then
    echo "Paseo npm install used prefix '${NPM_CONFIG_PREFIX:-unset}', expected '$PASEO_NPM_PREFIX'" >&2
    exit 57
  fi
  if [ "${DEVBOX_TEST_PASEO_INSTALL_FAIL:-0}" = 1 ]; then
    exit 51
  fi
  mkdir -p "$(dirname "$PASEO_USER_BIN")" "$PASEO_PACKAGE_DIR"
  cat > "$PASEO_USER_BIN" <<'PASEO_EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '0.1.107\n'
  exit 0
fi
printf 'prefix=%s paseo %s\n' "${NPM_CONFIG_PREFIX:-unset}" "$*" >> "$DEVBOX_TEST_PASEO_RUNTIME_LOG"
exit 53
PASEO_EOF
  chmod 0755 "$PASEO_USER_BIN"
  /usr/bin/chown -R "$DEV_USER:$DEV_USER" "$PASEO_NPM_PREFIX"
esac
EOF
  cat > "$fake_bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws-cli/$DEVBOX_AWS_CLI_VERSION Python/3.12.0 Linux/6 exe/x86_64.ubuntu.24"
EOF
  cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
command="claude $*"
echo "$command" >> "$DEVBOX_TEST_PLUGIN_LOG"
[ "${DEVBOX_TEST_PLUGIN_FAIL_COMMAND:-}" != "$command" ]
EOF
cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
command="codex $*"
echo "$command" >> "$DEVBOX_TEST_PLUGIN_LOG"
[ "$command" != "codex login status" ] || [ "${DEVBOX_TEST_CODEX_NOT_LOGGED_IN:-0}" != 1 ] || exit 1
[ "${DEVBOX_TEST_PLUGIN_FAIL_COMMAND:-}" != "$command" ]
EOF
  cat > "$fake_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "ip -4")
    echo "tailscale $*" >> "$DEVBOX_TEST_PASEO_TAILSCALE_LOG"
    [ "${DEVBOX_TEST_PASEO_TAILSCALE_IP_FAIL:-0}" != 1 ] || exit 54
    printf '%s\n' "${DEVBOX_TEST_PASEO_TAILSCALE_IP:-100.64.10.20}"
    ;;
  "status --json")
    echo "tailscale $*" >> "$DEVBOX_TEST_PASEO_TAILSCALE_LOG"
    [ "${DEVBOX_TEST_PASEO_TAILSCALE_STATUS_FAIL:-0}" != 1 ] || exit 55
    printf '{"Self":{"DNSName":"%s"}}\n' \
      "${DEVBOX_TEST_PASEO_TAILSCALE_DNS:-alice-devbox.example-tailnet.ts.net.}"
    ;;
  "serve --yes --bg 8000")
    echo "tailscale $*" >> "$DEVBOX_TEST_VSCODE_LAUNCH_LOG"
    [ "${DEVBOX_TEST_TAILSCALE_SERVE_FAIL:-0}" != 1 ] || exit 47
    ;;
  *)
    echo "unexpected tailscale $*" >&2
    exit 49
    ;;
esac
EOF
  cat > "$fake_bin/code" <<'EOF'
#!/usr/bin/env bash
echo "code $*" >> "$DEVBOX_TEST_VSCODE_LOG"
case "${1:-}" in
  --version) printf '1.99.0\n' ;;
  serve-web)
    if [ "${2:-}" = --help ]; then
      printf 'serve-web help\n'
    elif [ "${2:-}" = --host ]; then
      :
    else
      exit 2
    fi
    ;;
  *) exit 2 ;;
esac
EOF
  cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
if [ -n "${DEVBOX_TEST_GIT_LOG:-}" ]; then
  echo "git $*" >> "$DEVBOX_TEST_GIT_LOG"
fi
dir=""
if [ "${1:-}" = -C ]; then
  dir="$2"
  shift 2
fi
case "${1:-}" in
  init)
    mkdir -p "${@: -1}/.git"
    ;;
  remote)
    ;;
  fetch)
    if [ "${DEVBOX_TEST_GIT_FETCH_FAIL:-0}" = 1 ]; then
      exit 128
    fi
    ;;
  checkout)
    printf '%s\n' "${@: -1}" > "$dir/.git/FAKE_HEAD"
    ;;
  rev-parse)
    cat "$dir/.git/FAKE_HEAD" 2>/dev/null || exit 128
    ;;
  *)
    echo "unexpected git $*" >&2
    exit 1
    ;;
esac
EOF
  cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [ -n "${DEVBOX_TEST_TMUX_LOG:-}" ]; then
  echo "tmux $*" >> "$DEVBOX_TEST_TMUX_LOG"
fi
exit 0
EOF
  chmod 0755 "$fake_bin"/*
}

extract_codex_step() {
  local out="$1"
  sed -n '/^ensure_codex_cli()/,/^}/p' "$repo_root/scripts/devbox-toolchain" > "$out"
  grep -q '^ensure_codex_cli()' "$out" || fail "could not extract ensure_codex_cli"
  grep -q '^}' "$out" || fail "extracted ensure_codex_cli is truncated"
}

extract_paseo_step() {
  local out="$1"
  {
    sed -n '/^ensure_paseo_daemon()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^ensure_paseo()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
  } > "$out"
  grep -q '^ensure_paseo()' "$out" || fail "could not extract ensure_paseo"
  grep -q '^}' "$out" || fail "extracted ensure_paseo is truncated"
}

extract_agent_plugins_step() {
  local out="$1"
  sed -n '/^ensure_agent_plugins()/,/^}/p' "$repo_root/scripts/devbox-toolchain" > "$out"
  grep -q '^ensure_agent_plugins()' "$out" || fail "could not extract ensure_agent_plugins"
  grep -q '^}' "$out" || fail "extracted ensure_agent_plugins is truncated"
}

extract_tmux_plugins_step() {
  local out="$1"
  {
    sed -n '/^tmux_plugins_block()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^ensure_tmux_plugin_repo()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^ensure_tmux_conf_block()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^tmux_live_source()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^ensure_tmux_plugins()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
  } > "$out"
  grep -q '^ensure_tmux_plugins()' "$out" || fail "could not extract ensure_tmux_plugins"
}

extract_vscode_step() {
  local out="$1"

  {
    printf '%s\n' 'APT_GET=(apt-get -o DPkg::Lock::Timeout=300)'
    printf '%s\n' 'apt_updated=false'
    printf '%s\n' 'apt_needs_update=false'
    sed -n '/^install_if_changed()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^install_apt_file_if_changed()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^write_apt_source()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^download_dearmored_keyring()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^apt_update_if_needed()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^dpkg_version()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^ensure_apt_package_version()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^install_vscode_launcher()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^ensure_vscode()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
  } > "$out"

  grep -q '^ensure_vscode()' "$out" || fail "could not extract ensure_vscode"
}

make_fake_codex_installer() {
  local out="$1"
  cat > "$out" <<'EOF'
#!/bin/sh
set -eu
printf 'install non_interactive=%s release=%s dir=%s home=%s\n' \
  "${CODEX_NON_INTERACTIVE:-unset}" "${CODEX_RELEASE:-unset}" \
  "${CODEX_INSTALL_DIR:-unset}" "${HOME:-unset}" >> "$DEVBOX_TEST_LOG"
if [ "${DEVBOX_TEST_CODEX_INSTALL_FAIL:-0}" = 1 ]; then
  exit 42
fi
mkdir -p "$CODEX_INSTALL_DIR"
cat > "$CODEX_INSTALL_DIR/codex" <<'CODEX_EOF'
#!/bin/sh
printf 'codex-cli test\n'
CODEX_EOF
chmod 0755 "$CODEX_INSTALL_DIR/codex"
EOF
}

run_codex_step() {
  local workdir="$1"
  local function_file="$workdir/ensure-codex.sh"

  extract_codex_step "$function_file"
  DEVBOX_TEST_LOG="$workdir/install.log" \
    DEVBOX_TEST_CODEX_CHOWN_LOG="$workdir/chown.log" \
    DEVBOX_TEST_CODEX_CHMOD_LOG="$workdir/chmod.log" \
    DEVBOX_TEST_CODEX_CHMOD_FAIL="${DEVBOX_TEST_CODEX_CHMOD_FAIL:-0}" \
    DEVBOX_TEST_CODEX_DOWNLOAD_LOG="$workdir/download.log" \
    DEVBOX_TEST_CODEX_DOWNLOAD_FAIL="${DEVBOX_TEST_CODEX_DOWNLOAD_FAIL:-0}" \
    DEVBOX_TEST_CODEX_INSTALLER_SOURCE="$workdir/install.sh" \
    DEVBOX_TEST_CODEX_INSTALL_FAIL="${DEVBOX_TEST_CODEX_INSTALL_FAIL:-0}" \
    DEVBOX_TEST_CODEX_STATE_LOG="$workdir/state.log" \
    DEVBOX_TEST_CODEX_STATE_MOVE_FAIL="${DEVBOX_TEST_CODEX_STATE_MOVE_FAIL:-0}" \
    DEVBOX_TEST_CODEX_VERIFY_LOG="$workdir/verify.log" \
    DEVBOX_TEST_CODEX_VERIFY_FAIL="${DEVBOX_TEST_CODEX_VERIFY_FAIL:-0}" \
    DEV_USER="$test_user" \
    DEV_HOME="$workdir/home" \
    GCP_RUNTIME_BUCKET_FILE="$workdir/etc/devbox/runtime-bucket" \
    BOOTSTRAP_COMPLETE_FILE="$workdir/var/lib/devbox-bootstrap/complete" \
    CODEX_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/codex-cli-required" \
    CODEX_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/codex-cli-installed" \
    CODEX_INSTALLER_URL=https://chatgpt.com/codex/install.sh \
    CODEX_INSTALL_DIR="$workdir/home/.local/bin" \
    CODEX_BIN="$workdir/home/.local/bin/codex" \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; ensure_codex_cli' _ "$function_file"
}

run_paseo_step() {
  local workdir="$1"
  local function_file="$workdir/ensure-paseo.sh"

  extract_paseo_step "$function_file"
  # Fixture registry tarball; the sha pin defaults to its real sha and the
  # version pin matches the fake npm's installed paseo. Tests override either
  # env to exercise the mismatch paths.
  printf 'fake @getpaseo/cli tarball\n' > "$workdir/paseo-cli.tgz"
  DEVBOX_PASEO_CLI_VERSION="${DEVBOX_PASEO_CLI_VERSION:-0.1.107}" \
    DEVBOX_PASEO_CLI_TARBALL_SHA256="${DEVBOX_PASEO_CLI_TARBALL_SHA256:-$(sha256sum "$workdir/paseo-cli.tgz" | cut -d' ' -f1)}" \
    DEVBOX_TEST_PASEO_TARBALL_SOURCE="$workdir/paseo-cli.tgz" \
    DEVBOX_TEST_PASEO_DOWNLOAD_LOG="$workdir/paseo-download.log" \
    DEVBOX_TEST_PASEO_DOWNLOAD_FAIL="${DEVBOX_TEST_PASEO_DOWNLOAD_FAIL:-0}" \
    DEVBOX_TEST_LOG="$workdir/commands.log" \
    DEVBOX_TEST_PASEO_INSTALL_FAIL="${DEVBOX_TEST_PASEO_INSTALL_FAIL:-0}" \
    DEVBOX_TEST_PASEO_RUNTIME_LOG="$workdir/paseo-runtime.log" \
    DEVBOX_TEST_PASEO_TAILSCALE_LOG="$workdir/tailscale.log" \
    DEVBOX_TEST_PASEO_TAILSCALE_IP="${DEVBOX_TEST_PASEO_TAILSCALE_IP:-100.64.10.20}" \
    DEVBOX_TEST_PASEO_TAILSCALE_IP_FAIL="${DEVBOX_TEST_PASEO_TAILSCALE_IP_FAIL:-0}" \
    DEVBOX_TEST_PASEO_TAILSCALE_DNS="${DEVBOX_TEST_PASEO_TAILSCALE_DNS:-alice-devbox.example-tailnet.ts.net.}" \
    DEVBOX_TEST_PASEO_TAILSCALE_STATUS_FAIL="${DEVBOX_TEST_PASEO_TAILSCALE_STATUS_FAIL:-0}" \
    DEVBOX_TEST_PASEO_STATE_LOG="$workdir/paseo-state.log" \
    DEVBOX_TEST_PASEO_STATE_MOVE_FAIL="${DEVBOX_TEST_PASEO_STATE_MOVE_FAIL:-0}" \
    DEVBOX_TEST_PASEO_INSTALL_BOUNDARY_LOG="$workdir/paseo-install-boundary.log" \
    DEVBOX_TEST_PASEO_LAUNCHER_INSTALL_LOG="$workdir/paseo-launcher-install.log" \
    DEVBOX_TEST_PASEO_VERIFY_LOG="$workdir/paseo-verify.log" \
    DEVBOX_TEST_PASEO_VERIFY_FAIL="${DEVBOX_TEST_PASEO_VERIFY_FAIL:-0}" \
    DEVBOX_TEST_DAEMON_RELOAD_FAIL="${DEVBOX_TEST_DAEMON_RELOAD_FAIL:-0}" \
    DEV_USER="$test_user" \
    DEV_HOME="$workdir/home" \
    GCP_RUNTIME_BUCKET_FILE="$workdir/etc/devbox/runtime-bucket" \
    BOOTSTRAP_COMPLETE_FILE="$workdir/var/lib/devbox-bootstrap/complete" \
    PASEO_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/paseo-required" \
    PASEO_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/paseo-installed" \
    PASEO_NPM_PREFIX="$workdir/home/.local/share/paseo/npm" \
    PASEO_PACKAGE_DIR="$workdir/home/.local/share/paseo/npm/lib/node_modules/@getpaseo/cli" \
    PASEO_USER_BIN="$workdir/home/.local/share/paseo/npm/bin/paseo" \
    PASEO_BIN="$workdir/home/.local/bin/paseo" \
    PASEO_SYSTEM_BIN="$workdir/usr/local/bin/paseo" \
    PASEO_LEGACY_BIN="$workdir/usr/bin/paseo" \
    PASEO_CONFIG_DIR="$workdir/home/.paseo" \
    PASEO_CONFIG_FILE="$workdir/home/.paseo/config.json" \
    PASEO_DAEMON_RUNNER="$workdir/usr/local/bin/devbox-paseo-daemon" \
    PASEO_DAEMON_SERVICE_FILE="$workdir/etc/systemd/system/paseo.service" \
    DEVBOX_NODE_VERSION=22.22.2 \
    NPM_BIN="$workdir/fake-bin/npm" \
    TAILSCALE_BIN="$workdir/fake-bin/tailscale" \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; ensure_paseo' _ "$function_file"
}

run_agent_plugins_step() {
  local workdir="$1"
  local function_file="$workdir/ensure-agent-plugins.sh"

  extract_agent_plugins_step "$function_file"
    DEVBOX_TEST_LOG="$workdir/commands.log" \
    DEVBOX_TEST_PLUGIN_LOG="$workdir/plugin.log" \
    DEVBOX_TEST_PLUGIN_FAIL_COMMAND="${DEVBOX_TEST_PLUGIN_FAIL_COMMAND:-}" \
    DEVBOX_TEST_CODEX_NOT_LOGGED_IN="${DEVBOX_TEST_CODEX_NOT_LOGGED_IN:-0}" \
    DEV_USER="$test_user" \
    DEV_HOME="$workdir/home" \
    GCP_RUNTIME_BUCKET_FILE="$workdir/etc/devbox/runtime-bucket" \
    BOOTSTRAP_COMPLETE_FILE="$workdir/var/lib/devbox-bootstrap/complete" \
    CODEX_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/codex-cli-installed" \
    CLAUDE_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/claude-code-installed" \
    AGENT_PLUGINS_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/agent-plugins-required" \
    AGENT_PLUGINS_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/agent-plugins-installed" \
    CLAUDE_BIN="$workdir/fake-bin/claude" \
    CODEX_BIN="$workdir/fake-bin/codex" \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; ensure_agent_plugins' _ "$function_file"
}

run_tmux_plugins_step() {
  local workdir="$1"
  local function_file="$workdir/ensure-tmux-plugins.sh"

  extract_tmux_plugins_step "$function_file"
  DEVBOX_TEST_GIT_LOG="$workdir/git.log" \
    DEVBOX_TEST_GIT_FETCH_FAIL="${DEVBOX_TEST_GIT_FETCH_FAIL:-0}" \
    DEVBOX_TEST_TMUX_LOG="$workdir/tmux.log" \
    DEVBOX_TEST_TMUX_RELOAD_LOG="$workdir/tmux-reload.log" \
    DEV_USER="$test_user" \
    DEV_HOME="$workdir/home" \
    TMUX_PLUGINS_DIR="$workdir/opt/tmux-plugins" \
    TMUX_CONF_FILE="$workdir/home/.tmux.conf" \
    TMUX_BIN="$workdir/fake-bin/tmux" \
    TMUX_SOCKET="$workdir/tmux-socket" \
    DEVBOX_TMUX_RESURRECT_COMMIT=1111111111111111111111111111111111111111 \
    DEVBOX_TMUX_CONTINUUM_COMMIT=2222222222222222222222222222222222222222 \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; ensure_tmux_plugins' _ "$function_file"
}

expected_tmux_plugins_block() {
  local plugins_dir="$1"
  cat <<EOF
# >>> devbox-managed: tmux plugins >>>
set -g @continuum-restore 'on'
run-shell $plugins_dir/tmux-resurrect/resurrect.tmux
run-shell $plugins_dir/tmux-continuum/continuum.tmux
# keep last: setting status-right after this silently disables autosave
# <<< devbox-managed: tmux plugins <<<
EOF
}

seed_pinned_tmux_plugin_repos() {
  local workdir="$1"
  mkdir -p "$workdir/opt/tmux-plugins/tmux-resurrect/.git" \
    "$workdir/opt/tmux-plugins/tmux-continuum/.git"
  printf '%s\n' 1111111111111111111111111111111111111111 \
    > "$workdir/opt/tmux-plugins/tmux-resurrect/.git/FAKE_HEAD"
  printf '%s\n' 2222222222222222222222222222222222222222 \
    > "$workdir/opt/tmux-plugins/tmux-continuum/.git/FAKE_HEAD"
}

run_vscode_step() {
  local workdir="$1"
  local function_file="$workdir/ensure-vscode.sh"

  mkdir -p "$workdir/home"
  extract_vscode_step "$function_file"
  DEVBOX_TEST_LOG="$workdir/commands.log" \
    DEVBOX_TEST_VSCODE_LOG="$workdir/vscode.log" \
    DEVBOX_TEST_VSCODE_VERIFY_LOG="$workdir/vscode-verify.log" \
    DEVBOX_TEST_VSCODE_APT_FAIL="${DEVBOX_TEST_VSCODE_APT_FAIL:-0}" \
    DEVBOX_TEST_VSCODE_LAUNCHER_INSTALL_FAIL="${DEVBOX_TEST_VSCODE_LAUNCHER_INSTALL_FAIL:-0}" \
    DEVBOX_TEST_VSCODE_INSTALL_LOG="$workdir/vscode-install.log" \
    DEV_USER="$test_user" \
    DEV_HOME="$workdir/home" \
    GCP_RUNTIME_BUCKET_FILE="$workdir/etc/devbox/runtime-bucket" \
    BOOTSTRAP_COMPLETE_FILE="$workdir/var/lib/devbox-bootstrap/complete" \
    VSCODE_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/vscode-required" \
    VSCODE_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/vscode-installed" \
    VSCODE_BIN="$workdir/fake-bin/code" \
    VSCODE_LAUNCHER="$workdir/usr/local/bin/devbox-vscode" \
    VSCODE_VERSION=latest \
    APT_KEYRING_DIR="$workdir/etc/apt/keyrings" \
    APT_SOURCE_DIR="$workdir/etc/apt/sources.list.d" \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; ensure_vscode' _ "$function_file"
}

run_vscode_launcher() {
  local workdir="$1"
  DEVBOX_TEST_VSCODE_LAUNCH_LOG="$workdir/launcher.log" \
    DEVBOX_TEST_VSCODE_LOG="$workdir/launcher.log" \
    DEVBOX_TEST_VSCODE_SUDO_FAIL=1 \
    DEVBOX_VSCODE_BIN="$workdir/fake-bin/code" \
    DEVBOX_TAILSCALE_BIN="$workdir/fake-bin/tailscale" \
    PATH="$workdir/fake-bin:$PATH" \
    "$workdir/usr/local/bin/devbox-vscode"
}

test_matching_versions_are_noop() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home/.nvm" \
    "$workdir/npm/@anthropic-ai/claude-code" \
    "$workdir/npm/chrome-devtools-mcp/build/src/bin" \
    "$workdir/data" \
    "$workdir/var/lib/containerd"
  printf '# fake nvm\n' > "$workdir/home/.nvm/nvm.sh"
  : > "$workdir/npm/@anthropic-ai/claude-code/package.json"
  : > "$workdir/npm/chrome-devtools-mcp/package.json"
  : > "$workdir/npm/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
  : > "$workdir/google-chrome"
  chmod 0755 "$workdir/google-chrome"
  make_stub_claude "$workdir/home/.local/bin/claude" ok
  printf '%s %s none bind 0 0\n' "$workdir/data/containerd" "$workdir/var/lib/containerd" > "$workdir/fstab"
  seed_pinned_tmux_plugin_repos "$workdir"
  {
    printf 'set -g mouse on\n\n'
    expected_tmux_plugins_block "$workdir/opt/tmux-plugins"
  } > "$workdir/home/.tmux.conf"

  DEVBOX_TEST_LOG="$workdir/commands.log" \
    DEVBOX_DATA_MOUNT="$workdir/data" \
    DEVBOX_CONTAINERD_STATE_DIR="$workdir/var/lib/containerd" \
    DEVBOX_FSTAB="$workdir/fstab" \
    DEVBOX_DEV_HOME="$workdir/home" \
    DEVBOX_GCP_RUNTIME_BUCKET_FILE="$workdir/etc/devbox/runtime-bucket" \
    DEVBOX_CONNECTORS_FILE="$workdir/etc/devbox-connectors.json" \
    DEVBOX_BOOTSTRAP_COMPLETE_FILE="$workdir/var/lib/devbox-bootstrap/complete" \
    DEVBOX_CODEX_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/codex-cli-required" \
    DEVBOX_CODEX_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/codex-cli-installed" \
    DEVBOX_CODEX_INSTALLER_URL=https://chatgpt.com/codex/install.sh \
    DEVBOX_CODEX_INSTALL_DIR="$workdir/home/.local/bin" \
    DEVBOX_CODEX_BIN="$workdir/home/.local/bin/codex" \
    DEVBOX_PASEO_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/paseo-required" \
    DEVBOX_PASEO_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/paseo-installed" \
    DEVBOX_PASEO_NPM_PREFIX="$workdir/home/.local/share/paseo/npm" \
    DEVBOX_PASEO_PACKAGE_DIR="$workdir/home/.local/share/paseo/npm/lib/node_modules/@getpaseo/cli" \
    DEVBOX_PASEO_USER_BIN="$workdir/home/.local/share/paseo/npm/bin/paseo" \
    DEVBOX_PASEO_BIN="$workdir/home/.local/bin/paseo" \
    DEVBOX_PASEO_SYSTEM_BIN="$workdir/usr/local/bin/paseo" \
    DEVBOX_PASEO_CONFIG_DIR="$workdir/home/.paseo" \
    DEVBOX_PASEO_CONFIG_FILE="$workdir/home/.paseo/config.json" \
    DEVBOX_NEEDRESTART_PASEO_CONFIG_FILE="$workdir/etc/needrestart/conf.d/99-devbox-paseo.conf" \
    DEVBOX_VSCODE_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/vscode-required" \
    DEVBOX_VSCODE_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/vscode-installed" \
    DEVBOX_VSCODE_BIN="$workdir/fake-bin/code" \
    DEVBOX_VSCODE_LAUNCHER="$workdir/usr/local/bin/devbox-vscode" \
    DEVBOX_CLAUDE_BIN="$workdir/home/.local/bin/claude" \
    DEVBOX_DEV_USER="$(id -un)" \
    DEVBOX_CLAUDE_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/claude-code-installed" \
    DEVBOX_CLAUDE_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/claude-code-required" \
    DEVBOX_CLAUDE_OLD_SYSTEM_BIN="$workdir/usr/bin/claude" \
    DEVBOX_CLAUDE_OLD_NPM_DIR="$workdir/npm/@anthropic-ai/claude-code" \
    DEVBOX_CLAUDE_NVM_ROOT="$workdir/home/.nvm/versions/node" \
    CLAUDE_BIN="$workdir/home/.local/bin/claude" \
    DEV_USER="$(id -un)" \
    DEV_HOME="$workdir/home" \
    DEVBOX_AGENT_PLUGINS_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/agent-plugins-required" \
    DEVBOX_AGENT_PLUGINS_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/agent-plugins-installed" \
    DEVBOX_APT_KEYRING_DIR="$workdir/etc/apt/keyrings" \
    DEVBOX_APT_SOURCE_DIR="$workdir/etc/apt/sources.list.d" \
    DEVBOX_SHARE_KEYRING_DIR="$workdir/usr/share/keyrings" \
    DEVBOX_NPM_GLOBAL_DIR="$workdir/npm" \
    DEVBOX_NODE_BIN="$workdir/fake-bin/node" \
    DEVBOX_NPM_BIN="$workdir/fake-bin/npm" \
    DEVBOX_CHROME_BIN="$workdir/google-chrome" \
    DEVBOX_TAILSCALE_VERSION="1.0.0" \
    DEVBOX_DOCKER_CE_VERSION="5:1.0.0-1~ubuntu.24.04~noble" \
    DEVBOX_GH_VERSION="2.0.0" \
    DEVBOX_SYSTEM_NODE_VERSION="22.0.0-1nodesource1" \
    DEVBOX_NVM_VERSION="0.40.0" \
    DEVBOX_NVM_INSTALL_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    DEVBOX_NODE_VERSION="22.0.0" \
    DEVBOX_GOOGLE_CHROME_VERSION="1.0.0-1" \
    DEVBOX_CHROME_DEVTOOLS_MCP_VERSION="1.0.0" \
    DEVBOX_AWS_CLI_VERSION="2.0.0" \
    DEVBOX_AWS_CLI_INSTALL_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    DEVBOX_PASEO_CLI_VERSION="0.1.107" \
    DEVBOX_PASEO_CLI_TARBALL_SHA256="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
    DEVBOX_TMUX_PLUGINS_DIR="$workdir/opt/tmux-plugins" \
    DEVBOX_TMUX_CONF_FILE="$workdir/home/.tmux.conf" \
    DEVBOX_TMUX_BIN="$workdir/fake-bin/tmux" \
    DEVBOX_TMUX_RESURRECT_COMMIT=1111111111111111111111111111111111111111 \
    DEVBOX_TMUX_CONTINUUM_COMMIT=2222222222222222222222222222222222222222 \
    PATH="$workdir/fake-bin:$PATH" \
    "$repo_root/scripts/devbox-toolchain" >"$workdir/toolchain-test.out"

  grep -qF "devbox-toolchain complete" "$workdir/toolchain-test.out" || fail "toolchain did not complete"
  if [ -f "$workdir/commands.log" ] && grep -Eq 'apt-get .* install|npm install' "$workdir/commands.log"; then
    cat "$workdir/commands.log" >&2
    fail "matching versions should not call apt-get install or npm install"
  fi
  if [ -f "$workdir/commands.log" ] && grep -q 'systemctl stop' "$workdir/commands.log"; then
    fail "already-mounted containerd dir should not trigger a migration"
  fi
  [ "$(wc -l < "$workdir/fstab")" -eq 1 ] || fail "fstab entry should not be duplicated when already present"
}

# Boxes built before the containerd bind mount existed: /var/lib/containerd is
# a plain root-volume dir. The toolchain must stop docker/containerd, discard
# the old store, bind-mount /data/containerd over it, and persist the fstab
# entry.
test_containerd_migration() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home/.nvm" \
    "$workdir/npm/@anthropic-ai/claude-code" \
    "$workdir/npm/chrome-devtools-mcp/build/src/bin" \
    "$workdir/data" \
    "$workdir/var/lib/containerd/io.containerd.content.v1.content"
  printf '# fake nvm\n' > "$workdir/home/.nvm/nvm.sh"
  : > "$workdir/npm/@anthropic-ai/claude-code/package.json"
  : > "$workdir/npm/chrome-devtools-mcp/package.json"
  : > "$workdir/npm/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js"
  : > "$workdir/google-chrome"
  chmod 0755 "$workdir/google-chrome"
  : > "$workdir/var/lib/containerd/io.containerd.content.v1.content/old-layer"
  : > "$workdir/fstab"
  make_stub_claude "$workdir/home/.local/bin/claude" ok

  DEVBOX_TEST_LOG="$workdir/commands.log" \
    DEVBOX_TEST_CONTAINERD_MOUNTED_RC=1 \
    DEVBOX_DATA_MOUNT="$workdir/data" \
    DEVBOX_CONTAINERD_STATE_DIR="$workdir/var/lib/containerd" \
    DEVBOX_FSTAB="$workdir/fstab" \
    DEVBOX_DEV_HOME="$workdir/home" \
    DEVBOX_GCP_RUNTIME_BUCKET_FILE="$workdir/etc/devbox/runtime-bucket" \
    DEVBOX_CONNECTORS_FILE="$workdir/etc/devbox-connectors.json" \
    DEVBOX_BOOTSTRAP_COMPLETE_FILE="$workdir/var/lib/devbox-bootstrap/complete" \
    DEVBOX_CODEX_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/codex-cli-required" \
    DEVBOX_CODEX_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/codex-cli-installed" \
    DEVBOX_CODEX_INSTALLER_URL=https://chatgpt.com/codex/install.sh \
    DEVBOX_CODEX_INSTALL_DIR="$workdir/home/.local/bin" \
    DEVBOX_CODEX_BIN="$workdir/home/.local/bin/codex" \
    DEVBOX_PASEO_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/paseo-required" \
    DEVBOX_PASEO_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/paseo-installed" \
    DEVBOX_PASEO_NPM_PREFIX="$workdir/home/.local/share/paseo/npm" \
    DEVBOX_PASEO_PACKAGE_DIR="$workdir/home/.local/share/paseo/npm/lib/node_modules/@getpaseo/cli" \
    DEVBOX_PASEO_USER_BIN="$workdir/home/.local/share/paseo/npm/bin/paseo" \
    DEVBOX_PASEO_BIN="$workdir/home/.local/bin/paseo" \
    DEVBOX_PASEO_SYSTEM_BIN="$workdir/usr/local/bin/paseo" \
    DEVBOX_PASEO_CONFIG_DIR="$workdir/home/.paseo" \
    DEVBOX_PASEO_CONFIG_FILE="$workdir/home/.paseo/config.json" \
    DEVBOX_NEEDRESTART_PASEO_CONFIG_FILE="$workdir/etc/needrestart/conf.d/99-devbox-paseo.conf" \
    DEVBOX_VSCODE_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/vscode-required" \
    DEVBOX_VSCODE_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/vscode-installed" \
    DEVBOX_VSCODE_BIN="$workdir/fake-bin/code" \
    DEVBOX_VSCODE_LAUNCHER="$workdir/usr/local/bin/devbox-vscode" \
    DEVBOX_CLAUDE_BIN="$workdir/home/.local/bin/claude" \
    DEVBOX_DEV_USER="$(id -un)" \
    DEVBOX_CLAUDE_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/claude-code-installed" \
    DEVBOX_CLAUDE_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/claude-code-required" \
    DEVBOX_CLAUDE_OLD_SYSTEM_BIN="$workdir/usr/bin/claude" \
    DEVBOX_CLAUDE_OLD_NPM_DIR="$workdir/npm/@anthropic-ai/claude-code" \
    DEVBOX_CLAUDE_NVM_ROOT="$workdir/home/.nvm/versions/node" \
    CLAUDE_BIN="$workdir/home/.local/bin/claude" \
    DEV_USER="$(id -un)" \
    DEV_HOME="$workdir/home" \
    DEVBOX_AGENT_PLUGINS_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/agent-plugins-required" \
    DEVBOX_AGENT_PLUGINS_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/agent-plugins-installed" \
    DEVBOX_APT_KEYRING_DIR="$workdir/etc/apt/keyrings" \
    DEVBOX_APT_SOURCE_DIR="$workdir/etc/apt/sources.list.d" \
    DEVBOX_SHARE_KEYRING_DIR="$workdir/usr/share/keyrings" \
    DEVBOX_NPM_GLOBAL_DIR="$workdir/npm" \
    DEVBOX_NODE_BIN="$workdir/fake-bin/node" \
    DEVBOX_NPM_BIN="$workdir/fake-bin/npm" \
    DEVBOX_CHROME_BIN="$workdir/google-chrome" \
    DEVBOX_TAILSCALE_VERSION="1.0.0" \
    DEVBOX_DOCKER_CE_VERSION="5:1.0.0-1~ubuntu.24.04~noble" \
    DEVBOX_GH_VERSION="2.0.0" \
    DEVBOX_SYSTEM_NODE_VERSION="22.0.0-1nodesource1" \
    DEVBOX_NVM_VERSION="0.40.0" \
    DEVBOX_NVM_INSTALL_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    DEVBOX_NODE_VERSION="22.0.0" \
    DEVBOX_GOOGLE_CHROME_VERSION="1.0.0-1" \
    DEVBOX_CHROME_DEVTOOLS_MCP_VERSION="1.0.0" \
    DEVBOX_AWS_CLI_VERSION="2.0.0" \
    DEVBOX_AWS_CLI_INSTALL_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    DEVBOX_PASEO_CLI_VERSION="0.1.107" \
    DEVBOX_PASEO_CLI_TARBALL_SHA256="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" \
    DEVBOX_TMUX_PLUGINS_DIR="$workdir/opt/tmux-plugins" \
    DEVBOX_TMUX_CONF_FILE="$workdir/home/.tmux.conf" \
    DEVBOX_TMUX_BIN="$workdir/fake-bin/tmux" \
    DEVBOX_TMUX_RESURRECT_COMMIT=1111111111111111111111111111111111111111 \
    DEVBOX_TMUX_CONTINUUM_COMMIT=2222222222222222222222222222222222222222 \
    PATH="$workdir/fake-bin:$PATH" \
    "$repo_root/scripts/devbox-toolchain" >"$workdir/toolchain-test.out"

  grep -qF "devbox-toolchain complete" "$workdir/toolchain-test.out" || fail "toolchain did not complete during migration"
  grep -q 'systemctl stop docker.socket docker.service containerd.service' "$workdir/commands.log" \
    || fail "migration should stop docker and containerd before moving the store"
  grep -q "mount --bind $workdir/data/containerd $workdir/var/lib/containerd" "$workdir/commands.log" \
    || fail "migration should bind-mount the data-volume containerd dir"
  grep -q 'systemctl start containerd.service docker.service' "$workdir/commands.log" \
    || fail "migration should restart containerd and docker"
  [ ! -e "$workdir/var/lib/containerd/io.containerd.content.v1.content" ] \
    || fail "migration should discard the old root-volume containerd store"
  grep -qF "$workdir/data/containerd $workdir/var/lib/containerd none bind 0 0" "$workdir/fstab" \
    || fail "migration should persist the containerd fstab entry"
  [ -d "$workdir/data/containerd" ] || fail "migration should create /data/containerd"
}

test_agent_plugins_new_gcp_bootstrap_and_post_success_noop() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-runtime/codex-cli-installed"
  : > "$workdir/var/lib/devbox-runtime/claude-code-installed"

  run_agent_plugins_step "$workdir"

  mapfile -t commands < "$workdir/plugin.log"
  [ "${#commands[@]}" -eq 6 ] || fail "new GCP bootstrap did not run all six plugin commands"
  [ "${commands[0]}" = "claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git --scope user" ] \
    || fail "Claude official marketplace was not added at user scope"
  [ "${commands[1]}" = "claude plugin install superpowers@claude-plugins-official --scope user" ] \
    || fail "Superpowers was not installed for Claude Code"
  [ "${commands[2]}" = "claude plugin marketplace add https://github.com/openai/codex-plugin-cc.git --scope user" ] \
    || fail "OpenAI Codex marketplace was not added to Claude Code"
  [ "${commands[3]}" = "claude plugin install codex@openai-codex --scope user" ] \
    || fail "Codex plugin was not installed for Claude Code"
  [ "${commands[4]}" = "codex login status" ] \
    || fail "Codex authentication was not checked before official marketplace use"
  [ "${commands[5]}" = "codex plugin add superpowers@openai-curated" ] \
    || fail "Superpowers was not installed for Codex from the official marketplace"
  if grep -q 'obra/superpowers' "$workdir/plugin.log"; then
    fail "Codex Superpowers must come from openai-curated, not a personal marketplace clone"
  fi
  [ ! -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "successful plugin install did not clear retry marker"
  [ -e "$workdir/var/lib/devbox-runtime/agent-plugins-installed" ] \
    || fail "successful plugin install did not create success marker"

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_agent_plugins_step "$workdir"
  [ "$(wc -l < "$workdir/plugin.log")" -eq 6 ] \
    || fail "plugin commands reran after successful provisioning"
}

test_agent_plugins_defers_codex_until_login_without_failing() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-runtime/codex-cli-installed"
  : > "$workdir/var/lib/devbox-runtime/claude-code-installed"

  DEVBOX_TEST_CODEX_NOT_LOGGED_IN=1 run_agent_plugins_step "$workdir"
  [ "$(wc -l < "$workdir/plugin.log")" -eq 5 ] \
    || fail "logged-out bootstrap did not stop after the Codex login check"
  ! grep -qF "codex plugin add" "$workdir/plugin.log" \
    || fail "logged-out bootstrap attempted to install from the unavailable official marketplace"
  [ -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "logged-out bootstrap did not retain its retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/agent-plugins-installed" ] \
    || fail "logged-out bootstrap created a false success marker"

  run_agent_plugins_step "$workdir"
  [ "$(wc -l < "$workdir/plugin.log")" -eq 11 ] \
    || fail "plugin provisioning did not retry after Codex login"
  [ ! -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "successful post-login retry did not clear its marker"
  [ -e "$workdir/var/lib/devbox-runtime/agent-plugins-installed" ] \
    || fail "successful post-login retry did not create its marker"
}

test_agent_plugins_skip_existing_gcp_and_aws() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p \
    "$workdir/home" \
    "$workdir/etc/devbox" \
    "$workdir/var/lib/devbox-bootstrap" \
    "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  : > "$workdir/var/lib/devbox-runtime/codex-cli-installed"
  : > "$workdir/var/lib/devbox-runtime/claude-code-installed"

  run_agent_plugins_step "$workdir"
  [ ! -e "$workdir/plugin.log" ] || fail "existing GCP box installed agent plugins"
  [ ! -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "existing GCP box armed plugin provisioning"

  rm -f "$workdir/etc/devbox/runtime-bucket" "$workdir/var/lib/devbox-bootstrap/complete"
  run_agent_plugins_step "$workdir"
  [ ! -e "$workdir/plugin.log" ] || fail "AWS box installed agent plugins"
  [ ! -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "AWS box armed plugin provisioning"
}

test_agent_plugins_wait_for_codex_and_retry_after_bootstrap() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-runtime/claude-code-installed"

  if run_agent_plugins_step "$workdir"; then
    fail "agent plugin provisioning succeeded before Codex was ready"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "plugin provisioning did not retain its retry marker while waiting for Codex"
  [ ! -e "$workdir/plugin.log" ] \
    || fail "plugin commands ran before Codex installation completed"

  : > "$workdir/var/lib/devbox-runtime/codex-cli-installed"
  if DEVBOX_TEST_PLUGIN_FAIL_COMMAND="claude plugin install codex@openai-codex --scope user" \
      run_agent_plugins_step "$workdir"; then
    fail "failed Claude plugin install unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "failed plugin install did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/agent-plugins-installed" ] \
    || fail "failed plugin install created a false success marker"

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_agent_plugins_step "$workdir"
  [ "$(wc -l < "$workdir/plugin.log")" -eq 10 ] \
    || fail "plugin provisioning did not stop at failure and retry all idempotent commands"
  [ ! -e "$workdir/var/lib/devbox-runtime/agent-plugins-required" ] \
    || fail "successful plugin retry did not clear retry marker"
  [ -e "$workdir/var/lib/devbox-runtime/agent-plugins-installed" ] \
    || fail "successful plugin retry did not create success marker"
}

test_agent_plugins_wait_for_claude() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/var/lib/devbox-runtime" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-runtime/agent-plugins-required"
  : > "$workdir/var/lib/devbox-runtime/codex-cli-installed"
  # claude marker deliberately absent

  if run_agent_plugins_step "$workdir" >/dev/null 2>&1; then
    fail "agent-plugins ran without a verified claude install"
  fi
  [ ! -f "$workdir/var/lib/devbox-runtime/agent-plugins-installed" ] \
    || fail "agent-plugins recorded success without claude"
}

# make_stub_claude "ok" writes a claude that accepts any invocation
# whatsoever and exits 0 -- a binary that is present, executable, and would
# satisfy every check an executable-bit gate can make. Under
# [ -x "$CLAUDE_BIN" ] this stub would let all the plugin commands run and
# "succeed" against it, so the concern would return 0 and write its success
# marker. No CLAUDE_SUCCESS_FILE is ever seeded here, so the marker gate must
# reject it anyway, before a single plugin command is attempted.
test_agent_plugins_ignores_a_present_but_unverified_claude() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/var/lib/devbox-runtime" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-runtime/agent-plugins-required"
  : > "$workdir/var/lib/devbox-runtime/codex-cli-installed"
  make_stub_claude "$workdir/fake-bin/claude" ok
  # claude marker deliberately absent

  if run_agent_plugins_step "$workdir" >/dev/null 2>&1; then
    fail "agent-plugins ran against a claude that the contract would reject"
  fi
  [ ! -e "$workdir/plugin.log" ] \
    || fail "agent-plugins invoked plugin commands without a verified claude install"
  [ ! -f "$workdir/var/lib/devbox-runtime/agent-plugins-installed" ] \
    || fail "agent-plugins recorded success without a verified claude install"
}

test_codex_new_gcp_bootstrap_and_post_success_noop() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  run_codex_step "$workdir"

  [ -x "$workdir/home/.local/bin/codex" ] || fail "new GCP bootstrap did not install Codex"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "successful Codex install did not clear retry marker"
  grep -q "non_interactive=1 release=unset dir=$workdir/home/.local/bin home=$workdir/home" \
    "$workdir/install.log" || fail "Codex installer did not receive the expected unpinned non-interactive environment"
  if [ ! -f "$workdir/verify.log" ] \
      || ! grep -qxF "verify -u $test_user -H env HOME=$workdir/home $workdir/home/.local/bin/codex --version" \
        "$workdir/verify.log"; then
    fail "Codex command was not verified through the dev-user boundary"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "successful Codex install did not create success marker"
  if [ ! -f "$workdir/state.log" ] \
      || ! grep -qxF \
        "mv -f $workdir/var/lib/devbox-runtime/codex-cli-required $workdir/var/lib/devbox-runtime/codex-cli-installed" \
        "$workdir/state.log"; then
    fail "successful Codex install did not atomically transition retry state to success"
  fi

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_codex_step "$workdir"
  [ "$(wc -l < "$workdir/install.log")" -eq 1 ] \
    || fail "Codex installer reran after successful bootstrap"
}

test_codex_skips_existing_gcp_and_aws() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox" "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-bootstrap/complete"

  run_codex_step "$workdir"
  [ ! -e "$workdir/install.log" ] || fail "existing GCP box installed Codex"

  rm -f "$workdir/etc/devbox/runtime-bucket" "$workdir/var/lib/devbox-bootstrap/complete"
  run_codex_step "$workdir"
  [ ! -e "$workdir/install.log" ] || fail "AWS box installed Codex"
}

test_codex_failure_marker_retries_after_bootstrap() {
  local installer
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_CODEX_INSTALL_FAIL=1 run_codex_step "$workdir"; then
    fail "failed Codex installer unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "failed Codex install did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "failed Codex install created a false success marker"
  installer="$(awk '$1 == "download" { print $2; exit }' "$workdir/download.log")"
  [ -n "$installer" ] || fail "failed Codex install did not record its temporary file"
  [ ! -e "$installer" ] || fail "failed Codex install leaked its temporary file"

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_codex_step "$workdir"
  [ -x "$workdir/home/.local/bin/codex" ] || fail "Codex retry did not install the command"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "successful Codex retry did not clear marker"
  [ "$(wc -l < "$workdir/install.log")" -eq 2 ] \
    || fail "Codex retry did not run exactly once after the initial failure"
}

test_codex_chmod_failure_keeps_marker_and_cleans_installer() {
  local installer
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_CODEX_CHMOD_FAIL=1 run_codex_step "$workdir"; then
    fail "failed Codex installer chmod unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "failed Codex installer chmod did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "failed Codex installer chmod created a false success marker"
  [ ! -e "$workdir/install.log" ] \
    || fail "Codex installer ran after chmod failed"

  installer="$(awk '$1 == "chmod" { print $3 }' "$workdir/chmod.log")"
  [ -n "$installer" ] || fail "Codex installer chmod was not attempted"
  [ ! -e "$installer" ] || fail "failed Codex installer chmod leaked its temporary file"
}

test_codex_success_tombstone_prevents_rearm() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  run_codex_step "$workdir"
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "successful Codex install did not create a durable success marker"

  run_codex_step "$workdir"
  [ "$(wc -l < "$workdir/install.log")" -eq 1 ] \
    || fail "Codex installer reran while the same bootstrap was still incomplete"
  [ "$(wc -l < "$workdir/verify.log")" -eq 1 ] \
    || fail "Codex verification reran while the same bootstrap was still incomplete"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "successful Codex install re-armed the retry marker"
}

test_codex_download_failure_keeps_marker_and_cleans_installer() {
  local installer
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_CODEX_DOWNLOAD_FAIL=1 run_codex_step "$workdir"; then
    fail "failed Codex installer download unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "failed Codex installer download did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "failed Codex installer download created a false success marker"
  [ ! -e "$workdir/install.log" ] || fail "Codex installer ran after download failed"
  [ ! -e "$workdir/verify.log" ] || fail "Codex command was verified after download failed"
  [ ! -e "$workdir/home/.local/bin/codex" ] || fail "failed Codex download produced a command"

  installer="$(awk '$1 == "download" { print $2; exit }' "$workdir/download.log")"
  [ -n "$installer" ] || fail "failed Codex download did not record its temporary file"
  [ ! -e "$installer" ] || fail "failed Codex installer download leaked its temporary file"
}

test_codex_verification_failure_keeps_marker_and_cleans_installer() {
  local installer
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_CODEX_VERIFY_FAIL=1 run_codex_step "$workdir"; then
    fail "failed Codex command verification unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "failed Codex command verification did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "failed Codex command verification created a false success marker"
  [ "$(wc -l < "$workdir/install.log")" -eq 1 ] \
    || fail "Codex installer did not complete before verification failure"
  if [ ! -f "$workdir/verify.log" ] \
      || ! grep -qxF "verify -u $test_user -H env HOME=$workdir/home $workdir/home/.local/bin/codex --version" \
        "$workdir/verify.log"; then
    fail "failed Codex verification did not cross the dev-user boundary"
  fi

  installer="$(awk '$1 == "download" { print $2; exit }' "$workdir/download.log")"
  [ -n "$installer" ] || fail "failed Codex verification did not record its temporary installer"
  [ ! -e "$installer" ] || fail "failed Codex command verification leaked its temporary installer"
}

test_codex_atomic_state_move_failure_retains_retry() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_CODEX_STATE_MOVE_FAIL=1 run_codex_step "$workdir"; then
    fail "failed Codex state transition unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "failed Codex state transition did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "failed Codex state transition created a false success marker"
  grep -qxF \
    "mv -f $workdir/var/lib/devbox-runtime/codex-cli-required $workdir/var/lib/devbox-runtime/codex-cli-installed" \
    "$workdir/state.log" || fail "Codex state transition did not use the required atomic move"
}

test_codex_success_dominates_stale_retry_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-runtime/codex-cli-required"
  : > "$workdir/var/lib/devbox-runtime/codex-cli-installed"

  run_codex_step "$workdir"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "durable Codex success did not clear stale retry marker"
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "durable Codex success marker disappeared"
  [ ! -e "$workdir/download.log" ] || fail "stale Codex retry marker triggered a download"
  [ ! -e "$workdir/install.log" ] || fail "stale Codex retry marker triggered an install"
  [ ! -e "$workdir/verify.log" ] || fail "stale Codex retry marker triggered verification"
}

test_codex_replacement_root_is_eligible_again() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  make_fake_codex_installer "$workdir/install.sh"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  run_codex_step "$workdir"
  [ -x "$workdir/home/.local/bin/codex" ] || fail "initial root did not install Codex"

  rm -f \
    "$workdir/var/lib/devbox-runtime/codex-cli-required" \
    "$workdir/var/lib/devbox-runtime/codex-cli-installed"
  run_codex_step "$workdir"

  [ "$(wc -l < "$workdir/install.log")" -eq 2 ] \
    || fail "replacement root did not reinstall Codex into the preserved home"
  [ "$(wc -l < "$workdir/verify.log")" -eq 2 ] \
    || fail "replacement root did not reverify Codex"
  [ ! -e "$workdir/var/lib/devbox-runtime/codex-cli-required" ] \
    || fail "replacement root retained retry marker after success"
  [ -e "$workdir/var/lib/devbox-runtime/codex-cli-installed" ] \
    || fail "replacement root did not create success marker"
}

test_vscode_new_gcp_bootstrap_and_post_success_noop() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  run_vscode_step "$workdir"

  grep -qF 'apt-get -o DPkg::Lock::Timeout=300 install -y code' "$workdir/commands.log" \
    || fail "new GCP bootstrap did not install VS Code"
  grep -qF 'https://packages.microsoft.com/repos/code' "$workdir/etc/apt/sources.list.d/vscode.sources" \
    || fail "VS Code source does not use the Microsoft repository"
  grep -qF 'Signed-By: '"$workdir/etc/apt/keyrings/microsoft.gpg" \
    "$workdir/etc/apt/sources.list.d/vscode.sources" \
    || fail "VS Code source does not use the Microsoft signing key"
  grep -qxF 'code --version' "$workdir/vscode.log" \
    || fail "VS Code version was not verified"
  grep -qxF 'code serve-web --help' "$workdir/vscode.log" \
    || fail "VS Code serve-web support was not verified"
  grep -qxF "verify -u $test_user -H env HOME=$workdir/home $workdir/fake-bin/code --version" \
    "$workdir/vscode-verify.log" \
    || fail "VS Code version verification did not run as the dev user"
  grep -qxF "verify -u $test_user -H env HOME=$workdir/home $workdir/fake-bin/code serve-web --help" \
    "$workdir/vscode-verify.log" \
    || fail "VS Code serve-web verification did not run as the dev user"
  [ -x "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "successful VS Code install did not create devbox-vscode"
  run_vscode_launcher "$workdir"
  mapfile -t launcher_lines < "$workdir/launcher.log"
  [ "${#launcher_lines[@]}" -eq 2 ] \
    || fail "devbox-vscode did not emit exactly the expected launcher commands"
  [ "${launcher_lines[0]}" = 'tailscale serve --yes --bg 8000' ] \
    || fail "devbox-vscode did not enable Tailscale Serve"
  [ "${launcher_lines[1]}" = 'code serve-web --host 127.0.0.1 --without-connection-token --port 8000' ] \
    || fail "devbox-vscode did not run the loopback VS Code server"
  [ -e "$workdir/var/lib/devbox-runtime/vscode-installed" ] \
    || fail "successful VS Code install did not create success marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "successful VS Code install did not clear retry marker"

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_vscode_step "$workdir"
  [ "$(grep -cF 'install -y code' "$workdir/commands.log")" -eq 1 ] \
    || fail "VS Code installed more than once after success"
}

test_vscode_skips_existing_gcp_and_aws() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox" "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-bootstrap/complete"

  run_vscode_step "$workdir"
  [ ! -e "$workdir/commands.log" ] || fail "existing GCP box installed VS Code"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "existing GCP box armed VS Code provisioning"
  [ ! -e "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "ineligible devbox received devbox-vscode"

  rm -f "$workdir/etc/devbox/runtime-bucket" "$workdir/var/lib/devbox-bootstrap/complete"
  run_vscode_step "$workdir"
  [ ! -e "$workdir/commands.log" ] || fail "AWS box installed VS Code"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "AWS box armed VS Code provisioning"
  [ ! -e "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "ineligible devbox received devbox-vscode"
}

test_vscode_failure_marker_retries_after_bootstrap() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_VSCODE_APT_FAIL=1 run_vscode_step "$workdir"; then
    fail "failed VS Code package install unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "failed VS Code package install did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-installed" ] \
    || fail "failed VS Code package install created a false success marker"

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_vscode_step "$workdir"
  [ -e "$workdir/var/lib/devbox-runtime/vscode-installed" ] \
    || fail "VS Code retry did not create success marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "successful VS Code retry did not clear retry marker"
  [ "$(grep -cF 'install -y code' "$workdir/commands.log")" -eq 2 ] \
    || fail "VS Code retry did not rerun package installation"
}

test_vscode_launcher_install_failure_keeps_marker_and_cleans_tmp() {
  local workdir
  local launcher_tmp
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_VSCODE_LAUNCHER_INSTALL_FAIL=1 run_vscode_step "$workdir"; then
    fail "failed VS Code launcher install unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "failed VS Code launcher install did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-installed" ] \
    || fail "failed VS Code launcher install created a false success marker"
  [ ! -e "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "failed VS Code launcher install created the launcher"
  launcher_tmp="$(awk '$1 == "install" { print $2; exit }' "$workdir/vscode-install.log")"
  [ -n "$launcher_tmp" ] || fail "failed VS Code launcher install did not log its temporary source"
  [ ! -e "$launcher_tmp" ] || fail "failed VS Code launcher install leaked its temporary source"

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_vscode_step "$workdir"
  [ -e "$workdir/var/lib/devbox-runtime/vscode-installed" ] \
    || fail "successful VS Code launcher retry did not create success marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "successful VS Code launcher retry did not clear retry marker"
  [ -x "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "successful VS Code launcher retry did not create the launcher"
}

test_vscode_success_marker_repairs_missing_launcher() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  run_vscode_step "$workdir"
  [ -x "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "initial VS Code install did not create devbox-vscode"

  rm -f "$workdir/usr/local/bin/devbox-vscode"
  : > "$workdir/var/lib/devbox-runtime/vscode-required"
  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"

  run_vscode_step "$workdir"
  [ -x "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "durable VS Code success did not repair the launcher"
  [ ! -e "$workdir/var/lib/devbox-runtime/vscode-required" ] \
    || fail "durable VS Code success did not clear stale retry marker"
  [ "$(grep -cF 'install -y code' "$workdir/commands.log")" -eq 1 ] \
    || fail "durable VS Code success reran package installation while repairing the launcher"
}

test_vscode_launcher_stops_when_tailscale_serve_fails() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  run_vscode_step "$workdir"
  [ -x "$workdir/usr/local/bin/devbox-vscode" ] \
    || fail "successful VS Code install did not create devbox-vscode"

  rm -f "$workdir/launcher.log"
  if DEVBOX_TEST_TAILSCALE_SERVE_FAIL=1 run_vscode_launcher "$workdir"; then
    fail "devbox-vscode succeeded even though Tailscale Serve failed"
  fi
  if [ -e "$workdir/launcher.log" ] \
      && grep -qF 'code serve-web --host 127.0.0.1 --without-connection-token --port 8000' \
        "$workdir/launcher.log"; then
    fail "devbox-vscode ran the loopback VS Code server after Tailscale Serve failed"
  fi
}

test_paseo_new_gcp_bootstrap_installs_pinned_tarball_and_writes_tailnet_config() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  run_paseo_step "$workdir"

  grep -q '^download https://registry.npmjs.org/@getpaseo/cli/-/cli-0.1.107.tgz ' \
    "$workdir/paseo-download.log" \
    || fail "new GCP bootstrap did not fetch the pinned Paseo tarball from the registry"
  grep -Eq '^npm install -g [^ ]+/paseo-cli\.tgz$' "$workdir/commands.log" \
    || fail "new GCP bootstrap did not install Paseo from the verified local tarball"
  grep -Eq \
    "^install -u $test_user -H env HOME=$workdir/home NPM_CONFIG_PREFIX=$workdir/home/.local/share/paseo/npm $workdir/fake-bin/npm install -g [^ ]+/paseo-cli\.tgz$" \
    "$workdir/paseo-install-boundary.log" \
    || fail "Paseo npm install did not cross the dev-user prefix boundary"
  grep -qxF \
    "verify -u $test_user -H env HOME=$workdir/home NPM_CONFIG_PREFIX=$workdir/home/.local/share/paseo/npm $workdir/home/.local/bin/paseo --version" \
    "$workdir/paseo-verify.log" \
    || fail "Paseo command verification did not cross the dev-user boundary"
  awk -v dest="$workdir/home/.local/bin/paseo" -v u="$test_user" '
    $1 == "install" && $2 == "-o" && $3 == u &&
      $4 == "-g" && $5 == u && $6 == "-m" && $7 == "0755" &&
      $NF == dest { found = 1 }
    END { exit !found }
  ' "$workdir/paseo-launcher-install.log" \
    || fail "Paseo user launcher was not installed as dev"
  awk -v dest="$workdir/usr/local/bin/paseo" '
    $1 == "install" && $2 == "-m" && $3 == "0755" && $NF == dest { found = 1 }
    END { exit !found }
  ' "$workdir/paseo-launcher-install.log" \
    || fail "Paseo system fallback launcher was not installed"
  [ -x "$workdir/home/.local/bin/paseo" ] \
    || fail "Paseo provisioning did not create the user launcher"
  [ -x "$workdir/usr/local/bin/paseo" ] \
    || fail "Paseo provisioning did not create the system fallback launcher"
  [ -x "$workdir/home/.local/share/paseo/npm/bin/paseo" ] \
    || fail "Paseo provisioning did not create the user-owned command"
  [ -d "$workdir/home/.local/share/paseo/npm/lib/node_modules/@getpaseo/cli" ] \
    || fail "Paseo provisioning did not create the user-owned package"
  [ "$(stat -c '%U:%G' "$workdir/home/.local/share/paseo/npm")" = "$test_user:$test_user" ] \
    || fail "Paseo npm prefix is not owned by dev"
  [ "$(stat -c '%U:%G' "$workdir/home/.local/share/paseo/npm/bin/paseo")" = "$test_user:$test_user" ] \
    || fail "Paseo user command is not owned by dev"
  [ "$(stat -c '%U:%G' "$workdir/home/.local/share/paseo/npm/lib/node_modules/@getpaseo/cli")" = "$test_user:$test_user" ] \
    || fail "Paseo package is not owned by dev"
  [ "$(stat -c '%U:%G' "$workdir/home/.local/bin/paseo")" = "$test_user:$test_user" ] \
    || fail "Paseo user launcher is not owned by dev"
  [ ! -e "$workdir/home/.npmrc" ] \
    || fail "Paseo provisioning changed the dev user's general npm prefix"
  [ ! -e "$workdir/paseo-runtime.log" ] \
    || fail "Paseo provisioning invoked a runtime command instead of only --version"
  if NPM_CONFIG_PREFIX='' DEVBOX_TEST_PASEO_RUNTIME_LOG="$workdir/paseo-runtime.log" \
      "$workdir/home/.local/bin/paseo" daemon status; then
    fail "fake Paseo runtime command unexpectedly succeeded"
  elif [ "$?" -ne 53 ]; then
    fail "Paseo launcher did not preserve the user command's exit status"
  fi
  grep -qxF \
    "prefix=$workdir/home/.local/share/paseo/npm paseo daemon status" \
    "$workdir/paseo-runtime.log" \
    || fail "Paseo launcher did not inject the self-update npm prefix"
  mkdir -p "$workdir/home/.nvm/versions/node/v22.22.2/bin"
  printf '# old NVM Paseo\n' > "$workdir/home/.nvm/versions/node/v22.22.2/bin/paseo"
  chmod 0755 "$workdir/home/.nvm/versions/node/v22.22.2/bin/paseo"
  [ "$(PATH="$workdir/home/.local/bin:$workdir/home/.nvm/versions/node/v22.22.2/bin:$workdir/usr/local/bin:$PATH" command -v paseo)" \
      = "$workdir/home/.local/bin/paseo" ] \
    || fail "Paseo user launcher did not take precedence over an existing NVM install"
  [ -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "successful Paseo provisioning did not create the success marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "successful Paseo provisioning retained the retry marker"

  jq -e '
    .version == 1 and
    .daemon.listen == "100.64.10.20:6767" and
    .daemon.hostnames == [
      "alice-devbox",
      "alice-devbox.example-tailnet.ts.net"
    ] and
    .daemon.cors.allowedOrigins == [
      "https://app.paseo.sh",
      "http://100.64.10.20:6767",
      "http://alice-devbox:6767",
      "http://alice-devbox.example-tailnet.ts.net:6767"
    ] and
    .daemon.relay.enabled == false and
    .features.webUi.enabled == false and
    (.daemon.auth | not)
  ' "$workdir/home/.paseo/config.json" >/dev/null \
    || fail "Paseo config did not enforce the approved Tailscale-only settings"
  [ "$(stat -c '%a' "$workdir/home/.paseo")" = 700 ] \
    || fail "Paseo home directory mode is not 0700"
  [ "$(stat -c '%a' "$workdir/home/.paseo/config.json")" = 600 ] \
    || fail "Paseo config mode is not 0600"
  [ "$(stat -c '%U:%G' "$workdir/home/.paseo")" = "$test_user:$test_user" ] \
    || fail "Paseo home directory is not owned by dev"
  [ "$(stat -c '%U:%G' "$workdir/home/.paseo/config.json")" = "$test_user:$test_user" ] \
    || fail "Paseo config is not owned by dev"
}

test_paseo_tarball_download_failure_retains_retry_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_PASEO_DOWNLOAD_FAIL=1 run_paseo_step "$workdir" >/dev/null 2>&1; then
    fail "failed Paseo tarball download unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "failed Paseo tarball download did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "failed Paseo tarball download created a false success marker"
  if [ -f "$workdir/commands.log" ] && grep -q 'npm install' "$workdir/commands.log"; then
    fail "npm install ran despite a failed Paseo tarball download"
  fi
}

test_paseo_tarball_sha_mismatch_retains_retry_marker() {
  local tarball workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_PASEO_CLI_TARBALL_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
      run_paseo_step "$workdir" >/dev/null 2>&1; then
    fail "Paseo install succeeded despite a tarball pin mismatch"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "Paseo tarball pin mismatch did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "Paseo tarball pin mismatch created a false success marker"
  if [ -f "$workdir/commands.log" ] && grep -q 'npm install' "$workdir/commands.log"; then
    fail "npm touched an unverified Paseo tarball"
  fi
  tarball="$(awk '$1 == "download" { print $3; exit }' "$workdir/paseo-download.log")"
  [ -n "$tarball" ] || fail "Paseo tarball pin mismatch did not record the downloaded file"
  [ ! -e "$tarball" ] || fail "Paseo tarball pin mismatch leaked the unverified tarball"
}

test_paseo_pinned_version_mismatch_retains_retry_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  # The fake npm installs a paseo reporting 0.1.107; pin a different version.
  if DEVBOX_PASEO_CLI_VERSION=9.9.9 run_paseo_step "$workdir" >/dev/null 2>&1; then
    fail "Paseo install succeeded despite reporting a version other than the pin"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "Paseo version mismatch did not retain retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "Paseo version mismatch created a false success marker"
}

test_paseo_success_reconciles_boot_enabled_daemon() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox" "$workdir/home/.paseo" "$workdir/usr/bin" \
    "$workdir/var/lib/devbox-bootstrap" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  : > "$workdir/var/lib/devbox-runtime/paseo-installed"
  printf '{}\n' > "$workdir/home/.paseo/config.json"
  cat > "$workdir/usr/bin/paseo" <<'EOF'
#!/usr/bin/env bash
printf 'paseo %s\n' "$*" >> "$DEVBOX_TEST_PASEO_RUNTIME_LOG"
case "$*" in
  "daemon status"|"daemon status --json")
    printf '{"localDaemon":"stopped"}\n'
    exit 0
    ;;
  "daemon start --foreground")
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
EOF
  chmod 0755 "$workdir/usr/bin/paseo"

  run_paseo_step "$workdir"

  [ -x "$workdir/usr/local/bin/devbox-paseo-daemon" ] \
    || fail "Paseo daemon runner was not installed"
  [ -f "$workdir/etc/systemd/system/paseo.service" ] \
    || fail "Paseo systemd service was not installed"
  grep -qxF "RequiresMountsFor=$workdir/home" \
    "$workdir/etc/systemd/system/paseo.service" \
    || fail "Paseo service can start before the persistent home is mounted"
  grep -qxF "User=$test_user" "$workdir/etc/systemd/system/paseo.service" \
    || fail "Paseo service does not run as dev"
  grep -qxF \
    "Environment=PATH=$workdir/home/.local/bin:$workdir/home/.nvm/versions/node/v22.22.2/bin:$workdir/usr/local/bin:/usr/bin:/bin" \
    "$workdir/etc/systemd/system/paseo.service" \
    || fail "Paseo service cannot discover the devbox-managed agent commands"
  grep -qxF "ExecStart=$workdir/usr/local/bin/devbox-paseo-daemon" \
    "$workdir/etc/systemd/system/paseo.service" \
    || fail "Paseo service does not use the managed foreground runner"
  grep -qxF 'Restart=always' "$workdir/etc/systemd/system/paseo.service" \
    || fail "Paseo service will not recover after the daemon exits"
  grep -qxF 'KillMode=control-group' "$workdir/etc/systemd/system/paseo.service" \
    || fail "Paseo service will not stop the foreground daemon process group cleanly"
  grep -qxF 'WantedBy=multi-user.target' "$workdir/etc/systemd/system/paseo.service" \
    || fail "Paseo service is not attached to the boot target"
  grep -qxF 'systemctl daemon-reload' "$workdir/commands.log" \
    || fail "Paseo service install did not reload systemd"
  grep -qxF 'systemctl enable --now paseo.service' "$workdir/commands.log" \
    || fail "Paseo service was not enabled persistently and started"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$workdir/etc/systemd/system/paseo.service" \
      || fail "Paseo systemd service failed systemd-analyze verification"
  fi

  if ! timeout 2 env DEVBOX_TEST_PASEO_RUNTIME_LOG="$workdir/paseo-runtime.log" \
      "$workdir/usr/local/bin/devbox-paseo-daemon"; then
    fail "Paseo daemon runner did not recognize a successful stopped status"
  fi
  grep -qxF 'paseo daemon status --json' "$workdir/paseo-runtime.log" \
    || fail "Paseo daemon runner did not inspect structured local daemon state"
  grep -qxF 'paseo daemon start --foreground' "$workdir/paseo-runtime.log" \
    || fail "Paseo daemon runner did not hand foreground supervision to systemd"
}

test_paseo_daemon_runner_preserves_then_takes_over_detached_daemon() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox" "$workdir/home/.paseo" "$workdir/usr/bin" \
    "$workdir/var/lib/devbox-bootstrap" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  : > "$workdir/var/lib/devbox-runtime/paseo-installed"
  printf '{}\n' > "$workdir/home/.paseo/config.json"
  cat > "$workdir/usr/bin/paseo" <<'EOF'
#!/usr/bin/env bash
printf 'paseo %s\n' "$*" >> "$DEVBOX_TEST_PASEO_RUNTIME_LOG"
case "$*" in
  "daemon status --json")
    count="$(cat "$DEVBOX_TEST_PASEO_STATUS_COUNT" 2>/dev/null || printf 0)"
    count=$((count + 1))
    printf '%s\n' "$count" > "$DEVBOX_TEST_PASEO_STATUS_COUNT"
    if [ "$count" -eq 1 ]; then
      printf '{"localDaemon":"running","pid":1234}\n'
    else
      printf '{"localDaemon":"stopped","pid":null}\n'
    fi
    ;;
  "daemon start --foreground")
    ;;
  *)
    exit 2
    ;;
esac
EOF
  cat > "$workdir/fake-bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 0755 "$workdir/usr/bin/paseo" "$workdir/fake-bin/sleep"

  run_paseo_step "$workdir"
  DEVBOX_TEST_PASEO_RUNTIME_LOG="$workdir/paseo-runtime.log" \
    DEVBOX_TEST_PASEO_STATUS_COUNT="$workdir/paseo-status-count" \
    PATH="$workdir/fake-bin:$PATH" \
    "$workdir/usr/local/bin/devbox-paseo-daemon"

  [ "$(cat "$workdir/paseo-status-count")" -eq 2 ] \
    || fail "Paseo daemon runner did not wait for the detached daemon to exit"
  [ "$(grep -cxF 'paseo daemon status --json' "$workdir/paseo-runtime.log")" -eq 2 ] \
    || fail "Paseo daemon runner did not recheck detached daemon liveness"
  ! grep -qF 'paseo daemon stop' "$workdir/paseo-runtime.log" \
    || fail "Paseo daemon runner interrupted the existing detached daemon"
  tail -1 "$workdir/paseo-runtime.log" | grep -qxF 'paseo daemon start --foreground' \
    || fail "Paseo daemon runner did not take over after the detached daemon exited"
}

test_paseo_daemon_reload_failure_is_retryable() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/etc/devbox" "$workdir/home/.paseo" "$workdir/usr/bin" \
    "$workdir/var/lib/devbox-bootstrap" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  : > "$workdir/var/lib/devbox-runtime/paseo-installed"
  printf '{}\n' > "$workdir/home/.paseo/config.json"
  printf '#!/bin/sh\nexit 0\n' > "$workdir/usr/bin/paseo"
  chmod 0755 "$workdir/usr/bin/paseo"

  if DEVBOX_TEST_DAEMON_RELOAD_FAIL=1 run_paseo_step "$workdir"; then
    fail "Paseo daemon reconciliation succeeded after systemd rejected its unit"
  fi
  run_paseo_step "$workdir"

  [ "$(grep -cxF 'systemctl daemon-reload' "$workdir/commands.log")" -eq 2 ] \
    || fail "Paseo daemon reconciliation did not retry a failed systemd reload"
  grep -qxF 'systemctl enable --now paseo.service' "$workdir/commands.log" \
    || fail "Paseo daemon reconciliation did not enable the service after retry"
}

test_paseo_success_marker_leaves_preinstalled_box_alone() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home/.paseo" "$workdir/usr/bin" \
    "$workdir/var/lib/devbox-bootstrap" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  : > "$workdir/var/lib/devbox-runtime/paseo-installed"
  printf '{}\n' > "$workdir/home/.paseo/config.json"
  printf '#!/bin/sh\nexit 0\n' > "$workdir/usr/bin/paseo"
  chmod 0755 "$workdir/usr/bin/paseo"

  run_paseo_step "$workdir"

  [ ! -e "$workdir/commands.log" ] \
    || fail "success-marked box received Paseo service management"
  [ ! -e "$workdir/usr/local/bin/devbox-paseo-daemon" ] \
    || fail "success-marked AWS box received the Paseo daemon runner"
  [ ! -e "$workdir/etc/systemd/system/paseo.service" ] \
    || fail "success-marked AWS box received the Paseo systemd service"
}

test_paseo_existing_gcp_reconciles_daemon_without_reinstall_and_aws_skips() {
  local root_paseo workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox" "$workdir/usr/bin" \
    "$workdir/var/lib/devbox-bootstrap" "$workdir/var/lib/devbox-runtime"
  : > "$workdir/etc/devbox/runtime-bucket"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  : > "$workdir/var/lib/devbox-runtime/paseo-installed"
  : > "$workdir/var/lib/devbox-runtime/paseo-required"
  root_paseo="$workdir/usr/bin/paseo"
  printf '# existing root-owned Paseo\n' > "$root_paseo"
  chmod 0755 "$root_paseo"

  run_paseo_step "$workdir"
  ! grep -qF 'npm install' "$workdir/commands.log" \
    || fail "existing GCP box reinstalled Paseo"
  [ ! -e "$workdir/home/.paseo/config.json" ] || fail "existing GCP box configured Paseo"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "existing GCP success did not clear its stale retry marker"
  grep -qxF '# existing root-owned Paseo' "$root_paseo" \
    || fail "existing GCP success changed the root-owned Paseo command"
  [ ! -e "$workdir/usr/local/bin/paseo" ] \
    || fail "existing GCP success created the Paseo system fallback launcher"
  [ ! -e "$workdir/home/.local/bin/paseo" ] \
    || fail "existing GCP success created the Paseo user launcher"
  [ ! -e "$workdir/home/.local/share/paseo/npm" ] \
    || fail "existing GCP success created the user-owned Paseo prefix"

  rm -f "$workdir/etc/devbox/runtime-bucket" \
    "$workdir/var/lib/devbox-bootstrap/complete" \
    "$workdir/var/lib/devbox-runtime/paseo-installed" \
    "$workdir/commands.log"
  run_paseo_step "$workdir"
  [ ! -e "$workdir/commands.log" ] || fail "AWS box installed Paseo"
  [ ! -e "$workdir/home/.paseo/config.json" ] || fail "AWS box configured Paseo"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "AWS box armed Paseo provisioning"
}

test_paseo_failure_marker_retries_after_bootstrap() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_PASEO_INSTALL_FAIL=1 run_paseo_step "$workdir"; then
    fail "failed Paseo npm install unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "failed Paseo install did not retain its retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "failed Paseo install created a false success marker"
  [ ! -e "$workdir/home/.paseo/config.json" ] \
    || fail "failed Paseo install wrote configuration"

  mkdir -p "$workdir/var/lib/devbox-bootstrap"
  : > "$workdir/var/lib/devbox-bootstrap/complete"
  run_paseo_step "$workdir"
  [ -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "Paseo retry after bootstrap did not create a success marker"
  [ "$(grep -cE '^npm install -g [^ ]+/paseo-cli\.tgz$' "$workdir/commands.log")" -eq 2 ] \
    || fail "Paseo retry did not install the pinned tarball again"
}

test_paseo_tailscale_failure_retains_retry_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_PASEO_TAILSCALE_STATUS_FAIL=1 run_paseo_step "$workdir"; then
    fail "Paseo provisioning succeeded without a Tailscale identity"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "Tailscale failure did not retain the Paseo retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "Tailscale failure created a false Paseo success marker"
  [ ! -e "$workdir/home/.paseo/config.json" ] \
    || fail "Tailscale failure wrote a Paseo config"
}

test_paseo_verification_failure_retains_retry_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_PASEO_VERIFY_FAIL=1 run_paseo_step "$workdir"; then
    fail "Paseo provisioning succeeded after command verification failed"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "verification failure did not retain the Paseo retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "verification failure created a false Paseo success marker"
  [ ! -e "$workdir/tailscale.log" ] \
    || fail "Paseo provisioning queried Tailscale after verification failed"
}

test_paseo_invalid_existing_config_retains_retry_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home/.paseo" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"
  printf '{not-json\n' > "$workdir/home/.paseo/config.json"

  if run_paseo_step "$workdir"; then
    fail "Paseo provisioning overwrote an invalid existing config"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "invalid config did not retain the Paseo retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "invalid config created a false Paseo success marker"
  grep -qxF '{not-json' "$workdir/home/.paseo/config.json" \
    || fail "Paseo provisioning mutated an invalid existing config"
  if find "$workdir/home/.paseo" -maxdepth 1 -name '.config.*' -print -quit | grep -q .; then
    fail "Paseo config failure leaked a temporary file"
  fi
}

test_paseo_merge_preserves_unmanaged_settings_and_success_is_noop() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home/.paseo" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"
  cat > "$workdir/home/.paseo/config.json" <<'EOF'
{
  "version": 1,
  "daemon": {
    "listen": "0.0.0.0:9999",
    "mcp": {"enabled": false},
    "relay": {"enabled": true, "endpoint": "relay.invalid:443"}
  },
  "features": {
    "webUi": {"enabled": true, "distDir": "custom-web"}
  },
  "worktrees": {"root": "/data/worktrees"}
}
EOF

  run_paseo_step "$workdir"

  jq -e '
    .daemon.mcp.enabled == false and
    .daemon.relay == {"enabled": false, "endpoint": "relay.invalid:443"} and
    .features.webUi == {"enabled": false, "distDir": "custom-web"} and
    .worktrees.root == "/data/worktrees" and
    .daemon.listen == "100.64.10.20:6767"
  ' "$workdir/home/.paseo/config.json" >/dev/null \
    || fail "Paseo config merge lost unmanaged settings or retained unsafe settings"

  run_paseo_step "$workdir"
  [ "$(grep -cE '^npm install -g [^ ]+/paseo-cli\.tgz$' "$workdir/commands.log")" -eq 1 ] \
    || fail "successful Paseo provisioning upgraded during later convergence"
  [ "$(wc -l < "$workdir/paseo-verify.log")" -eq 1 ] \
    || fail "successful Paseo provisioning reverified during later convergence"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "durable Paseo success rearmed the retry marker"
}

test_paseo_atomic_state_failure_retains_retry_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home" "$workdir/etc/devbox"
  : > "$workdir/etc/devbox/runtime-bucket"

  if DEVBOX_TEST_PASEO_STATE_MOVE_FAIL=1 run_paseo_step "$workdir"; then
    fail "failed Paseo state transition unexpectedly succeeded"
  fi
  [ -e "$workdir/var/lib/devbox-runtime/paseo-required" ] \
    || fail "failed Paseo state transition did not retain its retry marker"
  [ ! -e "$workdir/var/lib/devbox-runtime/paseo-installed" ] \
    || fail "failed Paseo state transition created a false success marker"
}

test_tmux_plugins_clones_pins_and_appends_block() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home"
  printf 'set -g mouse on\nset -g status-right "#h"\n' > "$workdir/home/.tmux.conf"

  run_tmux_plugins_step "$workdir"

  grep -qF "git init -q $workdir/opt/tmux-plugins/tmux-resurrect" "$workdir/git.log" \
    || fail "tmux-resurrect was not initialized"
  grep -qF "remote add origin https://github.com/tmux-plugins/tmux-resurrect.git" "$workdir/git.log" \
    || fail "tmux-resurrect origin was not configured"
  grep -qF "fetch -q --depth 1 origin 1111111111111111111111111111111111111111" "$workdir/git.log" \
    || fail "tmux-resurrect pin was not fetched"
  grep -qF "remote add origin https://github.com/tmux-plugins/tmux-continuum.git" "$workdir/git.log" \
    || fail "tmux-continuum origin was not configured"
  [ "$(cat "$workdir/opt/tmux-plugins/tmux-resurrect/.git/FAKE_HEAD")" = 1111111111111111111111111111111111111111 ] \
    || fail "tmux-resurrect was not checked out at its pin"
  [ "$(cat "$workdir/opt/tmux-plugins/tmux-continuum/.git/FAKE_HEAD")" = 2222222222222222222222222222222222222222 ] \
    || fail "tmux-continuum was not checked out at its pin"

  head -n 2 "$workdir/home/.tmux.conf" \
    | diff - <(printf 'set -g mouse on\nset -g status-right "#h"\n') >/dev/null \
    || fail "existing tmux.conf content was not preserved"
  tail -n 6 "$workdir/home/.tmux.conf" \
    | diff - <(expected_tmux_plugins_block "$workdir/opt/tmux-plugins") >/dev/null \
    || fail "managed block was not appended verbatim at the end"
  [ "$(grep -cF '>>> devbox-managed: tmux plugins >>>' "$workdir/home/.tmux.conf")" -eq 1 ] \
    || fail "managed block should appear exactly once"
  [ ! -f "$workdir/tmux-reload.log" ] \
    || fail "live reload should not run without a tmux server socket"
}

test_tmux_plugins_steady_state_is_noop() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home"
  seed_pinned_tmux_plugin_repos "$workdir"
  {
    printf 'set -g mouse on\n\n'
    expected_tmux_plugins_block "$workdir/opt/tmux-plugins"
  } > "$workdir/home/.tmux.conf"
  cp "$workdir/home/.tmux.conf" "$workdir/tmux.conf.orig"

  run_tmux_plugins_step "$workdir"

  if grep -Eq 'git (init|-C [^ ]+ (fetch|checkout|remote))' "$workdir/git.log"; then
    cat "$workdir/git.log" >&2
    fail "pinned repos should not be re-fetched or re-initialized"
  fi
  cmp -s "$workdir/home/.tmux.conf" "$workdir/tmux.conf.orig" \
    || fail "a current managed block should leave tmux.conf byte-identical"
  [ ! -f "$workdir/tmux-reload.log" ] \
    || fail "steady state should not reload the running tmux server"
}

test_tmux_plugins_rewrites_drifted_block_and_reloads_running_server() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home"
  seed_pinned_tmux_plugin_repos "$workdir"
  {
    printf 'set -g mouse on\n\n'
    printf '# >>> devbox-managed: tmux plugins >>>\n'
    printf 'run-shell /stale/path/resurrect.tmux\n'
    printf '# <<< devbox-managed: tmux plugins <<<\n'
    printf 'set -g history-limit 9000\n'
  } > "$workdir/home/.tmux.conf"
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$workdir/tmux-socket"

  run_tmux_plugins_step "$workdir"

  grep -qF 'set -g mouse on' "$workdir/home/.tmux.conf" \
    || fail "user content before the block was lost"
  grep -qF 'set -g history-limit 9000' "$workdir/home/.tmux.conf" \
    || fail "user content after the old block was lost"
  ! grep -qF '/stale/path/resurrect.tmux' "$workdir/home/.tmux.conf" \
    || fail "drifted block content survived the rewrite"
  tail -n 6 "$workdir/home/.tmux.conf" \
    | diff - <(expected_tmux_plugins_block "$workdir/opt/tmux-plugins") >/dev/null \
    || fail "rewritten managed block did not land verbatim at the end"
  [ "$(grep -cF '>>> devbox-managed: tmux plugins >>>' "$workdir/home/.tmux.conf")" -eq 1 ] \
    || fail "managed block should appear exactly once after the rewrite"
  grep -qF "reload -u $test_user -H $workdir/fake-bin/tmux source-file $workdir/home/.tmux.conf" \
    "$workdir/tmux-reload.log" \
    || fail "running tmux server was not reloaded through the dev-user boundary"
}

test_tmux_plugins_skips_block_when_conf_missing() {
  local workdir out
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home"

  out="$(run_tmux_plugins_step "$workdir")"

  grep -qF "fetch -q --depth 1 origin 1111111111111111111111111111111111111111" "$workdir/git.log" \
    || fail "plugins should still be cloned when tmux.conf is missing"
  [ ! -e "$workdir/home/.tmux.conf" ] \
    || fail "the concern must not create tmux.conf; bootstrap owns the baseline"
  grep -qF "missing" <<<"$out" \
    || fail "missing tmux.conf should be reported"
}

test_tmux_plugins_fetch_failure_fails_and_leaves_conf_alone() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home"
  printf 'set -g mouse on\n' > "$workdir/home/.tmux.conf"

  if DEVBOX_TEST_GIT_FETCH_FAIL=1 run_tmux_plugins_step "$workdir" 2>/dev/null; then
    fail "a failed plugin fetch unexpectedly succeeded"
  fi
  ! grep -qF 'devbox-managed: tmux plugins' "$workdir/home/.tmux.conf" \
    || fail "the block must not be appended when the plugin clones are unverified"
}

extract_claude_contract() {
  local out="$1"
  {
    sed -n '/^claude_contract_version()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^claude_record_success()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
  } > "$out"
  grep -q '^claude_contract_version()' "$out" \
    || fail "could not extract claude_contract_version"
  grep -q '^claude_record_success()' "$out" \
    || fail "could not extract claude_record_success"
}

# Runs a single contract-helper call. DEV_USER defaults to the *test* user so
# the ownership clause is checkable without root, and the fake sudo passes the
# --version probe straight through. DEV_USER_OVERRIDE lets a test deliberately
# claim a different owner.
run_claude_contract() {
  local workdir="$1"
  local function_file="$workdir/claude-contract.sh"

  extract_claude_contract "$function_file"
  DEV_USER="${DEV_USER_OVERRIDE:-$(id -un)}" \
    DEV_HOME="$workdir/home" \
    CLAUDE_BIN="$workdir/home/.local/bin/claude" \
    CLAUDE_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/claude-code-required" \
    CLAUDE_SUCCESS_FILE="$workdir/var/lib/devbox-runtime/claude-code-installed" \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; claude_contract_version' _ "$function_file"
}

# Writes a stub claude at $1 whose --version behaviour is chosen by $2:
#   ok      -> exits 0, prints a current version
#   minimum -> exits 0, prints the minimum Fable 5.1-compatible version
#   old     -> exits 0, prints the version immediately below the minimum
#   empty   -> exits 0, prints nothing
#   fail    -> exits 3
make_stub_claude() {
  local path="$1" mode="$2"
  mkdir -p "$(dirname "$path")"
  case "$mode" in
    ok)      printf '#!/bin/sh\nprintf "2.9.9 (Claude Code)\\n"\n' > "$path" ;;
    minimum) printf '#!/bin/sh\nprintf "2.1.255 (Claude Code)\\n"\n' > "$path" ;;
    old)     printf '#!/bin/sh\nprintf "2.1.254 (Claude Code)\\n"\n' > "$path" ;;
    empty)   printf '#!/bin/sh\nexit 0\n' > "$path" ;;
    fail)    printf '#!/bin/sh\nexit 3\n' > "$path" ;;
    *)     fail "unknown stub mode: $mode" ;;
  esac
  chmod 0755 "$path"
}

test_claude_contract_accepts_a_good_binary() {
  local workdir out
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" ok

  out="$(run_claude_contract "$workdir")" || fail "contract rejected a good binary"
  [ "$out" = "2.9.9 (Claude Code)" ] \
    || fail "contract did not print the version: $out"
}

test_claude_contract_accepts_the_fable_5_1_minimum_version() {
  local workdir out
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" minimum

  out="$(run_claude_contract "$workdir")" \
    || fail "contract rejected the minimum Fable 5.1-compatible Claude Code"
  [ "$out" = "2.1.255 (Claude Code)" ] \
    || fail "contract did not print the minimum compatible version: $out"
}

test_claude_contract_rejects_a_pre_fable_5_1_version() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" old

  if run_claude_contract "$workdir" >/dev/null 2>&1; then
    fail "contract accepted Claude Code older than Fable 5.1 requires"
  fi
}

test_claude_contract_rejects_a_directory() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  mkdir -p "$workdir/home/.local/bin/claude"

  if run_claude_contract "$workdir" >/dev/null 2>&1; then
    fail "contract accepted a directory at the claude path"
  fi
}

test_claude_contract_rejects_non_executable() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" ok
  chmod 0644 "$workdir/home/.local/bin/claude"

  if run_claude_contract "$workdir" >/dev/null 2>&1; then
    fail "contract accepted a non-executable claude"
  fi
}

test_claude_contract_rejects_wrong_owner() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" ok

  # Claim an owner the file is NOT owned by.
  if DEV_USER_OVERRIDE=nobody run_claude_contract "$workdir" >/dev/null 2>&1; then
    fail "contract accepted a claude owned by another user"
  fi
}

test_claude_contract_rejects_nonzero_version() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" fail

  if run_claude_contract "$workdir" >/dev/null 2>&1; then
    fail "contract accepted a claude whose --version exits non-zero"
  fi
}

# The clause an exit-status-only implementation silently fails.
test_claude_contract_rejects_empty_version() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" empty

  if run_claude_contract "$workdir" >/dev/null 2>&1; then
    fail "contract accepted a claude that exits 0 but prints no version"
  fi
}

test_claude_contract_rejects_missing_binary() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"

  if run_claude_contract "$workdir" >/dev/null 2>&1; then
    fail "contract accepted a missing claude"
  fi
}

extract_claude_step() {
  local out="$1"
  {
    sed -n '/^claude_contract_version()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^claude_record_success()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^remove_legacy_claude_installs()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
    sed -n '/^ensure_claude_code()/,/^}/p' "$repo_root/scripts/devbox-toolchain"
  } > "$out"
  grep -q '^ensure_claude_code()' "$out" || fail "could not extract ensure_claude_code"
  grep -q '^}' "$out" || fail "extracted ensure_claude_code is truncated"
}

# Fake https://claude.ai/install.sh. Logs the target it was given, then either
# fails or writes a working stub claude at CLAUDE_BIN.
make_fake_claude_installer() {
  local out="$1"
  cat > "$out" <<'EOF'
#!/bin/sh
set -eu
printf 'claude-install target=%s home=%s\n' "${1:-unset}" "${HOME:-unset}" \
  >> "$DEVBOX_TEST_LOG"
if [ "${DEVBOX_TEST_CLAUDE_INSTALL_FAIL:-0}" = 1 ]; then
  exit 42
fi
mkdir -p "$(dirname "$DEVBOX_TEST_CLAUDE_TARGET_BIN")"
cat > "$DEVBOX_TEST_CLAUDE_TARGET_BIN" <<'CLAUDE_EOF'
#!/bin/sh
printf '2.9.9 (Claude Code)\n'
CLAUDE_EOF
chmod 0755 "$DEVBOX_TEST_CLAUDE_TARGET_BIN"
EOF
}

# Workdir-scoped paths for the success marker and the two retired Claude
# installs, shared between run_claude_step (drives ensure_claude_code, which
# reaches the cleanup only after a fresh marker write) and run_claude_cleanup
# (calls remove_legacy_claude_installs directly, the only way to exercise it
# with the marker absent). Populates the caller's local `claude_legacy_env`
# array so both runners point remove_legacy_claude_installs at the same
# fixtures without duplicating the four assignments.
claude_legacy_env_vars() {
  local workdir="$1"
  claude_legacy_env=(
    "CLAUDE_SUCCESS_FILE=$workdir/var/lib/devbox-runtime/claude-code-installed"
    "CLAUDE_OLD_SYSTEM_BIN=$workdir/usr/bin/claude"
    "CLAUDE_OLD_NPM_DIR=$workdir/npm/@anthropic-ai/claude-code"
    "CLAUDE_NVM_ROOT=$workdir/home/.nvm/versions/node"
  )
}

run_claude_step() {
  local workdir="$1"
  local function_file="$workdir/ensure-claude.sh"
  local -a claude_legacy_env
  claude_legacy_env_vars "$workdir"

  mkdir -p "$workdir/home"
  extract_claude_step "$function_file"
  make_fake_claude_installer "$workdir/claude-install.sh"
  env \
    DEVBOX_TEST_LOG="$workdir/install.log" \
    DEVBOX_TEST_CODEX_INSTALLER_SOURCE="$workdir/claude-install.sh" \
    DEVBOX_TEST_CODEX_DOWNLOAD_LOG="$workdir/download.log" \
    DEVBOX_TEST_CODEX_DOWNLOAD_FAIL="${DEVBOX_TEST_CLAUDE_DOWNLOAD_FAIL:-0}" \
    DEVBOX_TEST_CLAUDE_INSTALL_FAIL="${DEVBOX_TEST_CLAUDE_INSTALL_FAIL:-0}" \
    DEVBOX_TEST_CLAUDE_TARGET_BIN="$workdir/home/.local/bin/claude" \
    DEV_USER="$(id -un)" \
    DEV_HOME="$workdir/home" \
    CLAUDE_BIN="$workdir/home/.local/bin/claude" \
    CLAUDE_INSTALLER_URL=https://claude.ai/install.sh \
    CLAUDE_INSTALL_TARGET=latest \
    CLAUDE_REQUIRED_FILE="$workdir/var/lib/devbox-runtime/claude-code-required" \
    "${claude_legacy_env[@]}" \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; ensure_claude_code' _ "$function_file"
}

# Calls remove_legacy_claude_installs directly, bypassing ensure_claude_code
# entirely. This is the only way to drive the cleanup with the success marker
# absent -- both of ensure_claude_code's call sites run right after
# claude_record_success has just written it.
run_claude_cleanup() {
  local workdir="$1"
  local function_file="$workdir/ensure-claude.sh"
  local -a claude_legacy_env
  claude_legacy_env_vars "$workdir"

  mkdir -p "$workdir/home"
  extract_claude_step "$function_file"
  env \
    "${claude_legacy_env[@]}" \
    PATH="$workdir/fake-bin:$PATH" \
    bash -c 'set -euo pipefail; source "$1"; remove_legacy_claude_installs' _ "$function_file"
}

test_claude_installs_when_absent() {
  local workdir marker
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  marker="$workdir/var/lib/devbox-runtime/claude-code-installed"

  run_claude_step "$workdir" >/dev/null || fail "install failed"

  grep -qF 'claude-install target=latest' "$workdir/install.log" \
    || fail "installer was not run with target latest"
  grep -qF "home=$workdir/home" "$workdir/install.log" \
    || fail "installer did not run with the dev HOME"
  [ -f "$marker" ] || fail "success marker was not written"
  grep -qF '2.9.9 (Claude Code)' "$marker" \
    || fail "marker does not record the resolved version"
}

test_claude_second_run_is_a_noop() {
  local workdir marker
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  marker="$workdir/var/lib/devbox-runtime/claude-code-installed"

  run_claude_step "$workdir" >/dev/null || fail "first install failed"
  : > "$workdir/install.log"
  : > "$workdir/download.log"
  touch -d '2020-01-01T00:00:00Z' "$marker"
  run_claude_step "$workdir" >/dev/null || fail "second run failed"

  [ ! -s "$workdir/install.log" ] || fail "second run re-ran the installer"
  [ ! -s "$workdir/download.log" ] || fail "second run re-downloaded the installer"
  [ "$(date -u -d "@$(stat -c %Y "$marker")" +%Y)" = 2020 ] \
    || fail "second run rewrote an already-current marker"
}

# Regression test: claude_record_success compares the marker's first line
# against ${version%% *}. `cut -d' ' -f1` alone emits one field PER LINE, so
# a multi-line --version string (Claude Code prints one line today, but this
# is defensive) makes the comparison never match, rewriting the marker on
# every 8-hourly converge and destroying the fleet's only drift trail.
test_claude_record_success_is_stable_across_a_multiline_version() {
  local workdir marker
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  marker="$workdir/var/lib/devbox-runtime/claude-code-installed"

  mkdir -p "$workdir/home/.local/bin"
  printf '#!/bin/sh\nprintf "2.9.9 (Claude Code)\\nNode.js v20.11.0\\n"\n' \
    > "$workdir/home/.local/bin/claude"
  chmod 0755 "$workdir/home/.local/bin/claude"

  run_claude_step "$workdir" >/dev/null || fail "first run failed"
  [ -f "$marker" ] || fail "precondition: marker should exist"
  touch -d '2020-01-01T00:00:00Z' "$marker"

  run_claude_step "$workdir" >/dev/null || fail "second run failed"
  [ "$(date -u -d "@$(stat -c %Y "$marker")" +%Y)" = 2020 ] \
    || fail "marker was rewritten even though the multi-line version did not change"
}

# The regression case for the marker-lifecycle fix: a stale marker must never
# outlive the condition it attests.
test_claude_stale_marker_is_removed_before_failed_repair() {
  local workdir marker
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  marker="$workdir/var/lib/devbox-runtime/claude-code-installed"

  run_claude_step "$workdir" >/dev/null || fail "first install failed"
  [ -f "$marker" ] || fail "precondition: marker should exist"

  # Break the binary, then make the repair install fail.
  make_stub_claude "$workdir/home/.local/bin/claude" fail
  if DEVBOX_TEST_CLAUDE_INSTALL_FAIL=1 run_claude_step "$workdir" >/dev/null 2>&1; then
    fail "ensure_claude_code succeeded despite a failing repair"
  fi
  [ ! -f "$marker" ] \
    || fail "stale marker survived a failed repair over a broken binary"
}

test_claude_successful_repair_recreates_the_marker() {
  local workdir marker
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  marker="$workdir/var/lib/devbox-runtime/claude-code-installed"

  run_claude_step "$workdir" >/dev/null || fail "first install failed"
  make_stub_claude "$workdir/home/.local/bin/claude" empty

  run_claude_step "$workdir" >/dev/null || fail "repair failed"
  [ -f "$marker" ] || fail "successful repair did not recreate the marker"
}

test_claude_download_failure_leaves_no_marker() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"

  if DEVBOX_TEST_CLAUDE_DOWNLOAD_FAIL=1 run_claude_step "$workdir" >/dev/null 2>&1; then
    fail "ensure_claude_code succeeded despite a failed installer download"
  fi
  [ ! -f "$workdir/var/lib/devbox-runtime/claude-code-installed" ] \
    || fail "marker written despite a failed download"
}

# Regression test for narrowing the no-claude window: $CLAUDE_BIN must not be
# removed until AFTER we know a replacement can be fetched. Seed a binary
# that fails the contract (as a dangling post-GC symlink would), force the
# installer download to fail, and assert the pre-existing file is still
# there -- a box must never end up with no `claude` at all just because the
# disk or network hiccuped.
test_claude_download_failure_preserves_existing_binary() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  make_stub_claude "$workdir/home/.local/bin/claude" fail

  if DEVBOX_TEST_CLAUDE_DOWNLOAD_FAIL=1 run_claude_step "$workdir" >/dev/null 2>&1; then
    fail "ensure_claude_code succeeded despite a failed installer download"
  fi
  [ ! -f "$workdir/var/lib/devbox-runtime/claude-code-installed" ] \
    || fail "marker written despite a failed download"
  [ -e "$workdir/home/.local/bin/claude" ] \
    || fail "pre-existing claude binary was removed before a replacement was known to be fetchable"
}

seed_legacy_claude_installs() {
  local workdir="$1"
  mkdir -p "$workdir/usr/bin" \
    "$workdir/npm/@anthropic-ai/claude-code" \
    "$workdir/home/.nvm/versions/node/v22.22.2/lib/node_modules/@anthropic-ai/claude-code"
  : > "$workdir/npm/@anthropic-ai/claude-code/package.json"
  : > "$workdir/home/.nvm/versions/node/v22.22.2/lib/node_modules/@anthropic-ai/claude-code/package.json"
  ln -sf ../npm/@anthropic-ai/claude-code/bin/claude.exe "$workdir/usr/bin/claude"
}

test_claude_cleanup_removes_both_legacy_installs() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  seed_legacy_claude_installs "$workdir"

  run_claude_step "$workdir" >/dev/null || fail "install failed"

  [ ! -e "$workdir/npm/@anthropic-ai/claude-code" ] \
    || fail "root-owned npm-global install survived"
  [ ! -L "$workdir/usr/bin/claude" ] || fail "/usr/bin/claude symlink survived"
  [ ! -e "$workdir/home/.nvm/versions/node/v22.22.2/lib/node_modules/@anthropic-ai/claude-code" ] \
    || fail "nvm-global install survived"
}

test_claude_cleanup_keeps_fallbacks_when_contract_fails() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  seed_legacy_claude_installs "$workdir"

  if DEVBOX_TEST_CLAUDE_INSTALL_FAIL=1 run_claude_step "$workdir" >/dev/null 2>&1; then
    fail "ensure_claude_code succeeded despite a failing installer"
  fi

  [ -d "$workdir/npm/@anthropic-ai/claude-code" ] \
    || fail "npm-global install was deleted despite a failed install"
  [ -d "$workdir/home/.nvm/versions/node/v22.22.2/lib/node_modules/@anthropic-ai/claude-code" ] \
    || fail "nvm-global install was deleted despite a failed install"
}

# The guard is unreachable through ensure_claude_code: both of its call sites
# run after claude_record_success has already written the marker. Calling the
# cleanup directly is the only way to cover the fail-safe that keeps a box with
# a broken native claude on its nvm fallback.
test_claude_cleanup_without_the_marker_is_a_noop() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"
  seed_legacy_claude_installs "$workdir"
  # deliberately no marker

  run_claude_cleanup "$workdir" >/dev/null \
    || fail "cleanup returned non-zero with no marker; run_tool would report a failed concern"

  [ -d "$workdir/npm/@anthropic-ai/claude-code" ] || fail "npm-global install was deleted with no marker"
  [ -L "$workdir/usr/bin/claude" ] || fail "/usr/bin/claude symlink was deleted with no marker"
  [ -d "$workdir/home/.nvm/versions/node/v22.22.2/lib/node_modules/@anthropic-ai/claude-code" ] \
    || fail "nvm-global install was deleted with no marker"
}

test_codex_connectors_file() {
  local work; work="$(mktemp -d)"; trap 'rm -rf "$work"' RETURN
  # Extract ensure_codex_connectors_file for standalone execution.
  awk '/^ensure_codex_connectors_file\(\)/,/^}$/' "$repo_root/scripts/devbox-toolchain" > "$work/fn.sh"
  [ -s "$work/fn.sh" ] || fail "ensure_codex_connectors_file not found in devbox-toolchain"

  # Non-empty JSON: file written 0644 with exact payload.
  ( set -e
    source "$work/fn.sh"
    DEVBOX_CONNECTORS_FILE="$work/connectors.json" \
    DEVBOX_CODEX_MCP_CONNECTORS='{"tracker":{"url":"https://mcp.tracker.example/mcp","http_headers":{}}}' \
      ensure_codex_connectors_file
  ) || fail "connectors write failed"
  [ "$(cat "$work/connectors.json")" = '{"tracker":{"url":"https://mcp.tracker.example/mcp","http_headers":{}}}' ] \
    || fail "connectors payload mismatch"
  [ "$(stat -c %a "$work/connectors.json")" = 644 ] || fail "connectors file must be world-readable 0644"

  # Empty / absent env: file removed.
  ( source "$work/fn.sh"
    DEVBOX_CONNECTORS_FILE="$work/connectors.json" DEVBOX_CODEX_MCP_CONNECTORS='{}' \
      ensure_codex_connectors_file ) || fail "empty-map run failed"
  [ ! -e "$work/connectors.json" ] || fail "empty map must remove the file"

  # Invalid JSON: fails, leaves no file.
  ( source "$work/fn.sh"
    DEVBOX_CONNECTORS_FILE="$work/connectors.json" DEVBOX_CODEX_MCP_CONNECTORS='not-json' \
      ensure_codex_connectors_file ) && fail "invalid JSON must fail" || true
  [ ! -e "$work/connectors.json" ] || fail "invalid JSON must not write a file"

  echo "PASS codex connectors file"
}

# The pins only defend the fetches if a manifest that lacks them cannot
# converge at all: require_env must fail closed, before any tool runs.
test_require_env_fails_closed_without_the_pin_env() {
  local out workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  make_fake_bin "$workdir/fake-bin"

  if out="$(env -i PATH="$workdir/fake-bin:/usr/bin:/bin" \
      bash "$repo_root/scripts/devbox-toolchain" 2>&1)"; then
    fail "devbox-toolchain ran without its required pin environment"
  fi
  grep -q 'missing required toolchain environment variables' <<<"$out" \
    || fail "empty environment did not fail closed in require_env"
  local name
  for name in \
      DEVBOX_PASEO_CLI_VERSION \
      DEVBOX_PASEO_CLI_TARBALL_SHA256; do
    grep -q "$name" <<<"$out" || fail "require_env does not require $name"
  done
}

test_needrestart_defers_paseo_before_package_work() {
  local function_file protect_line tools_line workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  function_file="$workdir/ensure-needrestart.sh"

  awk '/^ensure_needrestart_paseo_protection\(\)/,/^}$/' \
    "$repo_root/scripts/devbox-toolchain" > "$function_file"
  [ -s "$function_file" ] || fail "ensure_needrestart_paseo_protection not found"

  NEEDRESTART_PASEO_CONFIG_FILE="$workdir/etc/needrestart/conf.d/99-devbox-paseo.conf" \
    bash -c 'set -euo pipefail; source "$1"; ensure_needrestart_paseo_protection' \
      _ "$function_file"

  grep -qxF '$nrconf{override_rc}{qr(^paseo\.service$)} = 0;' \
    "$workdir/etc/needrestart/conf.d/99-devbox-paseo.conf" \
    || fail "needrestart config does not defer paseo.service"

  protect_line="$(grep -n '^ensure_needrestart_paseo_protection$' \
    "$repo_root/scripts/devbox-toolchain" | cut -d: -f1)"
  tools_line="$(grep -n '^run_tool base-tools ' \
    "$repo_root/scripts/devbox-toolchain" | cut -d: -f1)"
  [ -n "$protect_line" ] && [ "$protect_line" -lt "$tools_line" ] \
    || fail "Paseo protection is not installed before package convergence"
}

test_require_env_fails_closed_without_the_pin_env
test_needrestart_defers_paseo_before_package_work
test_paseo_new_gcp_bootstrap_installs_pinned_tarball_and_writes_tailnet_config
test_paseo_tarball_download_failure_retains_retry_marker
test_paseo_tarball_sha_mismatch_retains_retry_marker
test_paseo_pinned_version_mismatch_retains_retry_marker
test_paseo_success_reconciles_boot_enabled_daemon
test_paseo_daemon_runner_preserves_then_takes_over_detached_daemon
test_paseo_daemon_reload_failure_is_retryable
test_paseo_success_marker_leaves_preinstalled_box_alone
test_paseo_existing_gcp_reconciles_daemon_without_reinstall_and_aws_skips
test_paseo_failure_marker_retries_after_bootstrap
test_paseo_tailscale_failure_retains_retry_marker
test_paseo_verification_failure_retains_retry_marker
test_paseo_invalid_existing_config_retains_retry_marker
test_paseo_merge_preserves_unmanaged_settings_and_success_is_noop
test_paseo_atomic_state_failure_retains_retry_marker
test_codex_new_gcp_bootstrap_and_post_success_noop
test_codex_skips_existing_gcp_and_aws
test_codex_failure_marker_retries_after_bootstrap
test_codex_chmod_failure_keeps_marker_and_cleans_installer
test_codex_success_tombstone_prevents_rearm
test_codex_download_failure_keeps_marker_and_cleans_installer
test_codex_verification_failure_keeps_marker_and_cleans_installer
test_codex_atomic_state_move_failure_retains_retry
test_codex_success_dominates_stale_retry_marker
test_codex_replacement_root_is_eligible_again
test_codex_connectors_file
test_vscode_new_gcp_bootstrap_and_post_success_noop
test_vscode_skips_existing_gcp_and_aws
test_vscode_failure_marker_retries_after_bootstrap
test_vscode_launcher_install_failure_keeps_marker_and_cleans_tmp
test_vscode_success_marker_repairs_missing_launcher
test_vscode_launcher_stops_when_tailscale_serve_fails
test_agent_plugins_new_gcp_bootstrap_and_post_success_noop
test_agent_plugins_defers_codex_until_login_without_failing
test_agent_plugins_skip_existing_gcp_and_aws
test_agent_plugins_wait_for_codex_and_retry_after_bootstrap
test_agent_plugins_wait_for_claude
test_agent_plugins_ignores_a_present_but_unverified_claude
test_tmux_plugins_clones_pins_and_appends_block
test_tmux_plugins_steady_state_is_noop
test_tmux_plugins_rewrites_drifted_block_and_reloads_running_server
test_tmux_plugins_skips_block_when_conf_missing
test_tmux_plugins_fetch_failure_fails_and_leaves_conf_alone
test_matching_versions_are_noop
test_containerd_migration
test_claude_contract_accepts_a_good_binary
test_claude_contract_accepts_the_fable_5_1_minimum_version
test_claude_contract_rejects_a_pre_fable_5_1_version
test_claude_contract_rejects_a_directory
test_claude_contract_rejects_non_executable
test_claude_contract_rejects_wrong_owner
test_claude_contract_rejects_nonzero_version
test_claude_contract_rejects_empty_version
test_claude_contract_rejects_missing_binary
test_claude_installs_when_absent
test_claude_second_run_is_a_noop
test_claude_record_success_is_stable_across_a_multiline_version
test_claude_stale_marker_is_removed_before_failed_repair
test_claude_successful_repair_recreates_the_marker
test_claude_download_failure_leaves_no_marker
test_claude_download_failure_preserves_existing_binary
test_claude_cleanup_removes_both_legacy_installs
test_claude_cleanup_keeps_fallbacks_when_contract_fails
test_claude_cleanup_without_the_marker_is_a_noop

echo "devbox-toolchain tests passed"
