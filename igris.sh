#!/bin/bash
#
# Igris Agent Installer
# Usage: curl -fsSL https://get.pipeops.dev/igris.sh | bash
#
# Environment variables:
#   VERSION          - Specific version to install (default: latest)
#   PREFIX           - Installation directory (default: /usr/local/bin or ~/.local/bin)
#   GATEWAY_URL      - Halo Gateway URL (optional, for auto-config)
#   TOKEN            - Agent enrollment token (optional, for auto-config)
#   VERIFY           - Checksum verification: auto, strict, skip (default: auto)
#

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
GH_REPO="${GH_REPO:-PipeOpsHQ/halo}"
BINARY_NAME="${BINARY_NAME:-igris}"
VERSION="${VERSION:-}"
PREFIX="${PREFIX:-}"
VERIFY="${VERIFY:-auto}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Helper Functions ────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_cmd() {
    if ! command -v "$1" &> /dev/null; then
        error "Required command not found: $1"
    fi
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
    local api_url="https://api.github.com/repos/${GH_REPO}/releases/latest"
    local latest=""
    
    if command -v curl &> /dev/null; then
        latest=$(curl -fsSL "${api_url}" 2>/dev/null | \
                 grep -o '"tag_name": *"v[^"]*"' | \
                 head -1 | \
                 sed 's/.*"v\([^"]*\)".*/\1/')
    elif command -v wget &> /dev/null; then
        latest=$(wget -qO- "${api_url}" 2>/dev/null | \
                 grep -o '"tag_name": *"v[^"]*"' | \
                 head -1 | \
                 sed 's/.*"v\([^"]*\)".*/\1/')
    fi
    
    if [[ -z "$latest" ]]; then
        error "Could not determine latest version. Set VERSION=x.y.z explicitly."
    fi
    
    echo "$latest"
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
    
    if [[ "$actual" != "$expected" ]]; then
        return 1
    fi
    return 0
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
    
    local base_url="https://github.com/${GH_REPO}/releases/download/v${version}"
    local archive_url="${base_url}/${archive_name}"
    local checksum_url="${base_url}/checksums.txt"
    
    # Create temp directory
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf ${tmp_dir}" EXIT
    
    info "Downloading Igris Agent v${version} for ${os}/${arch}..."
    download "$archive_url" "${tmp_dir}/${archive_name}" || \
        error "Failed to download: ${archive_url}"
    
    # Verify checksum
    if [[ "$VERIFY" != "skip" ]]; then
        info "Verifying checksum..."
        local checksum_file="${tmp_dir}/checksums.txt"
        if download "$checksum_url" "$checksum_file" 2>/dev/null; then
            local expected
            expected=$(grep "  ${archive_name}$" "$checksum_file" | awk '{print $1}')
            if [[ -n "$expected" ]] && verify_checksum "${tmp_dir}/${archive_name}" "$expected"; then
                success "Checksum verified"
            else
                if [[ "$VERIFY" == "strict" ]]; then
                    error "Checksum verification failed!"
                else
                    warn "Checksum mismatch (continuing anyway)"
                fi
            fi
        else
            if [[ "$VERIFY" == "strict" ]]; then
                error "Checksum file not found and VERIFY=strict"
            else
                warn "Checksum file not available, skipping verification"
            fi
        fi
    fi
    
    # Extract
    cd "$tmp_dir"
    if [[ "$os" == "windows" ]]; then
        need_cmd unzip
        unzip -q "$archive_name"
    else
        tar -xzf "$archive_name"
    fi
    
    # Determine install location
    local install_dir="$PREFIX"
    if [[ -z "$install_dir" ]]; then
        if [[ -w "/usr/local/bin" ]]; then
            install_dir="/usr/local/bin"
        elif [[ -d "$HOME/.local/bin" ]] || mkdir -p "$HOME/.local/bin" 2>/dev/null; then
            install_dir="$HOME/.local/bin"
        else
            install_dir="/usr/local/bin"
        fi
    fi
    
    local target="${install_dir}/${BINARY_NAME}${ext}"
    local binary_file="${BINARY_NAME}${ext}"
    
    info "Installing to ${target}..."
    
    chmod +x "$binary_file"
    
    if [[ -w "$install_dir" ]]; then
        mv "$binary_file" "$target"
    else
        info "Requesting sudo access..."
        sudo mv "$binary_file" "$target"
    fi
    
    success "Igris Agent v${version} installed to ${target}"
    
    # Check if in PATH
    if ! command -v "$BINARY_NAME" &> /dev/null; then
        warn "${install_dir} is not in your PATH"
        echo ""
        echo "Add it to your shell profile:"
        echo "  export PATH=\"${install_dir}:\$PATH\""
        echo ""
    fi
}

# ─── Create Systemd Service (Linux) ──────────────────────────────────────────
setup_systemd() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        return 0
    fi
    
    if ! command -v systemctl &> /dev/null; then
        return 0
    fi
    
    local gateway_url="${GATEWAY_URL:-}"
    local token="${TOKEN:-}"
    
    if [[ -z "$gateway_url" ]] || [[ -z "$token" ]]; then
        echo ""
        info "To run as a systemd service, set GATEWAY_URL and TOKEN:"
        echo "  GATEWAY_URL=https://halo.example.com TOKEN=xxx curl -fsSL https://get.pipeops.dev/igris.sh | bash"
        return 0
    fi
    
    info "Setting up systemd service..."
    
    local service_content="[Unit]
Description=Igris Security Agent
Documentation=https://github.com/${GH_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/${BINARY_NAME} --gateway-url ${gateway_url} --token ${token}
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
WantedBy=multi-user.target"

    echo "$service_content" | sudo tee /etc/systemd/system/igris.service > /dev/null
    
    sudo mkdir -p /var/lib/igris /var/log/igris
    sudo systemctl daemon-reload
    sudo systemctl enable igris
    sudo systemctl start igris
    
    success "Systemd service installed and started!"
    info "Check status: sudo systemctl status igris"
    info "View logs: sudo journalctl -u igris -f"
}

# ─── Print Usage ─────────────────────────────────────────────────────────────
print_usage() {
    cat << EOF

${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
${GREEN}Igris Agent installed successfully!${NC}
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${BLUE}Quick Start:${NC}
  ${BINARY_NAME} --gateway-url https://your-halo-gateway.com --token YOUR_TOKEN

${BLUE}Common Options:${NC}
  --gateway-url    Halo Gateway URL
  --token          Agent enrollment token
  --workspace      Workspace ID (optional)
  --tags           Comma-separated tags (optional)
  --log-level      Log level: debug, info, warn, error

${BLUE}Run as Service (Linux):${NC}
  GATEWAY_URL=https://halo.example.com TOKEN=xxx \\
    curl -fsSL https://get.pipeops.dev/igris.sh | bash

${BLUE}Documentation:${NC}
  https://github.com/${GH_REPO}

EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}           ${GREEN}Igris Agent Installer${NC}                               ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}           Autonomous Security for Every Environment           ${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Detect platform
    local os arch
    os=$(detect_os)
    arch=$(detect_arch)
    info "Platform: ${os}/${arch}"
    
    # Get version
    if [[ -z "$VERSION" ]]; then
        info "Fetching latest version..."
        VERSION=$(get_latest_version)
    fi
    info "Version: ${VERSION}"
    
    # Install
    install_binary "$os" "$arch" "$VERSION"
    
    # Setup systemd if credentials provided
    setup_systemd
    
    # Print usage
    print_usage
}

main "$@"
