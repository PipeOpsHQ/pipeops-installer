#!/bin/bash
#
# Igris Agent Installer
# Usage: curl -fsSL https://get.pipeops.dev/igris.sh | bash
#
# Environment variables:
#   IGRIS_VERSION      - Specific version to install (default: 0.6.1)
#   IGRIS_INSTALL_DIR  - Installation directory (default: /usr/local/bin)
#   IGRIS_GATEWAY_URL  - Halo Gateway URL (alias: GATEWAY_URL)
#   IGRIS_AGENT_TOKEN  - Agent enrollment token (aliases: IGRIS_TOKEN, TOKEN)
#   IGRIS_WORKSPACE_ID - Workspace ID (alias: WORKSPACE_ID)
#   IGRIS_TENANT_ID    - Tenant ID (alias: TENANT_ID)
#   IGRIS_ORG_ID       - Organisation ID (alias: ORG_ID)
#   IGRIS_MODE         - Deployment mode / agent type (alias: MODE)
#

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
VERSION="1.5.3"
INSTALL_DIR="${IGRIS_INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="igris"
REPO="PipeOpsHQ/pipeops-installer"
GITHUB_URL="https://github.com/${REPO}"
RELEASES_URL="${GITHUB_URL}/releases"
DOCS_URL="https://github.com/PipeOpsHQ/halo"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# ─── Helper Functions ────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_cmd() {
    if ! command -v "$1" &> /dev/null; then
        error "Required command not found: $1"
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

resolve_gateway_url()    { get_first_env IGRIS_GATEWAY_URL GATEWAY_URL || true; }
resolve_agent_token()    { get_first_env IGRIS_AGENT_TOKEN IGRIS_TOKEN TOKEN || true; }
resolve_workspace_id()   { get_first_env IGRIS_WORKSPACE_ID WORKSPACE_ID || true; }
resolve_tenant_id()      { get_first_env IGRIS_TENANT_ID TENANT_ID || true; }
resolve_org_id()         { get_first_env IGRIS_ORG_ID ORG_ID || true; }
resolve_requested_mode() { get_first_env IGRIS_MODE MODE || true; }

normalize_mode() {
    local mode="${1:-host}"
    mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    mode="${mode//-/_}"
    mode="${mode// /_}"

    case "$mode" in
        host|server|vm|virtual_machine|baremetal|bare_metal|physical)
            printf 'host' ;;
        kubernetes|k8s|daemonset|sidecar|pod|cluster|kubernetes_node|kubernetes_pod|eks|gke|aks)
            printf 'kubernetes' ;;
        cloud|cloud_instance|instance|ec2|aws|gcp|gce|azure|azure_vm|lambda|serverless|cloud_function|cloud_functions|function_app)
            printf 'cloud' ;;
        container|docker|docker_container|podman|ecs|fargate|crio|cri_o)
            printf 'container' ;;
        *)
            return 1 ;;
    esac
}

has_bootstrap_env() {
    [[ -n "$(resolve_gateway_url)" || -n "$(resolve_agent_token)" || \
       -n "$(resolve_workspace_id)" || -n "$(resolve_tenant_id)" || \
       -n "$(resolve_org_id)" || -n "$(resolve_requested_mode)" ]]
}

missing_service_requirements() {
    local missing=()
    [[ -z "$(resolve_gateway_url)" ]]  && missing+=("GATEWAY_URL/IGRIS_GATEWAY_URL")
    [[ -z "$(resolve_agent_token)" ]]  && missing+=("TOKEN/IGRIS_AGENT_TOKEN")
    [[ -z "$(resolve_workspace_id)" ]] && missing+=("WORKSPACE_ID/IGRIS_WORKSPACE_ID")
    [[ -z "$(resolve_tenant_id)" ]]    && missing+=("TENANT_ID/IGRIS_TENANT_ID")
    [[ -z "$(resolve_org_id)" ]]       && missing+=("ORG_ID/IGRIS_ORG_ID")
    printf '%s' "${missing[*]:-}"
}

# ─── Detect Platform ─────────────────────────────────────────────────────────
detect_os() {
    case "$(uname -s)" in
        Linux*)   echo "linux" ;;
        Darwin*)  echo "darwin" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)        error "Unsupported OS: $(uname -s)" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armv7)   echo "armv7" ;;
        *)              error "Unsupported architecture: $(uname -m)" ;;
    esac
}

# ─── Get Latest Version ──────────────────────────────────────────────────────
get_latest_version() {
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local latest=""

    if command -v curl &> /dev/null; then
        latest=$(curl -fsSL "${api_url}" 2>/dev/null | \
                 grep -o '"tag_name": *"v[^"]*"' | head -1 | \
                 sed 's/.*"v\([^"]*\)".*/\1/')
    elif command -v wget &> /dev/null; then
        latest=$(wget -qO- "${api_url}" 2>/dev/null | \
                 grep -o '"tag_name": *"v[^"]*"' | head -1 | \
                 sed 's/.*"v\([^"]*\)".*/\1/')
    fi

    if [[ -z "$latest" ]]; then
        warn "Could not fetch latest version, using default: ${VERSION}"
        echo "$VERSION"
    else
        echo "$latest"
    fi
}

# ─── Download File ───────────────────────────────────────────────────────────
download() {
    local url="$1"
    local dest="$2"

    if command -v curl &> /dev/null; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget &> /dev/null; then
        wget -q -O "$dest" "$url"
    else
        error "Neither curl nor wget found"
    fi
}

# ─── Verify Checksum ─────────────────────────────────────────────────────────
verify_checksum() {
    local file="$1"
    local expected="$2"

    local actual
    if command -v sha256sum &> /dev/null; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum &> /dev/null; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "No sha256sum or shasum available, skipping verification"
        return 0
    fi

    [[ "$actual" == "$expected" ]]
}

# ─── Install Binary ──────────────────────────────────────────────────────────
install_binary() {
    local os="$1"
    local arch="$2"
    local version="$3"

    local ext=""
    [[ "$os" == "windows" ]] && ext=".exe"

    local archive_name="${BINARY_NAME}_${version}_${os}_${arch}.tar.gz"
    [[ "$os" == "windows" ]] && archive_name="${BINARY_NAME}_${version}_${os}_${arch}.zip"

    local base_url="${RELEASES_URL}/download/v${version}"
    local archive_url="${base_url}/${archive_name}"
    local checksum_url="${base_url}/checksums.txt"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf ${tmp_dir}" EXIT

    info "Downloading Igris Agent v${version} for ${os}/${arch}..."
    download "$archive_url" "${tmp_dir}/${archive_name}" || \
        error "Failed to download: ${archive_url}"

    # Verify checksum
    info "Verifying checksum..."
    local checksum_file="${tmp_dir}/checksums.txt"
    if download "$checksum_url" "$checksum_file" 2>/dev/null; then
        local expected
        expected=$(grep "  ${archive_name}$" "$checksum_file" | awk '{print $1}')
        if [[ -n "$expected" ]] && verify_checksum "${tmp_dir}/${archive_name}" "$expected"; then
            success "Checksum verified"
        else
            error "Checksum verification failed!"
        fi
    else
        warn "Checksum file not available, skipping verification"
    fi

    # Extract
    cd "$tmp_dir"
    if [[ "$os" == "windows" ]]; then
        need_cmd unzip
        unzip -q "$archive_name"
    else
        tar -xzf "$archive_name"
    fi

    # Install
    local target="${INSTALL_DIR}/${BINARY_NAME}${ext}"
    local binary_file="${BINARY_NAME}${ext}"

    info "Installing to ${target}..."
    chmod +x "$binary_file"

    if [[ -w "$INSTALL_DIR" ]]; then
        mv "$binary_file" "$target"
    else
        info "Requesting sudo access to install to ${INSTALL_DIR}..."
        sudo mv "$binary_file" "$target"
    fi

    success "Igris Agent v${version} installed successfully!"
}

# ─── Create Systemd Service ──────────────────────────────────────────────────
create_systemd_service() {
    local auto_config="${1:-false}"

    if [[ "$(uname -s)" != "Linux" ]]; then
        return
    fi

    if ! command -v systemctl &> /dev/null; then
        return
    fi

    if [[ "$auto_config" != "true" ]]; then
        read -p "Would you like to install Igris as a systemd service? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    else
        info "Detected bootstrap environment; creating a systemd service..."
    fi

    local gateway_url token workspace_id tenant_id org_id requested_mode mode
    gateway_url="$(resolve_gateway_url)"
    token="$(resolve_agent_token)"
    workspace_id="$(resolve_workspace_id)"
    tenant_id="$(resolve_tenant_id)"
    org_id="$(resolve_org_id)"
    requested_mode="$(resolve_requested_mode)"

    if [[ "$auto_config" == "true" ]]; then
        local missing
        missing="$(missing_service_requirements)"
        if [[ -n "$missing" ]]; then
            warn "Skipping systemd service setup: missing required env vars: ${missing}"
            info "Set GATEWAY_URL/TOKEN/WORKSPACE_ID/TENANT_ID/ORG_ID (or IGRIS_* equivalents) to auto-configure the service."
            return
        fi
    fi

    if [[ -z "$gateway_url" ]]; then
        read -p "Enter Halo Gateway URL (e.g., https://halo.example.com): " gateway_url
    fi
    if [[ -z "$token" ]]; then
        read -p "Enter Agent Enrollment Token: " token
    fi
    if [[ -z "$workspace_id" ]]; then
        read -p "Enter Workspace ID: " workspace_id
    fi
    if [[ -z "$tenant_id" ]]; then
        read -p "Enter Tenant ID: " tenant_id
    fi
    if [[ -z "$org_id" ]]; then
        read -p "Enter Organisation ID: " org_id
    fi
    if [[ -z "$requested_mode" ]]; then
        read -p "Enter deployment mode / agent type (default: host): " requested_mode
    fi

    requested_mode="${requested_mode:-host}"
    mode="$(normalize_mode "$requested_mode")" || \
        error "Unsupported deployment mode / agent type: ${requested_mode}"

    local service_file="/etc/systemd/system/igris.service"
    local env_file="/etc/default/igris"

    info "Writing agent environment to ${env_file}..."
    sudo tee "$env_file" > /dev/null << EOF
IGRIS_GATEWAY_URL=${gateway_url}
IGRIS_AGENT_TOKEN=${token}
IGRIS_WORKSPACE_ID=${workspace_id}
IGRIS_TENANT_ID=${tenant_id}
IGRIS_ORG_ID=${org_id}
IGRIS_MODE=${mode}
EOF
    sudo chmod 600 "$env_file"

    info "Creating systemd service..."
    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=Igris Security Agent
Documentation=${DOCS_URL}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${env_file}
ExecStart=${INSTALL_DIR}/${BINARY_NAME}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=false
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ReadWritePaths=/var/lib/igris /var/log/igris

[Install]
WantedBy=multi-user.target
EOF

    sudo mkdir -p /var/lib/igris /var/log/igris
    sudo systemctl daemon-reload
    sudo systemctl enable igris

    success "Systemd service created!"
    info "Start the agent with: sudo systemctl start igris"
    info "Check status with: sudo systemctl status igris"
}

# ─── Print Usage ─────────────────────────────────────────────────────────────
print_usage() {
    cat << EOF

${GREEN}Igris Agent installed successfully!${NC}

${BLUE}Quick Start:${NC}
  export IGRIS_GATEWAY_URL=https://your-halo-gateway.com
  export IGRIS_AGENT_TOKEN=YOUR_TOKEN
  export IGRIS_WORKSPACE_ID=1
  export IGRIS_TENANT_ID=1
  export IGRIS_ORG_ID=1
  ${BINARY_NAME}

${BLUE}Shorthand Aliases:${NC}
  GATEWAY_URL / IGRIS_GATEWAY_URL
  TOKEN / IGRIS_AGENT_TOKEN
  WORKSPACE_ID / IGRIS_WORKSPACE_ID
  TENANT_ID / IGRIS_TENANT_ID
  ORG_ID / IGRIS_ORG_ID
  MODE / IGRIS_MODE

${BLUE}Examples:${NC}
  # Basic enrollment
  GATEWAY_URL=https://halo.example.com TOKEN=abc123 \\
  WORKSPACE_ID=1 TENANT_ID=1 ORG_ID=1 ${BINARY_NAME}

  # Agent-type aliases are normalized automatically
  GATEWAY_URL=https://halo.example.com TOKEN=abc123 \\
  WORKSPACE_ID=1 TENANT_ID=1 ORG_ID=1 MODE=daemonset ${BINARY_NAME}

  # Install + auto-configure a systemd service from the one-liner
  curl -fsSL https://get.pipeops.dev/igris.sh | \\
    GATEWAY_URL=https://halo.example.com TOKEN=abc123 \\
    WORKSPACE_ID=1 TENANT_ID=1 ORG_ID=1 MODE=host bash

${BLUE}Documentation:${NC}
  ${DOCS_URL}

EOF
}

# ─── Run Agent Directly ──────────────────────────────────────────────────────
run_agent() {
    local gateway_url token workspace_id tenant_id org_id requested_mode mode
    gateway_url="$(resolve_gateway_url)"
    token="$(resolve_agent_token)"
    workspace_id="$(resolve_workspace_id)"
    tenant_id="$(resolve_tenant_id)"
    org_id="$(resolve_org_id)"
    requested_mode="$(resolve_requested_mode)"

    local missing
    missing="$(missing_service_requirements)"
    if [[ -n "$missing" ]]; then
        warn "Cannot start agent: missing required env vars: ${missing}"
        return
    fi

    requested_mode="${requested_mode:-host}"
    mode="$(normalize_mode "$requested_mode")" || {
        warn "Unsupported deployment mode: ${requested_mode}, defaulting to host"
        mode="host"
    }

    info "Starting Igris Agent..."
    export IGRIS_GATEWAY_URL="$gateway_url"
    export IGRIS_AGENT_TOKEN="$token"
    export IGRIS_WORKSPACE_ID="$workspace_id"
    export IGRIS_TENANT_ID="$tenant_id"
    export IGRIS_ORG_ID="$org_id"
    export IGRIS_MODE="$mode"

    exec "${INSTALL_DIR}/${BINARY_NAME}"
}
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           Igris Agent Installer                               ║"
    echo "║           Autonomous Security for Every Environment           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # Detect platform
    local os arch
    os=$(detect_os)
    arch=$(detect_arch)
    info "Platform: ${os}/${arch}"

    # Get version
    if [[ -n "${IGRIS_VERSION:-}" ]]; then
        VERSION="$IGRIS_VERSION"
    else
        VERSION=$(get_latest_version)
    fi
    info "Version: ${VERSION}"

    # Check if already installed
    if command -v "$BINARY_NAME" &> /dev/null; then
        local current_version
        current_version=$("$BINARY_NAME" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        warn "Igris Agent is already installed (version: ${current_version})"
        if [[ -t 0 ]]; then
            read -p "Do you want to reinstall/upgrade? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                info "Installation cancelled."
                exit 0
            fi
        fi
    fi

    # Download and install
    install_binary "$os" "$arch" "$VERSION"

    # Verify installation
    if command -v "$BINARY_NAME" &> /dev/null; then
        local installed_version
        installed_version=$("$BINARY_NAME" --version 2>/dev/null || echo "installed")
        success "Verified: ${BINARY_NAME} ${installed_version}"
    fi

    # Create systemd service (Linux only). In curl|bash flows stdin is not a
    # TTY, so auto-configure when bootstrap env vars are provided.
    local used_systemd=false
    if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl &> /dev/null; then
        if [[ -t 0 ]]; then
            create_systemd_service
            used_systemd=true
        elif has_bootstrap_env; then
            create_systemd_service true
            used_systemd=true
        fi
    fi

    # If systemd wasn't used but bootstrap env vars are set, run the agent directly
    if [[ "$used_systemd" == "false" ]] && has_bootstrap_env; then
        run_agent
    fi

    # Print usage
    print_usage
}

main "$@"
