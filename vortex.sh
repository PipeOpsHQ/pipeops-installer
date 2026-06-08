#!/usr/bin/env bash
#
# Vortex Network Agent Installer
# Usage: curl -fsSL https://get.pipeops.dev/vortex.sh | bash
#
# Environment variables:
#   VORTEX_VERSION         - Specific version to install (default: highest semver release)
#   VORTEX_INSTALL_DIR     - Binary install directory (default: /usr/local/bin)
#   VORTEX_RELEASE_REPO    - GitHub release repo (default: PipeOpsHQ/vortex)
#   VORTEX_GITHUB_TOKEN    - Optional GitHub token (aliases: GITHUB_TOKEN, GH_TOKEN)
#   VORTEX_GATEWAY_URL     - Halo Gateway URL (alias: GATEWAY_URL)
#   VORTEX_BOOTSTRAP_TOKEN - Agent bootstrap JWT/API key/service key (aliases: VORTEX_TOKEN, TOKEN, IGRIS_AGENT_TOKEN)
#   VORTEX_WORKSPACE_ID    - Workspace ID/UUID (alias: WORKSPACE_ID)
#   VORTEX_TENANT_ID       - Optional tenant ID/UUID (alias: TENANT_ID)
#   VORTEX_ORG_ID          - Optional organization ID/UUID (alias: ORG_ID)
#   VORTEX_IFACE           - Network interface to monitor (default: default route device or eth0)
#   VORTEX_CAPTURE_BACKEND - auto, ebpf, or pcap (default: auto)
#   VORTEX_IPS_MODE        - true/false (default: false)
#   VORTEX_METRICS_PORT    - Prometheus metrics port, 0 disables (default: 9090)
#   VORTEX_INSTALL_SERVICE - true/false, force service install without enrollment env
#

set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  sudo() {
    "$@"
  }
fi

REQUESTED_VERSION="${VORTEX_VERSION:-}"
VERSION="0.1.0"
INSTALL_DIR="${VORTEX_INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="vortex"
REPO="${VORTEX_RELEASE_REPO:-PipeOpsHQ/vortex}"
GITHUB_URL="https://github.com/${REPO}"
RELEASES_URL="${GITHUB_URL}/releases"
SERVICE_STARTED="false"

GITHUB_TOKEN_VALUE="${VORTEX_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
  echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

ensure_sudo_available() {
  local reason="${1:-perform privileged installation steps}"

  if [[ "$(id -u)" -eq 0 ]]; then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    error "sudo is required to ${reason}, but sudo is not installed."
  fi

  info "Requesting sudo access to ${reason}..."
  if ! sudo -v; then
    error "sudo authentication failed; cannot ${reason}."
  fi
}

get_first_env() {
  local key value

  for key in "$@"; do
    value="${!key:-}"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done

  return 1
}

resolve_gateway_url() {
  get_first_env VORTEX_GATEWAY_URL GATEWAY_URL || true
}

resolve_bootstrap_token() {
  get_first_env VORTEX_BOOTSTRAP_TOKEN VORTEX_TOKEN TOKEN IGRIS_AGENT_TOKEN IGRIS_TOKEN || true
}

resolve_workspace_id() {
  get_first_env VORTEX_WORKSPACE_ID WORKSPACE_ID IGRIS_WORKSPACE_ID || true
}

resolve_tenant_id() {
  get_first_env VORTEX_TENANT_ID TENANT_ID IGRIS_TENANT_ID || true
}

resolve_org_id() {
  get_first_env VORTEX_ORG_ID ORG_ID IGRIS_ORG_ID || true
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|True|yes|YES|Yes|y|Y|on|ON|On)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_bool() {
  if truthy "${1:-}"; then
    printf 'true'
  else
    printf 'false'
  fi
}

default_iface() {
  if command -v ip >/dev/null 2>&1; then
    ip route show default 2>/dev/null | awk '/default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
    return
  fi

  printf 'eth0'
}

resolve_iface() {
  local iface
  iface="$(get_first_env VORTEX_IFACE IFACE || true)"
  if [[ -n "$iface" ]]; then
    printf '%s' "$iface"
    return
  fi

  iface="$(default_iface)"
  printf '%s' "${iface:-eth0}"
}

has_gateway_env() {
  [[ -n "$(resolve_gateway_url)" || -n "$(resolve_bootstrap_token)" || -n "$(resolve_workspace_id)" || -n "$(resolve_tenant_id)" || -n "$(resolve_org_id)" ]]
}

missing_gateway_requirements() {
  local missing=()

  [[ -z "$(resolve_gateway_url)" ]] && missing+=("VORTEX_GATEWAY_URL/GATEWAY_URL")
  [[ -z "$(resolve_bootstrap_token)" ]] && missing+=("VORTEX_BOOTSTRAP_TOKEN/TOKEN")
  [[ -z "$(resolve_workspace_id)" ]] && missing+=("VORTEX_WORKSPACE_ID/WORKSPACE_ID")

  if ((${#missing[@]} == 0)); then
    return
  fi

  local IFS=', '
  printf '%s' "${missing[*]}"
}

normalize_version() {
  local raw="${1:-}"

  raw="${raw#v}"
  printf '%s' "$raw"
}

release_tag_for_version() {
  printf 'v%s' "$(normalize_version "$1")"
}

compare_versions() {
  local lhs="${1:-0.0.0}" rhs="${2:-0.0.0}"
  lhs="${lhs#v}"; lhs="${lhs%%-*}"; lhs="${lhs%%+*}"
  rhs="${rhs#v}"; rhs="${rhs%%-*}"; rhs="${rhs%%+*}"

  local IFS='.'
  local a=($lhs) b=($rhs)
  local i max=${#a[@]}
  (( ${#b[@]} > max )) && max=${#b[@]}
  for (( i = 0; i < max; i++ )); do
    local ai="${a[i]:-0}" bi="${b[i]:-0}"
    ai="${ai//[^0-9]/}"; bi="${bi//[^0-9]/}"
    ai=$((10#${ai:-0})); bi=$((10#${bi:-0}))
    if (( ai < bi )); then echo "lt"; return; fi
    if (( ai > bi )); then echo "gt"; return; fi
  done
  echo "eq"
}

normalize_arch() {
  local arch="$1"

  case "$arch" in
    x86_64|amd64)
      printf 'amd64'
      ;;
    aarch64|arm64)
      printf 'arm64'
      ;;
    *)
      return 1
      ;;
  esac
}

detect_platform() {
  local os arch

  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" != "linux" ]]; then
    error "Vortex native installer currently supports Linux only; detected ${os}."
  fi

  arch="$(normalize_arch "$(uname -m)")" || error "Unsupported architecture: $(uname -m)"
  printf 'linux-%s' "$arch"
}

archive_candidates_for_platform() {
  local platform="$1"
  local version
  local os
  local arch

  version="$(normalize_version "$2")"
  os="${platform%%-*}"
  arch="${platform#*-}"

  printf '%s_%s_%s_%s.tar.gz\n' "$BINARY_NAME" "$version" "$os" "$arch"
  printf '%s-%s-%s-%s.tar.gz\n' "$BINARY_NAME" "$os" "$arch" "$version"
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

gh_api_get() {
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
      curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN_VALUE}" -H "Accept: application/vnd.github+json" "$url"
    else
      curl -fsSL -H "Accept: application/vnd.github+json" "$url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
      wget -qO- --header="Authorization: Bearer ${GITHUB_TOKEN_VALUE}" --header="Accept: application/vnd.github+json" "$url"
    else
      wget -qO- --header="Accept: application/vnd.github+json" "$url"
    fi
  else
    error "Neither curl nor wget found. Please install one of them."
  fi
}

gh_download_file() {
  local url="$1" out="$2"

  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
      curl -fL -H "Authorization: Bearer ${GITHUB_TOKEN_VALUE}" -H "Accept: application/octet-stream" -o "$out" "$url"
    else
      curl -fsSL -o "$out" "$url"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
      wget -q --header="Authorization: Bearer ${GITHUB_TOKEN_VALUE}" --header="Accept: application/octet-stream" -O "$out" "$url"
    else
      wget -q -O "$out" "$url"
    fi
  else
    error "Neither curl nor wget found. Please install one of them."
  fi
}

get_latest_version() {
  local latest=""
  local tag
  local candidate

  while IFS= read -r tag; do
    candidate="$(normalize_version "$tag")"
    if [[ -z "$latest" || "$(compare_versions "$latest" "$candidate")" == "lt" ]]; then
      latest="$candidate"
    fi
  done < <(gh_api_get "https://api.github.com/repos/${REPO}/releases?per_page=100" 2>/dev/null \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' \
    | sed -E 's/.*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/' || true)

  if [[ -z "$latest" ]]; then
    warn "Could not resolve the latest Vortex version from ${REPO}. Falling back to default: ${VERSION}"
    echo "$VERSION"
  else
    echo "$latest"
  fi
}

checksum_expected_for() {
  local checksums_file="$1"
  local filename="$2"

  awk -v f="$filename" '($2 == f || $2 == "*" f) { print $1; exit }' "$checksums_file"
}

validate_tar_entries() {
  local archive="$1"
  local entry

  while IFS= read -r entry; do
    case "$entry" in
      /*|..|../*|*/../*|*/..)
        error "Refusing to extract unsafe archive entry: ${entry}"
        ;;
    esac
  done < <(tar -tzf "$archive")
}

install_release_payload() {
  local tmp_dir="$1"
  local install_dir="$2"
  local binary
  local ebpf

  binary="$(find "$tmp_dir" -maxdepth 2 -type f -name "$BINARY_NAME" | head -n 1)"
  ebpf="$(find "$tmp_dir" -maxdepth 2 -type f -name "vortex-ebpf" | head -n 1)"

  [[ -n "$binary" ]] || error "Downloaded archive did not contain ${BINARY_NAME}."
  [[ -n "$ebpf" ]] || error "Downloaded archive did not contain vortex-ebpf."

  ensure_sudo_available "install Vortex"
  sudo mkdir -p "$install_dir" /usr/lib/vortex /etc/vortex /var/lib/vortex /var/log/vortex
  sudo install -m 0755 "$binary" "${install_dir}/${BINARY_NAME}"
  sudo install -m 0644 "$ebpf" /usr/lib/vortex/vortex-ebpf
}

download_and_install() {
  local platform="$1"
  local version="$2"
  local tag
  local checksum_url
  local tmp_dir
  local filename
  local expected_sum
  local actual_sum
  local selected=""

  version="$(normalize_version "$version")"
  tag="$(release_tag_for_version "$version")"
  checksum_url="${RELEASES_URL}/download/${tag}/checksums.txt"
  tmp_dir="$(mktemp -d)"

  trap 'rm -rf "$tmp_dir"' RETURN

  info "Downloading Vortex v${version} for ${platform}..."
  gh_download_file "$checksum_url" "${tmp_dir}/checksums.txt" || error "Failed to download checksum manifest: ${checksum_url}"

  while IFS= read -r filename; do
    expected_sum="$(checksum_expected_for "${tmp_dir}/checksums.txt" "$filename")"
    if [[ -z "$expected_sum" ]]; then
      continue
    fi

    if gh_download_file "${RELEASES_URL}/download/${tag}/${filename}" "${tmp_dir}/${filename}"; then
      selected="$filename"
      break
    fi
  done < <(archive_candidates_for_platform "$platform" "$version")

  if [[ -z "$selected" ]]; then
    error "Failed to download a Vortex archive for ${platform} from ${REPO} release ${tag}."
  fi

  info "Verifying checksum..."
  expected_sum="$(checksum_expected_for "${tmp_dir}/checksums.txt" "$selected")"
  actual_sum="$(sha256_file "${tmp_dir}/${selected}")"
  if [[ "$expected_sum" != "$actual_sum" ]]; then
    error "Checksum verification failed for ${selected}."
  fi
  success "Checksum verified"

  validate_tar_entries "${tmp_dir}/${selected}"
  tar -xzf "${tmp_dir}/${selected}" -C "$tmp_dir"
  install_release_payload "$tmp_dir" "$INSTALL_DIR"

  success "Vortex installed successfully."
}

toml_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

render_config_file() {
  local out="$1"
  local gateway_url="$2"
  local bootstrap_token="$3"
  local workspace_id="$4"
  local tenant_id="$5"
  local org_id="$6"
  local iface="$7"
  local capture_backend="$8"
  local ips_mode="$9"
  local metrics_port="${10}"

  {
    printf '[general]\n'
    printf 'iface = "%s"\n' "$(toml_escape "$iface")"
    printf 'ips_mode = %s\n' "$(normalize_bool "$ips_mode")"
    printf 'log_level = "info"\n'
    printf 'log_format = "json"\n'
    printf 'metrics_port = %s\n' "$metrics_port"
    printf '\n'

    if [[ -n "$gateway_url" ]]; then
      printf '[gateway]\n'
      printf 'url = "%s"\n' "$(toml_escape "$gateway_url")"
      printf 'bootstrap_token = "%s"\n' "$(toml_escape "$bootstrap_token")"
      printf 'workspace_id = "%s"\n' "$(toml_escape "$workspace_id")"
      [[ -n "$tenant_id" ]] && printf 'tenant_id = "%s"\n' "$(toml_escape "$tenant_id")"
      [[ -n "$org_id" ]] && printf 'org_id = "%s"\n' "$(toml_escape "$org_id")"
      printf 'capabilities = ["network_telemetry", "dns_monitoring", "tls_fingerprinting", "flow_monitoring", "ids"]\n'
      printf 'heartbeat_secs = 30\n'
      printf 'http_timeout_secs = 5\n'
      printf 'retry_backoff_ms = [100, 500, 2000]\n'
      printf 'ws_reconnect_min_ms = 2000\n'
      printf 'ws_reconnect_max_ms = 120000\n'
      printf '\n'
    fi

    printf '[compat]\n'
    printf 'capture_backend = "%s"\n' "$(toml_escape "$capture_backend")"
    printf 'force_ids_only = false\n'
    printf 'allow_degraded = true\n'
    printf 'require_ebpf = false\n'
    printf '\n'
    printf '[compat.pcap]\n'
    printf 'buffer_size_mb = 16\n'
    printf 'promiscuous = true\n'
    printf 'snaplen = 65535\n'
  } > "$out"
}

write_config_file() {
  local gateway_url="$1"
  local bootstrap_token="$2"
  local workspace_id="$3"
  local tenant_id="$4"
  local org_id="$5"
  local iface="$6"
  local capture_backend="$7"
  local ips_mode="$8"
  local metrics_port="$9"
  local tmp_config

  tmp_config="$(mktemp)"
  trap 'rm -f "$tmp_config"' RETURN

  render_config_file "$tmp_config" "$gateway_url" "$bootstrap_token" "$workspace_id" "$tenant_id" "$org_id" "$iface" "$capture_backend" "$ips_mode" "$metrics_port"

  ensure_sudo_available "write Vortex configuration"
  sudo mkdir -p /etc/vortex
  sudo install -m 0600 "$tmp_config" /etc/vortex/config.toml
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

verify_systemd_service_active() {
  if sudo systemctl is-active --quiet vortex; then
    success "vortex systemd service is active."
    return
  fi

  warn "systemd accepted the unit, but vortex is not active."
  sudo systemctl status vortex --no-pager -l || true
  sudo journalctl -u vortex -n 80 --no-pager || true
  error "vortex service failed to start."
}

create_systemd_service() {
  local service_file="/etc/systemd/system/vortex.service"

  systemd_available || return 1

  ensure_sudo_available "install Vortex systemd service"
  info "Creating systemd service at ${service_file}..."

  sudo tee "$service_file" >/dev/null <<EOF
[Unit]
Description=Vortex Network Security Agent
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/vortex
ExecStart=${INSTALL_DIR}/${BINARY_NAME} --config /etc/vortex/config.toml
Restart=always
RestartSec=10
TimeoutStopSec=15
KillMode=mixed
LimitMEMLOCK=infinity
AmbientCapabilities=CAP_NET_ADMIN CAP_BPF CAP_SYS_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN CAP_BPF CAP_SYS_ADMIN
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ReadWritePaths=/var/lib/vortex /var/log/vortex /run/vortex
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vortex

[Install]
WantedBy=multi-user.target
EOF

  sudo mkdir -p /var/lib/vortex /var/log/vortex
  sudo chmod 700 /var/lib/vortex
  sudo chmod 755 /var/log/vortex
  sudo systemctl daemon-reload
  sudo systemctl enable vortex
  sudo systemctl restart vortex
  verify_systemd_service_active

  SERVICE_STARTED="true"
  success "Vortex systemd service created and started."
  info "Check status with: sudo systemctl status vortex"
}

should_install_service() {
  if truthy "${VORTEX_INSTALL_SERVICE:-}"; then
    return 0
  fi

  if has_gateway_env; then
    return 0
  fi

  if [[ -t 0 ]]; then
    local reply
    read -r -p "Would you like to install Vortex as a systemd service? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
    return
  fi

  return 1
}

install_service_if_requested() {
  local gateway_url
  local bootstrap_token
  local workspace_id
  local tenant_id
  local org_id
  local iface
  local capture_backend
  local ips_mode
  local metrics_port
  local missing

  should_install_service || return

  if has_gateway_env; then
    missing="$(missing_gateway_requirements)"
    if [[ -n "$missing" ]]; then
      error "Cannot configure Vortex enrollment; missing required env vars: ${missing}"
    fi
  fi

  gateway_url="$(resolve_gateway_url)"
  bootstrap_token="$(resolve_bootstrap_token)"
  workspace_id="$(resolve_workspace_id)"
  tenant_id="$(resolve_tenant_id)"
  org_id="$(resolve_org_id)"
  iface="$(resolve_iface)"
  capture_backend="${VORTEX_CAPTURE_BACKEND:-auto}"
  ips_mode="${VORTEX_IPS_MODE:-false}"
  metrics_port="${VORTEX_METRICS_PORT:-9090}"

  case "$capture_backend" in
    auto|ebpf|pcap) ;;
    *) error "VORTEX_CAPTURE_BACKEND must be auto, ebpf, or pcap." ;;
  esac

  write_config_file "$gateway_url" "$bootstrap_token" "$workspace_id" "$tenant_id" "$org_id" "$iface" "$capture_backend" "$ips_mode" "$metrics_port"

  if create_systemd_service; then
    return
  fi

  warn "No supported service manager detected. Vortex was installed, but no background service was created."
  info "Run manually with: sudo ${INSTALL_DIR}/${BINARY_NAME} --config /etc/vortex/config.toml"
}

print_success_message() {
  echo
  echo "Vortex installed successfully!"
  echo
  echo "Quick Start:"
  echo "  sudo ${INSTALL_DIR}/${BINARY_NAME} --iface $(resolve_iface)"
  echo
  echo "Auto-enrollment:"
  echo "  VORTEX_GATEWAY_URL=https://halo.example.com \\"
  echo "  VORTEX_BOOTSTRAP_TOKEN=<agent-install-service-key> \\"
  echo "  VORTEX_WORKSPACE_ID=<workspace-uuid> \\"
  echo "  curl -fsSL https://get.pipeops.dev/vortex.sh | bash"
  echo
  if [[ "$SERVICE_STARTED" == "true" ]]; then
    echo "Service:"
    echo "  sudo systemctl status vortex"
    echo "  sudo journalctl -u vortex -f"
  fi
}

main() {
  local platform
  local target_version

  echo
  echo "Vortex Network Agent Installer"
  echo "PipeOps network telemetry and runtime monitoring"
  echo

  platform="$(detect_platform)"
  target_version="${REQUESTED_VERSION:-$(get_latest_version)}"
  target_version="$(normalize_version "$target_version")"

  info "Detected platform: ${platform}"
  info "Version: ${target_version}"

  download_and_install "$platform" "$target_version"
  install_service_if_requested
  print_success_message
}

if [[ "${VORTEX_INSTALLER_SKIP_MAIN:-}" != "1" ]]; then
  main "$@"
fi
