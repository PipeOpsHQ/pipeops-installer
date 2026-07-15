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
  {
    "tag_name": "v1.2.3",
    "draft": false,
    "prerelease": false
  },
  {
    "tag_name": "v9.0.0-rc1",
    "draft": false,
    "prerelease": true
  },
  {
    "tag_name": "v1.4.0",
    "draft": true,
    "prerelease": false
  },
  {
    "tag_name": "v1.3.0",
    "draft": false,
    "prerelease": false
  }
]
JSON
  }

  assert_eq "1.3.0" "$(get_latest_version)" "highest stable release"
}

test_get_latest_version_fails_without_stable_release() {
  gh_api_get() {
    printf '[{"tag_name": "v9.0.0-rc1", "draft": false, "prerelease": true}]\n'
  }

  if (get_latest_version >/dev/null 2>/dev/null); then
    fail "get_latest_version should fail closed when no stable semver tag exists"
  fi
}

test_validate_metrics_port() {
  if (validate_metrics_port "abc" >/dev/null 2>&1); then
    fail "validate_metrics_port should reject non-numeric values"
  fi

  if (validate_metrics_port "70000" >/dev/null 2>&1); then
    fail "validate_metrics_port should reject values above 65535"
  fi

  validate_metrics_port "9090" >/dev/null
}

test_validate_tar_entries_rejects_symlink() {
  local fake_archive="/tmp/fake-vortex-symlink.tar.gz"
  local original_tar
  original_tar="$(type -p tar)"
  is_gnu_tar() { return 0; }

  tar() {
    local arg
    local has_tf=0
    local has_tvf=0

    for arg in "$@"; do
      if [[ "$arg" == "-tf" ]]; then
        has_tf=1
      elif [[ "$arg" == "-tvf" ]]; then
        has_tvf=1
      fi
    done

    if (( has_tf )) && [[ "${*: -1}" == "$fake_archive" ]]; then
      printf 'vortex\n'
      return 0
    fi

    if (( has_tvf )) && [[ "${*: -1}" == "$fake_archive" ]]; then
      printf 'lwrwxrwxrwx root/root 0 2026-06-08 00:00 vortex -> /etc/passwd\n'
      return 0
    fi

    "$original_tar" "$@"
  }

  if (validate_tar_entries "$fake_archive" >/dev/null 2>/dev/null); then
    fail "validate_tar_entries should reject symlink entries"
  fi

  unset -f is_gnu_tar
  unset -f tar
}

test_validate_tar_entries_rejects_absolute_paths() {
  local fake_archive="/tmp/fake-vortex-absolute.tar.gz"
  local original_tar
  original_tar="$(type -p tar)"

  tar() {
    local arg
    local has_tf=0
    local has_tvf=0

    for arg in "$@"; do
      if [[ "$arg" == "-tf" ]]; then
        has_tf=1
      elif [[ "$arg" == "-tvf" ]]; then
        has_tvf=1
      fi
    done

    if (( has_tf )) && [[ "${*: -1}" == "$fake_archive" ]]; then
      printf '/etc/passwd\n'
      return 0
    fi

    if (( has_tvf )) && [[ "${*: -1}" == "$fake_archive" ]]; then
      printf '-rw-r--r-- root/root 0 2026-06-08 00:00 /etc/passwd\n'
      return 0
    fi

    "$original_tar" "$@"
  }

  if (validate_tar_entries "$fake_archive" >/dev/null 2>/dev/null); then
    fail "validate_tar_entries should reject absolute-path entries"
  fi

  unset -f tar
}

test_validate_tar_entries_rejects_traversal_paths() {
  local fake_archive="/tmp/fake-vortex-traversal.tar.gz"
  local original_tar
  original_tar="$(type -p tar)"

  tar() {
    local arg
    local has_tf=0
    local has_tvf=0

    for arg in "$@"; do
      if [[ "$arg" == "-tf" ]]; then
        has_tf=1
      elif [[ "$arg" == "-tvf" ]]; then
        has_tvf=1
      fi
    done

    if (( has_tf )) && [[ "${*: -1}" == "$fake_archive" ]]; then
      printf '../etc/passwd\n'
      return 0
    fi

    if (( has_tvf )) && [[ "${*: -1}" == "$fake_archive" ]]; then
      printf '-rw-r--r-- root/root 0 2026-06-08 00:00 ../etc/passwd\n'
      return 0
    fi

    "$original_tar" "$@"
  }

  if (validate_tar_entries "$fake_archive" >/dev/null 2>/dev/null); then
    fail "validate_tar_entries should reject directory traversal entries"
  fi

  unset -f tar
}

test_binary_only_install_flag() {
  if binary_only_install; then
    fail "binary_only_install should be off by default"
  fi

  if ! (VORTEX_BINARY_ONLY=true binary_only_install); then
    fail "binary_only_install should honor VORTEX_BINARY_ONLY=true"
  fi

  if (VORTEX_BINARY_ONLY=false binary_only_install); then
    fail "binary_only_install should stay off for VORTEX_BINARY_ONLY=false"
  fi
}

test_binary_only_skips_service_and_enrollment() {
  local recorded
  recorded="$(mktemp)"
  trap 'rm -f "$recorded"' RETURN

  write_config_file() {
    printf 'write_config_file\n' >> "$recorded"
  }

  create_systemd_service() {
    printf 'create_systemd_service\n' >> "$recorded"
  }

  # Even with a full enrollment env AND a forced service install, binary-only
  # mode must not write config, create a service user, or install a unit.
  VORTEX_BINARY_ONLY=true \
  VORTEX_INSTALL_SERVICE=true \
  VORTEX_GATEWAY_URL=https://gateway.example.com \
  VORTEX_BOOTSTRAP_TOKEN=hsk_test \
  VORTEX_WORKSPACE_ID=workspace-1 \
    install_service_if_requested >/dev/null 2>&1

  if [[ -s "$recorded" ]]; then
    fail "binary-only install must skip config + service setup, got: $(cat "$recorded")"
  fi

  unset -f write_config_file
  unset -f create_systemd_service
}

test_has_vortex_enrollment_env() {
  unset VORTEX_GATEWAY_URL VORTEX_BOOTSTRAP_TOKEN VORTEX_TOKEN VORTEX_WORKSPACE_ID VORTEX_TENANT_ID VORTEX_ORG_ID
  if has_vortex_enrollment_env; then
    fail "has_vortex_enrollment_env should not trigger when only TOKEN/GATEWAY_URL aliases are set"
  fi

  TOKEN="abc"
  export TOKEN
  if has_vortex_enrollment_env; then
    fail "has_vortex_enrollment_env should ignore generic alias env vars"
  fi
  TOKEN=""
  export TOKEN

  VORTEX_BOOTSTRAP_TOKEN="abc"
  export VORTEX_BOOTSTRAP_TOKEN
  if ! has_vortex_enrollment_env; then
    fail "has_vortex_enrollment_env should trigger when VORTEX_* vars are set"
  fi

  unset TOKEN
  unset VORTEX_BOOTSTRAP_TOKEN
}

test_normalize_version
test_archive_candidates_include_normalized_and_legacy_names
test_normalize_arch
test_missing_gateway_requirements
test_render_config_file
test_get_latest_version_uses_highest_stable_release
test_get_latest_version_fails_without_stable_release
test_validate_tar_entries_rejects_symlink
test_validate_tar_entries_rejects_absolute_paths
test_validate_tar_entries_rejects_traversal_paths
test_validate_metrics_port
test_binary_only_install_flag
test_binary_only_skips_service_and_enrollment
test_has_vortex_enrollment_env

echo "ok"
