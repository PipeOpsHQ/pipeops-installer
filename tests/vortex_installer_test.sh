#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

export VORTEX_INSTALLER_SKIP_MAIN=1
# shellcheck source=vortex.sh
source "${REPO_ROOT}/vortex.sh"

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

test_normalize_version() {
  assert_eq "1.2.3" "$(normalize_version v1.2.3)" "strips leading v"
  assert_eq "1.2.3" "$(normalize_version 1.2.3)" "keeps plain semver"
}

test_archive_candidates_include_normalized_and_legacy_names() {
  local names

  names="$(archive_candidates_for_platform linux-amd64 v0.1.0)"
  assert_eq $'vortex_0.1.0_linux_amd64.tar.gz\nvortex-linux-amd64-0.1.0.tar.gz' "$names" "amd64 archive candidates"

  names="$(archive_candidates_for_platform linux-arm64 1.6.4)"
  assert_eq $'vortex_1.6.4_linux_arm64.tar.gz\nvortex-linux-arm64-1.6.4.tar.gz' "$names" "arm64 archive candidates"
}

test_normalize_arch() {
  assert_eq "amd64" "$(normalize_arch x86_64)" "x86_64 maps to amd64"
  assert_eq "arm64" "$(normalize_arch aarch64)" "aarch64 maps to arm64"
}

test_missing_gateway_requirements() {
  local missing

  missing="$(VORTEX_GATEWAY_URL=https://gateway.example.com VORTEX_BOOTSTRAP_TOKEN=hsk_test missing_gateway_requirements)"
  assert_eq "VORTEX_WORKSPACE_ID/WORKSPACE_ID" "$missing" "workspace required for enrollment"

  missing="$(VORTEX_GATEWAY_URL=https://gateway.example.com VORTEX_BOOTSTRAP_TOKEN=hsk_test VORTEX_WORKSPACE_ID=workspace-1 missing_gateway_requirements)"
  assert_eq "" "$missing" "complete enrollment env"
}

test_render_config_file() {
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  render_config_file "$tmp" "http://localhost:3030" "hsk_test" "workspace-1" "tenant-1" "org-1" "eth1" "pcap" "true" "19090"

  grep -q '^iface = "eth1"$' "$tmp" || fail "config missing iface"
  grep -q '^ips_mode = true$' "$tmp" || fail "config missing ips_mode"
  grep -q '^metrics_port = 19090$' "$tmp" || fail "config missing metrics_port"
  grep -q '^url = "http://localhost:3030"$' "$tmp" || fail "config missing gateway url"
  grep -q '^bootstrap_token = "hsk_test"$' "$tmp" || fail "config missing bootstrap token"
  grep -q '^workspace_id = "workspace-1"$' "$tmp" || fail "config missing workspace id"
  grep -q '^capture_backend = "pcap"$' "$tmp" || fail "config missing capture backend"
}

test_get_latest_version_uses_highest_stable_release() {
  gh_api_get() {
    cat <<'JSON'
[
  {"tag_name":"v1.2.3"},
  {"tag_name":"v9.0.0-rc1"},
  {"tag_name":"v1.3.0"}
]
JSON
  }

  assert_eq "1.3.0" "$(get_latest_version)" "highest stable release"
}

test_get_latest_version_fails_without_stable_release() {
  gh_api_get() {
    printf '[{"tag_name":"v9.0.0-rc1"}]\n'
  }

  if (get_latest_version >/dev/null 2>/dev/null); then
    fail "get_latest_version should fail closed when no stable semver tag exists"
  fi
}

test_validate_tar_entries_rejects_symlink() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/payload"
  ln -s /etc/passwd "$tmp/payload/vortex"
  tar -czf "$tmp/payload.tar.gz" -C "$tmp/payload" .

  if (validate_tar_entries "$tmp/payload.tar.gz" >/dev/null 2>/dev/null); then
    fail "validate_tar_entries should reject symlink entries"
  fi
}

test_normalize_version
test_archive_candidates_include_normalized_and_legacy_names
test_normalize_arch
test_missing_gateway_requirements
test_render_config_file
test_get_latest_version_uses_highest_stable_release
test_get_latest_version_fails_without_stable_release
test_validate_tar_entries_rejects_symlink

echo "ok"
