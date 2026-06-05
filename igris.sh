#!/bin/bash
#
# Igris Agent Installer
# Usage: curl -fsSL https://get.pipeops.dev/igris.sh | bash
#
# Environment variables:
#   IGRIS_VERSION      - Specific version to install (default: latest)
#   IGRIS_INSTALL_DIR  - Installation directory (default: /usr/local/bin)
#   IGRIS_GATEWAY_URL  - Halo Gateway URL (alias: GATEWAY_URL)
#   IGRIS_AGENT_TOKEN  - Agent bootstrap JWT or API key (aliases: IGRIS_TOKEN, TOKEN)
#   IGRIS_WORKSPACE_ID - Optional workspace ID/UUID override (alias: WORKSPACE_ID)
#   IGRIS_MODE         - Deployment mode / agent type (alias: MODE)
#   IGRIS_BINARY_BASE_URL - Optional base URL for raw/self-hosted binaries named igris-<os>-<arch>[.exe]
#   IGRIS_RELEASE_REPO - GitHub release repo for public agent assets
#                        (default: PipeOpsHQ/pipeops-installer)
#   IGRIS_GITHUB_TOKEN - Optional GitHub token (aliases: GITHUB_TOKEN, GH_TOKEN)
#                        for private release repo overrides or rate limits.
#

set -euo pipefail

# Minimal/root containers may not include sudo. Keep the existing sudo-based
# installer paths working when the script is already running as root.
if [[ "$(id -u)" -eq 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    sudo() {
        "$@"
    }
fi

# ─── Configuration ───────────────────────────────────────────────────────────
REQUESTED_VERSION="${IGRIS_VERSION:-}"
# Used only when public release discovery fails. Keep this pinned to a published
# PipeOpsHQ/pipeops-installer release with GoReleaser assets and checksums.txt.
VERSION="1.6.3"
INSTALL_DIR="${IGRIS_INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="igris"
REPO="${IGRIS_RELEASE_REPO:-PipeOpsHQ/pipeops-installer}"
GITHUB_URL="https://github.com/${REPO}"
RELEASES_URL="${GITHUB_URL}/releases"
IGRIS_SERVICE_STARTED="false"

# GitHub auth is optional for the default public release repo. It is still
# supported for private release repo overrides or environments that need a
# higher GitHub API rate limit.
GITHUB_TOKEN_VALUE="${IGRIS_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"

# Colors for output
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

# ─── Helper Functions ────────────────────────────────────────────────────────
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
    get_first_env IGRIS_GATEWAY_URL GATEWAY_URL || true
}

resolve_agent_token() {
    get_first_env IGRIS_AGENT_TOKEN IGRIS_TOKEN TOKEN || true
}

allow_insecure_http() {
    case "${IGRIS_ALLOW_INSECURE_HTTP:-}" in
        1|true|TRUE|True|yes|YES|Yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

refuse_insecure_artifact_token() {
    local url="$1"
    local token="$2"

    if [[ -n "$token" && "$url" == http://* ]] && ! allow_insecure_http; then
        error "Refusing to send TOKEN over plain HTTP to ${url}. Use HTTPS or set IGRIS_ALLOW_INSECURE_HTTP=1 for local testing."
    fi
}

resolve_workspace_id() {
    get_first_env IGRIS_WORKSPACE_ID WORKSPACE_ID || true
}

resolve_tenant_id() {
    get_first_env IGRIS_TENANT_ID TENANT_ID || true
}

resolve_org_id() {
    get_first_env IGRIS_ORG_ID ORG_ID || true
}

resolve_requested_mode() {
    get_first_env IGRIS_MODE MODE || true
}

normalize_mode() {
    local mode="${1:-host}"

    mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    mode="${mode//-/_}"
    mode="${mode// /_}"

    case "$mode" in
        host|server|vm|virtual_machine|baremetal|bare_metal|physical)
            printf 'host'
            ;;
        kubernetes|k8s|daemonset|sidecar|pod|cluster|kubernetes_node|kubernetes_pod|eks|gke|aks)
            printf 'kubernetes'
            ;;
        cloud|cloud_instance|instance|ec2|aws|gcp|gce|azure|azure_vm|lambda|serverless|cloud_function|cloud_functions|function_app)
            printf 'cloud'
            ;;
        container|docker|docker_container|podman|ecs|fargate|crio|cri_o)
            printf 'container'
            ;;
        *)
            return 1
            ;;
    esac
}

has_bootstrap_env() {
    [[ -n "$(resolve_gateway_url)" || -n "$(resolve_agent_token)" || -n "$(resolve_workspace_id)" || -n "$(resolve_tenant_id)" || -n "$(resolve_org_id)" || -n "$(resolve_requested_mode)" ]]
}

# ─── Version comparison ──────────────────────────────────────────────────────
# Compare two semver strings (X.Y.Z, ignoring -prerelease/+build suffixes).
# Prints:
#   "lt" when $1 < $2
#   "eq" when $1 == $2
#   "gt" when $1 > $2
# Designed to be safe under `set -u` and to never call `exit`. Unrecognised
# input (non-numeric components) is treated as 0 so we degrade to "eq" rather
# than aborting an installer in the field.
compare_versions() {
    local lhs="${1:-0.0.0}" rhs="${2:-0.0.0}"
    # Strip leading 'v' and anything from the first '-' or '+' onward.
    lhs="${lhs#v}"; lhs="${lhs%%-*}"; lhs="${lhs%%+*}"
    rhs="${rhs#v}"; rhs="${rhs%%-*}"; rhs="${rhs%%+*}"

    local IFS='.'
    # shellcheck disable=SC2206  # intentional word-split into version parts
    local a=($lhs) b=($rhs)
    # Pad missing components with 0 so "1.2" sorts cleanly against "1.2.0".
    local i max=${#a[@]}; (( ${#b[@]} > max )) && max=${#b[@]}
    for (( i=0; i<max; i++ )); do
        local ai="${a[i]:-0}" bi="${b[i]:-0}"
        # Strip leading zeros + non-digits defensively.
        ai="${ai//[^0-9]/}"; bi="${bi//[^0-9]/}"
        ai=$((10#${ai:-0})); bi=$((10#${bi:-0}))
        if (( ai < bi )); then echo "lt"; return; fi
        if (( ai > bi )); then echo "gt"; return; fi
    done
    echo "eq"
}

# Restart the running igris service after a binary replacement so the new
# binary actually takes effect. Tries each known service manager in turn —
# never errors if none are present (the daemon-mode fallback handles that
# case via create_daemonized_runtime which calls --stop then --daemon).
restart_running_service() {
    local restarted=false

    if command -v systemctl >/dev/null 2>&1; then
        if sudo systemctl list-unit-files 2>/dev/null | grep -q '^igris\.service'; then
            info "Restarting systemd igris service to pick up the new binary..."
            if sudo systemctl restart igris 2>/dev/null; then
                restarted=true
            fi
        fi
    fi

    if [[ "$restarted" != "true" ]] && command -v rc-service >/dev/null 2>&1; then
        if sudo rc-service --exists igris 2>/dev/null; then
            info "Restarting OpenRC igris service to pick up the new binary..."
            if sudo rc-service igris restart 2>/dev/null; then
                restarted=true
            fi
        fi
    fi

    if [[ "$restarted" != "true" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
        if sudo launchctl print system/com.pipeops.igris >/dev/null 2>&1; then
            info "Restarting launchd com.pipeops.igris to pick up the new binary..."
            if sudo launchctl kickstart -k system/com.pipeops.igris >/dev/null 2>&1; then
                restarted=true
            fi
        fi
    fi

    # Self-daemonized fallback: if a PID file exists, --stop then --daemon.
    if [[ "$restarted" != "true" ]] && [[ -f /var/lib/igris/igris.pid ]]; then
        info "Restarting self-daemonized igris (PID file at /var/lib/igris/igris.pid)..."
        "${INSTALL_DIR}/${BINARY_NAME}" --stop --pid-file=/var/lib/igris/igris.pid >/dev/null 2>&1 || true
        sleep 1
        if [[ -r /etc/default/igris ]]; then
            sudo sh -c "set -a; . /etc/default/igris; set +a; '${INSTALL_DIR}/${BINARY_NAME}' --daemon --pid-file=/var/lib/igris/igris.pid --log-file=/var/log/igris/igris.log" || true
            restarted=true
        fi
    fi

    if [[ "$restarted" == "true" ]]; then
        success "igris service restarted with new binary."
    fi
}

missing_service_requirements() {
    local missing=()

    [[ -z "$(resolve_gateway_url)" ]] && missing+=("GATEWAY_URL/IGRIS_GATEWAY_URL")
    [[ -z "$(resolve_agent_token)" ]] && missing+=("TOKEN/IGRIS_AGENT_TOKEN")

    printf '%s' "${missing[*]:-}"
}

write_agent_env_file() {
    local env_file="$1"
    local gateway_url="$2"
    local token="$3"
    local workspace_id="$4"
    local tenant_id="$5"
    local org_id="$6"
    local mode="$7"
    local tmp_file

    sudo mkdir -p "$(dirname "$env_file")" || error "Failed to create directory for ${env_file}."
    tmp_file="$(mktemp)"
    chmod 600 "$tmp_file"
    {
        printf 'IGRIS_GATEWAY_URL=%s\n' "$gateway_url"
        printf 'IGRIS_AGENT_TOKEN=%s\n' "$token"
        [[ -n "$workspace_id" ]] && printf 'IGRIS_WORKSPACE_ID=%s\n' "$workspace_id"
        [[ -n "$tenant_id" ]] && printf 'IGRIS_TENANT_ID=%s\n' "$tenant_id"
        [[ -n "$org_id" ]] && printf 'IGRIS_ORG_ID=%s\n' "$org_id"
        printf 'IGRIS_MODE=%s\n' "$mode"
    } > "$tmp_file"
    sudo sh -c 'umask 077; cat "$1" > "$2"' sh "$tmp_file" "$env_file" || error "Failed to write ${env_file}."
    sudo chmod 600 "$env_file" || error "Failed to secure ${env_file}."
    rm -f "$tmp_file"
}

install_binary_file() {
    local source="$1"
    local target="$2"
    local target_dir

    target_dir="$(dirname "$target")"

    if [[ ! -d "$target_dir" ]]; then
        if ! mkdir -p "$target_dir" 2>/dev/null; then
            info "Requesting sudo access to create ${target_dir}..."
            sudo mkdir -p "$target_dir"
        fi
    fi

    if [[ -w "$target_dir" ]]; then
        mv "$source" "$target"
        chmod +x "$target"
    else
        info "Requesting sudo access to install to ${target_dir}..."
        sudo mv "$source" "$target"
        sudo chmod +x "$target"
    fi
}

is_nixos() {
    [[ -e /etc/NIXOS ]] || ([[ -r /etc/os-release ]] && grep -qi '^ID=nixos' /etc/os-release)
}

resolve_systemd_service_file() {
    if [[ -n "${IGRIS_SYSTEMD_SERVICE_FILE:-}" ]]; then
        printf '%s' "$IGRIS_SYSTEMD_SERVICE_FILE"
        return
    fi

    if [[ -n "${IGRIS_SYSTEMD_UNIT_DIR:-}" ]]; then
        printf '%s/igris.service' "${IGRIS_SYSTEMD_UNIT_DIR%/}"
        return
    fi

    if is_nixos; then
        printf '/run/systemd/system/igris.service'
        return
    fi

    printf '/etc/systemd/system/igris.service'
}

verify_systemd_service_active() {
    local deadline
    deadline=$((SECONDS + 10))

    while (( SECONDS < deadline )); do
        if sudo systemctl is-active --quiet igris; then
            success "Systemd service is active."
            return 0
        fi
        sleep 0.25
    done

    warn "Systemd accepted the unit, but igris is not active."
    warn "Status output:"
    sudo systemctl status igris --no-pager -l || true
    warn "Recent journal output:"
    sudo journalctl -u igris -n 80 --no-pager || true
    error "Igris service did not stay active. Review the status and journal output above."
}

verify_launchd_service_active() {
    local label="system/com.pipeops.igris"
    local print_output
    local deadline

    deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        if print_output="$(sudo launchctl print "$label" 2>&1)" && printf '%s' "$print_output" | grep -Eq 'state = running|pid ='; then
            success "launchd daemon is active."
            return 0
        fi
        sleep 0.25
    done

    warn "launchd accepted the plist, but com.pipeops.igris is not active."
    warn "launchctl print output:"
    printf '%s\n' "${print_output:-<no launchctl output>}" >&2
    if sudo test -f /var/log/igris/igris.err; then
        warn "Recent stderr log:"
        sudo tail -n 80 /var/log/igris/igris.err || true
    else
        warn "/var/log/igris/igris.err does not exist yet."
    fi
    error "Igris launchd daemon did not stay active. Review the launchctl and stderr output above."
}

openrc_status_is_started() {
    grep -Eiq 'status:[[:space:]]+started|status:[[:space:]]+running'
}

openrc_supervisor_running() {
    ps aux 2>/dev/null \
        | grep -F "supervise-daemon ${BINARY_NAME}" \
        | grep -F "${INSTALL_DIR}/${BINARY_NAME}" \
        | grep -v grep >/dev/null
}

openrc_agent_process_running() {
    ps aux 2>/dev/null \
        | grep -F "${INSTALL_DIR}/${BINARY_NAME}" \
        | grep -v "supervise-daemon" \
        | grep -v grep >/dev/null
}

stop_openrc_orphaned_agent_processes() {
    if ! openrc_agent_process_running || openrc_supervisor_running; then
        return 0
    fi

    warn "Detected an Igris process that is not supervised by OpenRC; stopping it before service restart."
    if command -v pkill >/dev/null 2>&1; then
        sudo pkill -TERM -f "^${INSTALL_DIR}/${BINARY_NAME}([[:space:]]|$)" || true
        sleep 2
        if openrc_agent_process_running && ! openrc_supervisor_running; then
            sudo pkill -KILL -f "^${INSTALL_DIR}/${BINARY_NAME}([[:space:]]|$)" || true
        fi
    else
        warn "pkill is unavailable; cannot automatically stop orphaned Igris process."
    fi
}

verify_openrc_service_active() {
    local deadline status_output
    deadline=$((SECONDS + 10))

    while (( SECONDS < deadline )); do
        status_output="$(sudo rc-service igris status 2>&1 || true)"
        if printf '%s\n' "$status_output" | grep -qi 'unsupervised'; then
            warn "OpenRC reports Igris as unsupervised, not daemon-managed."
            break
        fi
        if printf '%s\n' "$status_output" | openrc_status_is_started \
            && openrc_supervisor_running \
            && openrc_agent_process_running; then
            success "OpenRC service is active."
            return 0
        fi
        sleep 0.25
    done

    warn "OpenRC accepted the service, but igris is not supervised and active."
    warn "Status output:"
    sudo rc-service igris status || true
    warn "Process output:"
    ps aux | grep -E '[s]upervise-daemon.*igris|[i]gris' || true
    if sudo test -f /var/log/igris/igris.err; then
        warn "Recent stderr log:"
        sudo tail -n 80 /var/log/igris/igris.err || true
    else
        warn "/var/log/igris/igris.err does not exist yet."
    fi
    error "Igris OpenRC service did not stay supervised and active. Review the status, process list, and stderr output above."
}

# ─── Detect Platform ─────────────────────────────────────────────────────────
detect_platform() {
    local os arch

    # Detect OS
    case "$(uname -s)" in
        Linux*)   os="linux" ;;
        Darwin*)  os="darwin" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *)        error "Unsupported operating system: $(uname -s)" ;;
    esac

    # Detect architecture
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7)  arch="arm" ;;
        *)             error "Unsupported architecture: $(uname -m)" ;;
    esac

    echo "${os}-${arch}"
}

normalize_version() {
    local raw="${1:-}"

    raw="${raw#agent-v}"
    raw="${raw#igris-v}"
    raw="${raw#v}"
    printf '%s' "$raw"
}

release_tag_for_version() {
    local version
    version="$(normalize_version "$1")"
    printf 'v%s' "$version"
}

archive_arch_for_platform() {
    local platform="$1"
    local arch="${platform#*-}"

    case "$arch" in
        amd64) printf 'x86_64' ;;
        arm) printf 'armv7' ;;
        *) printf '%s' "$arch" ;;
    esac
}

archive_name_for_platform() {
    local platform="$1"
    local version
    local os
    local arch
    local format

    version="$(normalize_version "$2")"
    os="${platform%%-*}"
    arch="$(archive_arch_for_platform "$platform")"
    format="tar.gz"
    [[ "$os" == "windows" ]] && format="zip"

    printf '%s_%s_%s_%s.%s' "$BINARY_NAME" "$version" "$os" "$arch" "$format"
}

sha256_file() {
    local file="$1"

    if command -v sha256sum &> /dev/null; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

# ─── GitHub HTTP helpers (token-aware) ───────────────────────────────────────
# gh_api_get URL — GET a GitHub API URL to stdout, sending the auth token when
# set. Returns curl/wget's exit status.
gh_api_get() {
    local url="$1"
    if command -v curl &> /dev/null; then
        if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
            curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN_VALUE}" -H "Accept: application/vnd.github+json" "$url"
        else
            curl -fsSL -H "Accept: application/vnd.github+json" "$url"
        fi
    elif command -v wget &> /dev/null; then
        if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
            wget -qO- --header="Authorization: Bearer ${GITHUB_TOKEN_VALUE}" --header="Accept: application/vnd.github+json" "$url"
        else
            wget -qO- --header="Accept: application/vnd.github+json" "$url"
        fi
    fi
}

# gh_download_file URL OUT — download a release asset to OUT, sending the auth
# token when set. With curl the Authorization header is dropped on the cross-host
# redirect to the signed object URL (curl's default), so private assets download
# cleanly. Returns the downloader's exit status (caller handles failure).
gh_download_file() {
    local url="$1" out="$2"
    if command -v curl &> /dev/null; then
        if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
            curl -fL -H "Authorization: Bearer ${GITHUB_TOKEN_VALUE}" -H "Accept: application/octet-stream" -o "$out" "$url"
        else
            curl -fsSL -o "$out" "$url"
        fi
    elif command -v wget &> /dev/null; then
        if [[ -n "$GITHUB_TOKEN_VALUE" ]]; then
            wget -q --header="Authorization: Bearer ${GITHUB_TOKEN_VALUE}" --header="Accept: application/octet-stream" -O "$out" "$url"
        else
            wget -q -O "$out" "$url"
        fi
    else
        error "Neither curl nor wget found. Please install one of them."
    fi
}

# ─── Get Latest Version ──────────────────────────────────────────────────────
get_latest_version() {
    local latest=""
    local tag
    local candidate

    # Do not trust /releases/latest here. The public installer release repo has
    # historically marked newer-created but lower-semver tags as Latest. List
    # releases and choose the highest vMAJOR.MINOR.PATCH tag instead.
    while IFS= read -r tag; do
        candidate="$(normalize_version "$tag")"
        if [[ -z "$latest" || "$(compare_versions "$latest" "$candidate")" == "lt" ]]; then
            latest="$candidate"
        fi
    done < <(gh_api_get "https://api.github.com/repos/${REPO}/releases?per_page=100" 2>/dev/null \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' \
        | sed -E 's/.*"(v[0-9]+\.[0-9]+\.[0-9]+)".*/\1/' || true)

    if [[ -z "$latest" ]]; then
        if [[ -z "$GITHUB_TOKEN_VALUE" ]]; then
            warn "Could not resolve the latest Igris version from ${REPO}. Falling back to default: ${VERSION}"
        else
            warn "Could not resolve the latest Igris version from ${REPO} (check the token's access). Falling back to default: ${VERSION}"
        fi
        echo "$VERSION"
    else
        echo "$latest"
    fi
}

# ─── Download Binary ─────────────────────────────────────────────────────────
download_binary() {
    local platform="$1"
    local version
    local ext=""
    local filename
    local tag
    
    version="$(normalize_version "$2")"
    [[ "$platform" == windows-* ]] && ext=".exe"

    if [[ -n "${IGRIS_BINARY_BASE_URL:-}" ]]; then
        local raw_base="${IGRIS_BINARY_BASE_URL%/}"
        local raw_binary="${BINARY_NAME}-${platform}${ext}"
        local raw_url="${raw_base}/${raw_binary}"
        local raw_checksum_url="${raw_base}/checksums.txt"
        local agent_token
        local tmp_dir
        agent_token="$(resolve_agent_token)"
        refuse_insecure_artifact_token "$raw_base" "$agent_token"
        tmp_dir=$(mktemp -d)
        trap "rm -rf ${tmp_dir}" EXIT

        info "Downloading Igris Agent build for ${platform} from artifact server..."
        if command -v curl &> /dev/null; then
            if [[ -n "$agent_token" ]]; then
                curl -fsSL -H "Authorization: Bearer ${agent_token}" -o "${tmp_dir}/${raw_binary}" "$raw_url" || error "Failed to download: $raw_url"
                curl -fsSL -H "Authorization: Bearer ${agent_token}" -o "${tmp_dir}/checksums.txt" "$raw_checksum_url" || error "Failed to download checksum manifest: $raw_checksum_url"
            else
                curl -fsSL -o "${tmp_dir}/${raw_binary}" "$raw_url" || error "Failed to download: $raw_url"
                curl -fsSL -o "${tmp_dir}/checksums.txt" "$raw_checksum_url" || error "Failed to download checksum manifest: $raw_checksum_url"
            fi
        elif command -v wget &> /dev/null; then
            if [[ -n "$agent_token" ]]; then
                wget -q --header="Authorization: Bearer ${agent_token}" -O "${tmp_dir}/${raw_binary}" "$raw_url" || error "Failed to download: $raw_url"
                wget -q --header="Authorization: Bearer ${agent_token}" -O "${tmp_dir}/checksums.txt" "$raw_checksum_url" || error "Failed to download checksum manifest: $raw_checksum_url"
            else
                wget -q -O "${tmp_dir}/${raw_binary}" "$raw_url" || error "Failed to download: $raw_url"
                wget -q -O "${tmp_dir}/checksums.txt" "$raw_checksum_url" || error "Failed to download checksum manifest: $raw_checksum_url"
            fi
        else
            error "Neither curl nor wget found. Please install one of them."
        fi

        cd "${tmp_dir}"
        info "Verifying checksum..."
        local expected_sum
        expected_sum=$(awk -v f="$raw_binary" '($2 == f || $2 == "*" f) {print $1; exit}' checksums.txt)
        if [[ -z "$expected_sum" ]]; then
            error "Checksum entry for ${raw_binary} not found in ${raw_checksum_url}"
        fi
        local actual_sum
        actual_sum=$(sha256_file "$raw_binary")
        if [[ "$expected_sum" != "$actual_sum" ]]; then
            error "Checksum verification failed!"
        fi
        success "Checksum verified"

        local target="${INSTALL_DIR}/${BINARY_NAME}${ext}"
        info "Installing to ${target}..."
        install_binary_file "${tmp_dir}/${raw_binary}" "$target"

        success "Igris Agent installed successfully!"
        return
    fi

    filename="$(archive_name_for_platform "$platform" "$version")"
    tag="$(release_tag_for_version "$version")"

    local url="${RELEASES_URL}/download/${tag}/${filename}"
    local checksum_url="${RELEASES_URL}/download/${tag}/checksums.txt"
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf ${tmp_dir}" EXIT
    
    info "Downloading Igris Agent v${version} for ${platform}..."

    if command -v curl &> /dev/null || command -v wget &> /dev/null; then
        if ! gh_download_file "$url" "${tmp_dir}/${filename}"; then
            if [[ -z "$GITHUB_TOKEN_VALUE" ]]; then
                error "Failed to download ${url}
  Verify release ${tag} exists in ${REPO} and contains ${filename}.
  For explicit artifact-server installs, set IGRIS_BINARY_BASE_URL."
            else
                error "Failed to download ${url}
  A token was provided but the download failed — verify the token has access to ${REPO}
  and that release ${tag} contains ${filename}."
            fi
        fi
        gh_download_file "$checksum_url" "${tmp_dir}/checksums.txt" 2>/dev/null || error "Failed to download checksum manifest: $checksum_url"
    else
        error "Neither curl nor wget found. Please install one of them."
    fi
    
    cd "${tmp_dir}"

    # Verify the downloaded release archive against GoReleaser's checksums.txt.
    info "Verifying checksum..."
    local expected_sum
    expected_sum=$(awk -v f="$filename" '($2 == f || $2 == "*" f) {print $1; exit}' checksums.txt)
    if [[ -z "$expected_sum" ]]; then
        error "Checksum entry for ${filename} not found in ${checksum_url}"
    fi
    local actual_sum
    actual_sum=$(sha256_file "$filename")

    if [[ "$expected_sum" != "$actual_sum" ]]; then
        error "Checksum verification failed!"
    else
        success "Checksum verified"
    fi

    if [[ "$platform" == windows-* ]]; then
        unzip -q "$filename"
    else
        tar -xzf "$filename"
    fi
    
    # Install binary
    local binary="${BINARY_NAME}${ext}"
    local target="${INSTALL_DIR}/${BINARY_NAME}${ext}"
    
    info "Installing to ${target}..."
    install_binary_file "$binary" "$target"
    
    success "Igris Agent installed successfully!"
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
            info "Set GATEWAY_URL/TOKEN (or IGRIS_* equivalents) to auto-configure the service."
            return
        fi
    fi

    if [[ -z "$gateway_url" && "$auto_config" != "true" ]]; then
        read -p "Enter Halo Gateway URL (e.g., https://halo.example.com): " gateway_url
    fi

    if [[ -z "$token" && "$auto_config" != "true" ]]; then
        read -p "Enter Agent Enrollment Token: " token
    fi

    if [[ -z "$workspace_id" && "$auto_config" != "true" ]]; then
        read -p "Enter Workspace ID or UUID (optional for agent-install service keys): " workspace_id
    fi

    if [[ -z "$requested_mode" && "$auto_config" == "true" ]]; then
        requested_mode="host"
    elif [[ -z "$requested_mode" ]]; then
        read -p "Enter deployment mode / agent type (default: host): " requested_mode
    fi

    requested_mode="${requested_mode:-host}"
    mode="$(normalize_mode "$requested_mode")" || error "Unsupported deployment mode / agent type: ${requested_mode}"

    local service_file
    service_file="$(resolve_systemd_service_file)"
    local env_file="/etc/default/igris"
    local runtime_unit=false
    [[ "$service_file" == /run/* ]] && runtime_unit=true

    info "Writing agent environment to ${env_file}..."
    write_agent_env_file "$env_file" "$gateway_url" "$token" "$workspace_id" "$tenant_id" "$org_id" "$mode"

    info "Creating systemd service at ${service_file}..."
    sudo mkdir -p "$(dirname "$service_file")"

    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=Igris Security Agent
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${env_file}
ExecStart=${INSTALL_DIR}/${BINARY_NAME}
Restart=always
RestartSec=10
# Bound graceful shutdown to 15s so a re-install never blocks waiting for
# a wedged old process (e.g., one looping on a 401 from the gateway).
# Default is 90s, which produces a long-feeling 'install hung' on re-runs.
TimeoutStopSec=15
# Force SIGKILL the whole process group if SIGTERM doesn't drain in time.
KillMode=mixed
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

    # Create data directories
    sudo mkdir -p /var/lib/igris /var/log/igris
    
    # Reload, enable, and start immediately so one-line installs enroll right away.
    sudo systemctl daemon-reload
    if [[ "$runtime_unit" == "true" ]]; then
        warn "Using runtime systemd unit at ${service_file}; it will not persist after reboot. On NixOS, add a declarative service for permanent install."
    else
        sudo systemctl enable igris
    fi
    sudo systemctl restart igris
    verify_systemd_service_active
    
    success "Systemd service created and started!"
    IGRIS_SERVICE_STARTED="true"
    info "Check status with: sudo systemctl status igris"
}

# ─── Create OpenRC Service ───────────────────────────────────────────────────
create_openrc_service() {
    local auto_config="${1:-false}"

    if [[ "$(uname -s)" != "Linux" ]]; then
        return
    fi

    if ! command -v rc-service &> /dev/null || ! command -v rc-update &> /dev/null; then
        return
    fi

    if [[ ! -x /sbin/openrc-run ]]; then
        warn "OpenRC detected, but /sbin/openrc-run was not found; skipping OpenRC service setup."
        return
    fi

    if [[ "$auto_config" != "true" ]]; then
        read -p "Would you like to install Igris as an OpenRC service? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    else
        info "Detected bootstrap environment; creating an OpenRC service..."
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
            warn "Skipping OpenRC service setup: missing required env vars: ${missing}"
            info "Set GATEWAY_URL/TOKEN (or IGRIS_* equivalents) to auto-configure the service."
            return
        fi
    fi

    if [[ -z "$gateway_url" && "$auto_config" != "true" ]]; then
        read -p "Enter Halo Gateway URL (e.g., https://halo.example.com): " gateway_url
    fi

    if [[ -z "$token" && "$auto_config" != "true" ]]; then
        read -p "Enter Agent Enrollment Token: " token
    fi

    if [[ -z "$workspace_id" && "$auto_config" != "true" ]]; then
        read -p "Enter Workspace ID or UUID (optional for agent-install service keys): " workspace_id
    fi

    if [[ -z "$requested_mode" && "$auto_config" == "true" ]]; then
        requested_mode="host"
    elif [[ -z "$requested_mode" ]]; then
        read -p "Enter deployment mode / agent type (default: host): " requested_mode
    fi

    requested_mode="${requested_mode:-host}"
    mode="$(normalize_mode "$requested_mode")" || error "Unsupported deployment mode / agent type: ${requested_mode}"

    local env_file="/etc/conf.d/igris"
    local service_file="/etc/init.d/igris"

    info "Writing agent environment to ${env_file}..."
    write_agent_env_file "$env_file" "$gateway_url" "$token" "$workspace_id" "$tenant_id" "$org_id" "$mode"

    info "Creating OpenRC service at ${service_file}..."
    sudo mkdir -p /etc/init.d /etc/conf.d /var/lib/igris /var/log/igris
    sudo chmod 700 /var/lib/igris
    sudo chmod 755 /var/log/igris

    sudo tee "$service_file" > /dev/null << EOF
#!/sbin/openrc-run

name="Igris Security Agent"
description="Igris Security Agent"

supervisor="supervise-daemon"
command="/bin/sh"
command_args="-c 'set -a; . ${env_file}; set +a; exec ${INSTALL_DIR}/${BINARY_NAME}'"
directory="/var/lib/igris"
respawn_delay=5
respawn_max=0
output_log="/var/log/igris/igris.log"
error_log="/var/log/igris/igris.err"

depend() {
    need net
}

start_pre() {
    checkpath -d -m 0750 /var/lib/igris
    checkpath -d -m 0755 /var/log/igris
}
EOF
    sudo chmod 755 "$service_file"

    sudo rc-update add igris default
    sudo rc-service igris stop || true
    stop_openrc_orphaned_agent_processes
    sudo rc-service igris start
    verify_openrc_service_active

    success "OpenRC service created and started!"
    IGRIS_SERVICE_STARTED="true"
    info "Check status with: sudo rc-service igris status"
    info "Check logs with: sudo tail -f /var/log/igris/igris.log /var/log/igris/igris.err"
}

# ─── Create launchd Service ──────────────────────────────────────────────────
create_launchd_service() {
    local auto_config="${1:-false}"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        return
    fi

    if [[ "$auto_config" != "true" ]]; then
        read -p "Would you like to install Igris as a launchd daemon? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    else
        info "Detected bootstrap environment; creating a launchd daemon..."
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
            warn "Skipping launchd setup: missing required env vars: ${missing}"
            info "Set GATEWAY_URL/TOKEN (or IGRIS_* equivalents) to auto-configure the daemon."
            return
        fi
    fi

    if [[ -z "$gateway_url" && "$auto_config" != "true" ]]; then
        read -p "Enter Halo Gateway URL (e.g., https://halo.example.com): " gateway_url
    fi

    if [[ -z "$token" && "$auto_config" != "true" ]]; then
        read -p "Enter Agent Enrollment Token: " token
    fi

    if [[ -z "$workspace_id" && "$auto_config" != "true" ]]; then
        read -p "Enter Workspace ID or UUID (optional for agent-install service keys): " workspace_id
    fi

    if [[ -z "$requested_mode" && "$auto_config" == "true" ]]; then
        requested_mode="host"
    elif [[ -z "$requested_mode" ]]; then
        read -p "Enter deployment mode / agent type (default: host): " requested_mode
    fi

    requested_mode="${requested_mode:-host}"
    mode="$(normalize_mode "$requested_mode")" || error "Unsupported deployment mode / agent type: ${requested_mode}"

    local env_file="/Library/Application Support/Igris/igris.env"
    local plist_file="/Library/LaunchDaemons/com.pipeops.igris.plist"

    ensure_sudo_available "install Igris as a macOS launchd daemon"

    info "Writing agent environment to ${env_file}..."
    write_agent_env_file "$env_file" "$gateway_url" "$token" "$workspace_id" "$tenant_id" "$org_id" "$mode"

    info "Creating launchd daemon..."
    sudo mkdir -p /var/lib/igris /var/log/igris || error "Failed to create Igris runtime directories."
    sudo chmod 700 /var/lib/igris || error "Failed to secure /var/lib/igris."
    sudo chmod 755 /var/log/igris || error "Failed to secure /var/log/igris."

    if ! sudo tee "$plist_file" > /dev/null << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pipeops.igris</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>set -a; . "${env_file}"; set +a; exec "${INSTALL_DIR}/${BINARY_NAME}"</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>WorkingDirectory</key>
    <string>/var/lib/igris</string>
    <key>StandardOutPath</key>
    <string>/var/log/igris/igris.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/igris/igris.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF
    then
        error "Failed to write ${plist_file}."
    fi
    sudo chown root:wheel "$plist_file" || error "Failed to set owner on ${plist_file}."
    sudo chmod 644 "$plist_file" || error "Failed to set permissions on ${plist_file}."

    sudo launchctl bootout system "$plist_file" >/dev/null 2>&1 || true
    local launchctl_output
    if ! launchctl_output="$(sudo launchctl bootstrap system "$plist_file" 2>&1)"; then
        error "launchctl bootstrap failed: ${launchctl_output}"
    fi
    if ! launchctl_output="$(sudo launchctl enable system/com.pipeops.igris 2>&1)"; then
        error "launchctl enable failed: ${launchctl_output}"
    fi
    if ! launchctl_output="$(sudo launchctl kickstart -k system/com.pipeops.igris 2>&1)"; then
        error "launchctl kickstart failed: ${launchctl_output}"
    fi
    verify_launchd_service_active

    success "launchd daemon created!"
    IGRIS_SERVICE_STARTED="true"
    info "Check status with: sudo launchctl print system/com.pipeops.igris"
}

# ─── Print Usage ─────────────────────────────────────────────────────────────
print_usage() {
    cat << EOF

${GREEN}Igris Agent installed successfully!${NC}

${BLUE}Quick Start:${NC}
  export IGRIS_GATEWAY_URL=https://your-halo-gateway.com
  export IGRIS_AGENT_TOKEN=YOUR_TOKEN
  ${BINARY_NAME}

${BLUE}Shorthand Aliases:${NC}
  GATEWAY_URL / IGRIS_GATEWAY_URL
  TOKEN / IGRIS_AGENT_TOKEN
  WORKSPACE_ID / IGRIS_WORKSPACE_ID (optional workspace override)
  MODE / IGRIS_MODE

${BLUE}Examples:${NC}
  # Basic enrollment
  GATEWAY_URL=https://halo.example.com TOKEN=<agent-install-service-key> ${BINARY_NAME}

  # Agent-type aliases are normalized automatically
  GATEWAY_URL=https://halo.example.com TOKEN=<bootstrap-jwt-or-api-key> \
  WORKSPACE_ID=<workspace-uuid> MODE=daemonset ${BINARY_NAME}

  # Install + auto-configure a systemd/launchd service from the one-liner
  curl -fsSL https://get.pipeops.dev/igris.sh | \
    GATEWAY_URL=https://halo.example.com TOKEN=<agent-install-service-key> MODE=host bash

${BLUE}Documentation:${NC}
  ${GITHUB_URL}

EOF
}

# ─── Create Self-Daemonized Runtime (no service manager) ─────────────────────
# Fallback used when systemd, OpenRC, and launchd are all absent (minimal
# containers, LXC without an init manager, distroless-ish images that ship a
# shell, etc). Uses igris' built-in --daemon mode so the agent forks into the
# background, writes a PID file, and keeps running after this installer exits.
#
# Also drops a small SysV-style /etc/init.d/igris wrapper that calls
# `igris --daemon` / `igris --stop` so a reboot picks the agent back up if
# /etc/init.d is scanned by the host's init (BusyBox init, Alpine pre-OpenRC,
# some Docker-in-Docker setups). When even that's missing operators get a
# clear "run on boot via your own mechanism" message instead of a silent gap.
create_daemonized_runtime() {
    local auto_config="${1:-false}"

    # Only meaningful on Unix-like hosts (Windows uses the SCM path).
    if [[ "$(uname -s)" == "MINGW"* || "$(uname -s)" == "CYGWIN"* || "$(uname -s)" == "MSYS"* ]]; then
        return
    fi

    if [[ "$auto_config" != "true" ]]; then
        read -p "No service manager detected. Run Igris in self-daemonized mode? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return
        fi
    else
        info "No systemd/OpenRC/launchd detected — falling back to igris --daemon mode."
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
            warn "Skipping daemonized runtime: missing required env vars: ${missing}"
            info "Set GATEWAY_URL/TOKEN (or IGRIS_* equivalents) to auto-start the daemon."
            return
        fi
    fi

    requested_mode="${requested_mode:-host}"
    mode="$(normalize_mode "$requested_mode")" || error "Unsupported deployment mode / agent type: ${requested_mode}"

    local env_file="/etc/default/igris"
    local pid_file="/var/lib/igris/igris.pid"
    local log_file="/var/log/igris/igris.log"
    local init_script="/etc/init.d/igris"

    # Use sudo only when not already root — minimal containers often have no sudo.
    local SUDO=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            warn "Not root and no sudo available — cannot create system paths. Try re-running as root."
            return
        fi
    fi

    info "Writing agent environment to ${env_file}..."
    write_agent_env_file "$env_file" "$gateway_url" "$token" "$workspace_id" "$tenant_id" "$org_id" "$mode"

    $SUDO mkdir -p /var/lib/igris /var/log/igris
    $SUDO chmod 700 /var/lib/igris 2>/dev/null || true
    $SUDO chmod 755 /var/log/igris 2>/dev/null || true

    # Best-effort SysV init script so the daemon comes back after reboot if
    # /etc/init.d is honoured. Harmless if no init scans it.
    if [[ -d /etc/init.d ]] || $SUDO mkdir -p /etc/init.d 2>/dev/null; then
        info "Writing SysV init script to ${init_script}..."
        $SUDO tee "$init_script" > /dev/null << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          igris
# Required-Start:    \$network \$remote_fs
# Required-Stop:     \$network \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Igris Security Agent (self-daemonized)
### END INIT INFO

ENV_FILE="${env_file}"
BIN="${INSTALL_DIR}/${BINARY_NAME}"
PID_FILE="${pid_file}"
LOG_FILE="${log_file}"

[ -r "\$ENV_FILE" ] && . "\$ENV_FILE"
export \$(grep -v '^#' "\$ENV_FILE" 2>/dev/null | cut -d= -f1) 2>/dev/null

case "\$1" in
    start)
        "\$BIN" --daemon --pid-file="\$PID_FILE" --log-file="\$LOG_FILE"
        ;;
    stop)
        "\$BIN" --stop --pid-file="\$PID_FILE"
        ;;
    status)
        "\$BIN" --status --pid-file="\$PID_FILE"
        ;;
    restart)
        "\$BIN" --stop --pid-file="\$PID_FILE"
        sleep 1
        "\$BIN" --daemon --pid-file="\$PID_FILE" --log-file="\$LOG_FILE"
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
exit 0
EOF
        $SUDO chmod 755 "$init_script"
    fi

    # Stop any previously-running daemon so re-runs are idempotent.
    "${INSTALL_DIR}/${BINARY_NAME}" --stop --pid-file="$pid_file" >/dev/null 2>&1 || true

    info "Starting igris --daemon (pid_file=${pid_file}, log_file=${log_file})..."
    # Source env file then exec the daemon. set -a exports everything in env_file.
    if ! $SUDO sh -c "set -a; . '${env_file}'; set +a; '${INSTALL_DIR}/${BINARY_NAME}' --daemon --pid-file='${pid_file}' --log-file='${log_file}'"; then
        warn "igris --daemon failed to start. Check ${log_file} for details."
        return
    fi

    # Verify the PID file landed and the process is alive.
    sleep 1
    if "${INSTALL_DIR}/${BINARY_NAME}" --status --pid-file="$pid_file" >/dev/null 2>&1; then
        success "Igris running in self-daemonized mode."
        IGRIS_SERVICE_STARTED="true"
        info "Check status: ${INSTALL_DIR}/${BINARY_NAME} --status --pid-file=${pid_file}"
        info "Stop daemon:  ${INSTALL_DIR}/${BINARY_NAME} --stop   --pid-file=${pid_file}"
        info "Logs:         ${log_file}"
    else
        warn "Daemon start reported success but --status shows no running process. See ${log_file}."
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           Igris Agent Installer                               ║"
    echo "║           Autonomous Security for Every Environment           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Detect platform
    local platform
    platform=$(detect_platform)
    info "Detected platform: ${platform}"
    
    # Get version
    if [[ -n "${IGRIS_BINARY_BASE_URL:-}" && -z "$REQUESTED_VERSION" ]]; then
        VERSION="local"
    elif [[ -z "$REQUESTED_VERSION" ]]; then
        VERSION=$(get_latest_version)
    fi
    info "Version: ${VERSION}"
    
    # Check if already installed, and decide whether to update, reinstall,
    # or skip based on a semver compare of installed vs target.
    local needs_install="true"
    local update_action=""   # "install" | "upgrade" | "downgrade" | "reinstall" | "skip"
    if command -v "$BINARY_NAME" &> /dev/null; then
        local current_version
        current_version=$("$BINARY_NAME" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        local target_version="${VERSION#v}"
        target_version="${target_version#agent-}"

        if [[ "$current_version" == "unknown" || "$target_version" == "local" ]]; then
            # Unable to parse — fall back to the old prompt-or-bootstrap path.
            warn "Igris is already installed but version detection was inconclusive (current=${current_version}, target=${VERSION})."
            update_action="reinstall"
        else
            local cmp
            cmp=$(compare_versions "$current_version" "$target_version")
            case "$cmp" in
                lt)
                    info "Update available: ${current_version} → ${target_version}"
                    update_action="upgrade"
                    ;;
                eq)
                    success "Igris is already at the latest version (${current_version}). Nothing to do."
                    update_action="skip"
                    ;;
                gt)
                    warn "Installed version (${current_version}) is NEWER than the target (${target_version}). Skipping to avoid downgrade — set IGRIS_VERSION explicitly to force."
                    update_action="skip"
                    ;;
            esac
        fi

        case "$update_action" in
            skip)
                needs_install="false"
                ;;
            upgrade)
                # Non-interactive bootstrap auto-upgrades; interactive
                # prompts so an operator can opt out.
                if [[ -t 0 ]]; then
                    read -p "Install update ${current_version} → ${target_version}? [Y/n] " -n 1 -r
                    echo
                    if [[ -n "$REPLY" && ! $REPLY =~ ^[Yy]$ ]]; then
                        info "Update cancelled."
                        exit 0
                    fi
                else
                    info "Non-interactive run; auto-upgrading ${current_version} → ${target_version}."
                fi
                ;;
            reinstall)
                # NOTE: `[[ has_bootstrap_env ]]` would treat the function
                # name as a non-empty string literal — always truthy —
                # never invoking the function. To actually call the
                # function and short-circuit on its return value, the AND
                # must be outside `[[ ... ]]`.
                if [[ ! -t 0 ]] && has_bootstrap_env; then
                    info "Non-interactive bootstrap detected; reinstalling automatically."
                else
                    read -p "Do you want to reinstall? [y/N] " -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        info "Installation cancelled."
                        exit 0
                    fi
                fi
                ;;
        esac
    fi

    if [[ "$needs_install" == "true" ]]; then
        # Download and install
        download_binary "$platform" "$VERSION"
    else
        if has_bootstrap_env; then
            info "Igris binary is already installed; ensuring the background service is configured."
        else
            # Up-to-date path: exit cleanly without touching the service config
            # or re-running create_*_service (which would needlessly bounce
            # a healthy daemon and re-prompt the operator for env vars).
            info "No changes made — re-run with IGRIS_VERSION=<x.y.z> to force a specific version."
            exit 0
        fi
    fi

    # Verify installation
    if command -v "$BINARY_NAME" &> /dev/null; then
        local installed_version
        installed_version=$("$BINARY_NAME" --version 2>/dev/null || echo "installed")
        success "Verified: ${BINARY_NAME} ${installed_version}"
    fi

    # On the upgrade path the binary has been replaced in place. If a
    # service manager is already running igris with the old binary, bounce
    # it now so the new binary actually takes effect. The create_*_service
    # functions below handle the fresh-install case (they call systemctl
    # restart at the end); restart_running_service handles the upgrade
    # case where create_*_service won't run (e.g. operator hit `n` to the
    # service prompt on the original install, or the systemd unit was
    # created out-of-band).
    if [[ "$update_action" == "upgrade" ]]; then
        restart_running_service
    fi

    # Create a service when supported. In curl|bash flows stdin is not a TTY,
    # so auto-configure when bootstrap env vars are provided. When none of the
    # standard service managers are available (minimal containers, LXC without
    # an init manager, etc), fall back to igris' built-in --daemon mode so the
    # agent still backgrounds itself instead of leaving the operator stranded.
    if [[ -t 0 ]]; then
        create_systemd_service
        create_openrc_service
        create_launchd_service
        if [[ "$IGRIS_SERVICE_STARTED" != "true" ]]; then
            create_daemonized_runtime
        fi
    elif has_bootstrap_env; then
        create_systemd_service true
        create_openrc_service true
        create_launchd_service true

        if [[ "$IGRIS_SERVICE_STARTED" != "true" ]]; then
            create_daemonized_runtime true
        fi

        if [[ "$IGRIS_SERVICE_STARTED" != "true" ]]; then
            warn "Igris binary was installed, but it could not be started in the background on this host."
            warn "No supported service manager (systemd, OpenRC, launchd) and --daemon mode also failed."
            warn "Inspect /var/log/igris/igris.log (if present) or run '${INSTALL_DIR}/${BINARY_NAME}' directly to see startup errors."
            exit 1
        fi
    fi
    
    # Print usage
    print_usage
}

if [[ "${IGRIS_INSTALLER_SKIP_MAIN:-}" != "1" ]]; then
    main "$@"
fi
