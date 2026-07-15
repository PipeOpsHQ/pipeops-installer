#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TEST_UNAME="${TEST_UNAME:-Linux}"
uname() {
  if [[ "${1:-}" == "-s" ]]; then
    printf '%s\n' "$TEST_UNAME"
    return 0
  fi

  command uname "$@"
}

export IGRIS_INSTALLER_SKIP_MAIN=1
# shellcheck source=igris.sh
source "${REPO_ROOT}/igris.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local want="$1"
  local got="$2"
  local label="$3"

  [[ "$got" == "$want" ]] || fail "${label}: got '${got}', want '${want}'"
}

assert_contains_line() {
  local haystack="$1"
  local needle="$2"
  local label="$3"

  grep -Fxq "$needle" <<< "$haystack" || fail "${label}: missing '${needle}'"
}

assert_should_install() {
  local label="$1"
  shift

  # shellcheck disable=SC2016 # $1 is intentionally expanded by the child bash.
  if ! env "$@" bash -c 'source "$1"; should_install_bundled_vortex' bash "${REPO_ROOT}/igris.sh"; then
    fail "${label}: expected Vortex bundle install"
  fi
}

assert_should_not_install() {
  local label="$1"
  shift

  # shellcheck disable=SC2016 # $1 is intentionally expanded by the child bash.
  if env "$@" bash -c 'source "$1"; should_install_bundled_vortex' bash "${REPO_ROOT}/igris.sh"; then
    fail "${label}: expected Vortex bundle skip"
  fi
}


test_skips_vortex_by_default_for_linux_host_bootstrap() {
  assert_should_not_install \
    "linux host bootstrap skips bundled Vortex by default" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=host
}

test_installs_vortex_when_explicitly_enabled() {
  assert_should_install \
    "explicit opt-in installs bundled Vortex" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=host \
    INSTALL_VORTEX=true
}

test_installs_vortex_standalone_mode() {
  assert_should_install \
    "standalone opt-in installs bundled Vortex" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=host \
    INSTALL_VORTEX=standalone
}

test_resolve_vortex_bundle_mode() {
  assert_eq "none" "$(resolve_vortex_bundle_mode)" "bundle mode defaults to none"
  assert_eq "none" "$(INSTALL_VORTEX=false resolve_vortex_bundle_mode)" "false maps to none"
  assert_eq "none" "$(INSTALL_VORTEX=auto resolve_vortex_bundle_mode)" "legacy auto maps to none"
  assert_eq "unified" "$(INSTALL_VORTEX=true resolve_vortex_bundle_mode)" "true maps to unified"
  assert_eq "unified" "$(INSTALL_VORTEX=unified resolve_vortex_bundle_mode)" "unified maps to unified"
  assert_eq "unified" "$(IGRIS_INSTALL_VORTEX=yes resolve_vortex_bundle_mode)" "yes alias maps to unified"
  assert_eq "standalone" "$(INSTALL_VORTEX=standalone resolve_vortex_bundle_mode)" "standalone maps to standalone"
  assert_eq "standalone" "$(INSTALL_VORTEX=STANDALONE resolve_vortex_bundle_mode)" "standalone is case-insensitive"
  assert_eq "unsupported" "$(INSTALL_VORTEX=maybe resolve_vortex_bundle_mode)" "unknown maps to unsupported"
}

test_skips_vortex_for_non_host_modes() {
  assert_should_not_install \
    "kubernetes bootstrap skips bundled Vortex" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=daemonset
}

test_skips_vortex_when_disabled() {
  assert_should_not_install \
    "explicit opt-out skips bundled Vortex" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=host \
    INSTALL_VORTEX=false
}

test_skips_vortex_for_legacy_auto_setting() {
  assert_should_not_install \
    "legacy auto setting skips bundled Vortex" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=host \
    INSTALL_VORTEX=auto
}

test_skips_vortex_for_unsupported_setting() {
  assert_should_not_install \
    "unsupported install setting skips bundled Vortex" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=host \
    INSTALL_VORTEX=maybe
}

test_skips_standalone_vortex_without_workspace() {
  assert_should_not_install \
    "workspace is required for standalone Vortex enrollment" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    MODE=host \
    INSTALL_VORTEX=standalone
}

test_unified_vortex_does_not_require_workspace() {
  assert_should_install \
    "unified Vortex needs no workspace (no enrollment of its own)" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    MODE=host \
    INSTALL_VORTEX=true
}

test_skips_unified_vortex_on_non_linux() {
  assert_should_not_install \
    "unified Vortex bundle is Linux-only" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Darwin \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    MODE=host \
    INSTALL_VORTEX=true
}

test_builds_vortex_env_from_igris_context() {
  local lines

  lines="$(
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    TENANT_ID=tenant-1 \
    ORG_ID=org-1 \
    VORTEX_IFACE=eth1 \
    VORTEX_CAPTURE_BACKEND=pcap \
    VORTEX_IPS_MODE=true \
    VORTEX_METRICS_PORT=19090 \
    GITHUB_TOKEN=ambient-github-token \
    GH_TOKEN=ambient-gh-token \
    build_vortex_env_lines
  )"

  assert_contains_line "$lines" "VORTEX_GATEWAY_URL=https://gateway.example.com" "gateway env"
  assert_contains_line "$lines" "VORTEX_BOOTSTRAP_TOKEN=hsk_test" "token env"
  assert_contains_line "$lines" "VORTEX_WORKSPACE_ID=workspace-1" "workspace env"
  assert_contains_line "$lines" "VORTEX_TENANT_ID=tenant-1" "tenant env"
  assert_contains_line "$lines" "VORTEX_ORG_ID=org-1" "org env"
  assert_contains_line "$lines" "VORTEX_IFACE=eth1" "iface env"
  assert_contains_line "$lines" "VORTEX_CAPTURE_BACKEND=pcap" "capture backend env"
  assert_contains_line "$lines" "VORTEX_IPS_MODE=true" "ips mode env"
  assert_contains_line "$lines" "VORTEX_METRICS_PORT=19090" "metrics env"
  assert_contains_line "$lines" "VORTEX_INSTALL_SERVICE=true" "service env"
  if grep -Eq '^(GITHUB_TOKEN|GH_TOKEN)=' <<< "$lines"; then
    fail "ambient GitHub tokens should not be forwarded to bundled installer"
  fi
}

test_vortex_installer_host_allowlist() {
  local run

  run="$(cat <<'SH'
#!/usr/bin/env bash
source "$1"

if ! vortex_installer_host_allowed "https://get.pipeops.dev/vortex.sh"; then
  exit 1
fi

if ! vortex_installer_host_allowed "https://127.0.0.1/vortex.sh"; then
  exit 1
fi

vortex_installer_host_allowed "https://malicious.example.com/vortex.sh"
SH
)"

if env VORTEX_INSTALLER_ALLOWED_HOSTS="get.pipeops.dev,127.0.0.1" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    bash -c "$run" ignored "$REPO_ROOT/igris.sh"; then
  fail "vortex installer host allowlist: rejected unknown host"
fi

  return 0
}

test_vortex_installer_security_gate_checks() {
  local run

  run="$(cat <<'SH'
#!/usr/bin/env bash
source "$1"

if run_vortex_installer "https://malicious.example.com/vortex.sh"; then
  exit 1
fi

if run_vortex_installer "http://get.pipeops.dev/vortex.sh"; then
  exit 1
fi
SH
)"

if ! env VORTEX_INSTALLER_ALLOWED_HOSTS="get.pipeops.dev" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    bash -c "$run" ignored "$REPO_ROOT/igris.sh"; then
  fail "vortex installer security gate checks: disallowed URLs should be rejected"
fi

  return 0
}

test_vortex_installer_checksum_validation() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  printf 'trusted contents' > "$tmp/vortex.sh"
  if (VORTEX_INSTALLER_SHA256="" verify_vortex_installer_checksum "$tmp/vortex.sh" "" >/dev/null 2>&1); then
    fail "missing checksum should fail closed"
  fi

  VORTEX_INSTALLER_SHA256="$(calculate_sha256 "$tmp/vortex.sh")" \
    verify_vortex_installer_checksum "$tmp/vortex.sh" || fail "matching checksum should pass"

  if (VORTEX_INSTALLER_SHA256="deadbeef" verify_vortex_installer_checksum "$tmp/vortex.sh" >/dev/null 2>&1); then
    fail "mismatched checksum should fail"
  fi

  if [[ -z "$(vortex_installer_expected_sha256 "https://get.pipeops.dev/vortex.sh")" ]]; then
    fail "default Vortex installer URL should have a pinned checksum"
  fi
}

test_builds_binary_only_env_for_unified_bundle() {
  local lines

  lines="$(
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    VORTEX_INSTALL_DIR=/opt/aeon/bin \
    VORTEX_VERSION=1.2.3 \
    build_vortex_binary_only_env_lines
  )"

  assert_contains_line "$lines" "VORTEX_BINARY_ONLY=true" "binary-only env"
  assert_contains_line "$lines" "VORTEX_INSTALL_SERVICE=false" "no-service env"
  assert_contains_line "$lines" "VORTEX_INSTALL_DIR=/opt/aeon/bin" "install dir env"
  assert_contains_line "$lines" "VORTEX_VERSION=1.2.3" "version env"
  if grep -Eq '^VORTEX_(GATEWAY_URL|BOOTSTRAP_TOKEN|WORKSPACE_ID|TENANT_ID|ORG_ID)=' <<< "$lines"; then
    fail "unified bundle must not forward enrollment env to the vortex installer"
  fi
}

test_standalone_install_hook_invokes_vortex_installer() {
  local tmp contents
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  run_vortex_installer() {
    local installer_url="$1"
    shift

    {
      printf 'URL=%s\n' "$installer_url"
      printf '%s\n' "$@"
    } > "$tmp"
  }

  IGRIS_MANAGE_VORTEX_SUPERVISION="false"
  GATEWAY_URL=https://gateway.example.com \
  TOKEN=hsk_test \
  WORKSPACE_ID=workspace-1 \
  INSTALL_VORTEX=standalone \
  VORTEX_INSTALLER_URL=https://get.pipeops.dev/vortex.sh \
    install_bundled_vortex_if_needed >/dev/null

  contents="$(cat "$tmp")"
  assert_contains_line "$contents" "URL=https://get.pipeops.dev/vortex.sh" "installer url"
  assert_contains_line "$contents" "VORTEX_GATEWAY_URL=https://gateway.example.com" "installer gateway env"
  assert_contains_line "$contents" "VORTEX_BOOTSTRAP_TOKEN=hsk_test" "installer token env"
  assert_contains_line "$contents" "VORTEX_WORKSPACE_ID=workspace-1" "installer workspace env"
  assert_contains_line "$contents" "VORTEX_INSTALL_SERVICE=true" "installer service env"
  assert_eq "false" "$IGRIS_MANAGE_VORTEX_SUPERVISION" "standalone bundle must not enable igris supervision"

  unset -f run_vortex_installer
}

test_unified_install_hook_enables_igris_supervision() {
  local tmp contents
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  run_vortex_installer() {
    local installer_url="$1"
    shift

    {
      printf 'URL=%s\n' "$installer_url"
      printf '%s\n' "$@"
    } > "$tmp"
  }

  IGRIS_MANAGE_VORTEX_SUPERVISION="false"
  IGRIS_SUPERVISED_VORTEX_BINARY=""
  GATEWAY_URL=https://gateway.example.com \
  TOKEN=hsk_test \
  INSTALL_VORTEX=true \
  VORTEX_INSTALLER_URL=https://get.pipeops.dev/vortex.sh \
    install_bundled_vortex_if_needed >/dev/null

  contents="$(cat "$tmp")"
  assert_contains_line "$contents" "URL=https://get.pipeops.dev/vortex.sh" "installer url"
  assert_contains_line "$contents" "VORTEX_BINARY_ONLY=true" "binary-only env"
  assert_contains_line "$contents" "VORTEX_INSTALL_SERVICE=false" "no-service env"
  if grep -Eq '^VORTEX_(GATEWAY_URL|BOOTSTRAP_TOKEN|WORKSPACE_ID)=' <<< "$contents"; then
    fail "unified bundle must not hand enrollment credentials to the vortex installer"
  fi
  assert_eq "true" "$IGRIS_MANAGE_VORTEX_SUPERVISION" "unified bundle enables igris supervision"
  assert_eq "" "$IGRIS_SUPERVISED_VORTEX_BINARY" "default install dir needs no IGRIS_VORTEX_BINARY override"

  IGRIS_MANAGE_VORTEX_SUPERVISION="false"
  IGRIS_SUPERVISED_VORTEX_BINARY=""
  GATEWAY_URL=https://gateway.example.com \
  TOKEN=hsk_test \
  INSTALL_VORTEX=true \
  VORTEX_INSTALL_DIR=/opt/aeon/bin \
    install_bundled_vortex_if_needed >/dev/null
  assert_eq "/opt/aeon/bin/vortex" "$IGRIS_SUPERVISED_VORTEX_BINARY" "custom install dir records supervised binary path"

  IGRIS_MANAGE_VORTEX_SUPERVISION="false"
  IGRIS_SUPERVISED_VORTEX_BINARY=""
  unset -f run_vortex_installer
}

test_unified_failure_does_not_enable_supervision() {
  run_vortex_installer() {
    return 1
  }

  IGRIS_MANAGE_VORTEX_SUPERVISION="false"
  GATEWAY_URL=https://gateway.example.com \
  TOKEN=hsk_test \
  INSTALL_VORTEX=true \
    install_bundled_vortex_if_needed >/dev/null 2>&1

  assert_eq "false" "$IGRIS_MANAGE_VORTEX_SUPERVISION" "failed unified install must not enable supervision"

  unset -f run_vortex_installer
}

test_agent_env_file_carries_vortex_supervision() {
  local tmp contents
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  sudo() {
    "$@"
  }

  IGRIS_MANAGE_VORTEX_SUPERVISION="true"
  IGRIS_SUPERVISED_VORTEX_BINARY="/opt/aeon/bin/vortex"
  write_agent_env_file "$tmp/unified.env" "https://gateway.example.com" "hsk_test" "workspace-1" "" "" "host" >/dev/null
  contents="$(cat "$tmp/unified.env")"
  assert_contains_line "$contents" "IGRIS_MANAGE_VORTEX=true" "unified env file enables supervision"
  assert_contains_line "$contents" "IGRIS_VORTEX_BINARY=/opt/aeon/bin/vortex" "unified env file pins custom vortex binary"

  IGRIS_MANAGE_VORTEX_SUPERVISION="true"
  IGRIS_SUPERVISED_VORTEX_BINARY=""
  write_agent_env_file "$tmp/unified-default.env" "https://gateway.example.com" "hsk_test" "workspace-1" "" "" "host" >/dev/null
  contents="$(cat "$tmp/unified-default.env")"
  assert_contains_line "$contents" "IGRIS_MANAGE_VORTEX=true" "unified env file enables supervision (default binary)"
  if grep -q '^IGRIS_VORTEX_BINARY=' "$tmp/unified-default.env"; then
    fail "default vortex install dir must not write IGRIS_VORTEX_BINARY"
  fi

  IGRIS_MANAGE_VORTEX_SUPERVISION="false"
  IGRIS_SUPERVISED_VORTEX_BINARY=""
  write_agent_env_file "$tmp/plain.env" "https://gateway.example.com" "hsk_test" "workspace-1" "" "" "host" >/dev/null
  if grep -q 'IGRIS_MANAGE_VORTEX\|IGRIS_VORTEX_BINARY' "$tmp/plain.env"; then
    fail "supervision keys must not leak into env files without a unified bundle"
  fi

  unset -f sudo
}

test_skips_vortex_by_default_for_linux_host_bootstrap
test_installs_vortex_when_explicitly_enabled
test_installs_vortex_standalone_mode
test_resolve_vortex_bundle_mode
test_skips_vortex_for_non_host_modes
test_skips_vortex_when_disabled
test_skips_vortex_for_legacy_auto_setting
test_skips_vortex_for_unsupported_setting
test_skips_standalone_vortex_without_workspace
test_unified_vortex_does_not_require_workspace
test_skips_unified_vortex_on_non_linux
test_builds_vortex_env_from_igris_context
test_builds_binary_only_env_for_unified_bundle
test_vortex_installer_host_allowlist
test_vortex_installer_security_gate_checks
test_vortex_installer_checksum_validation
test_standalone_install_hook_invokes_vortex_installer
test_unified_install_hook_enables_igris_supervision
test_unified_failure_does_not_enable_supervision
test_agent_env_file_carries_vortex_supervision

echo "ok"
