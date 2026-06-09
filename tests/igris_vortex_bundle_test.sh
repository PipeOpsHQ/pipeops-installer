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


test_defaults_to_vortex_for_linux_host_bootstrap() {
  assert_should_install \
    "linux host bootstrap defaults on" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    WORKSPACE_ID=workspace-1 \
    MODE=host
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

test_skips_vortex_without_workspace() {
  assert_should_not_install \
    "workspace is required for Vortex enrollment" \
    IGRIS_INSTALLER_SKIP_MAIN=1 \
    IGRIS_TEST_OS=Linux \
    GATEWAY_URL=https://gateway.example.com \
    TOKEN=hsk_test \
    MODE=host
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

test_install_hook_invokes_vortex_installer() {
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

  GATEWAY_URL=https://gateway.example.com \
  TOKEN=hsk_test \
  WORKSPACE_ID=workspace-1 \
  VORTEX_INSTALLER_URL=https://get.pipeops.dev/vortex.sh \
    install_bundled_vortex_if_needed >/dev/null

  contents="$(cat "$tmp")"
  assert_contains_line "$contents" "URL=https://get.pipeops.dev/vortex.sh" "installer url"
  assert_contains_line "$contents" "VORTEX_GATEWAY_URL=https://gateway.example.com" "installer gateway env"
  assert_contains_line "$contents" "VORTEX_BOOTSTRAP_TOKEN=hsk_test" "installer token env"
  assert_contains_line "$contents" "VORTEX_WORKSPACE_ID=workspace-1" "installer workspace env"
  assert_contains_line "$contents" "VORTEX_INSTALL_SERVICE=true" "installer service env"
}

test_defaults_to_vortex_for_linux_host_bootstrap
test_skips_vortex_for_non_host_modes
test_skips_vortex_when_disabled
test_skips_vortex_for_unsupported_setting
test_skips_vortex_without_workspace
test_builds_vortex_env_from_igris_context
test_vortex_installer_host_allowlist
test_vortex_installer_security_gate_checks
test_vortex_installer_checksum_validation
test_install_hook_invokes_vortex_installer

echo "ok"
