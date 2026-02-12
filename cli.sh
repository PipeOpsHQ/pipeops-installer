#!/bin/sh
set -eu

# PipeOps CLI installer
# Designed for maximum portability: works on GNU/Linux, Alpine/BusyBox,
# Proxmox LXC containers, macOS, and minimal environments.
#
# Customize via env vars:
#   GH_REPO     - GitHub repo (default: pipeopshq/pipeops-cli)
#   BINARY_NAME - Binary name inside the release (default: pipeops)
#   VERSION     - Tag like v1.2.3; default "latest"
#   PREFIX      - Install prefix; default ~/.local (or /usr/local when root)
#   ASSET_EXT   - Archive/file extension; default tar.gz
#   ASSET_FILE  - Override complete asset filename
#   VERIFY      - auto|strict|0 (default: auto). Verify checksums if available; strict fails if missing/mismatch
#   CHECKSUMS_ASSET - Override checksums asset file name (e.g., checksums.txt)
#   CHECKSUMS_URL   - Override full checksums URL

GH_REPO=${GH_REPO:-pipeopshq/pipeops-cli}
BINARY_NAME=${BINARY_NAME:-pipeops}
# Prefix used in release asset filenames (defaults to the real naming: pipeops-cli_...)
ASSET_PREFIX=${ASSET_PREFIX:-pipeops-cli}
VERSION=${VERSION:-latest}
ASSET_EXT=${ASSET_EXT:-tar.gz}
VERIFY=${VERIFY:-auto}

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have_cmd "$1" || die "Missing required command: $1"; }

detect_os() {
  case "$(uname -s)" in
    Linux)  echo Linux ;;
    Darwin) echo Darwin ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    arm64|aarch64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686) echo 386 ;;
    *) echo "$(uname -m)" ; warn "Unknown arch '$(uname -m)'; attempting as-is" ;;
  esac
}

make_tmpdir() {
  # mktemp -d is POSIX-ish and works on both GNU and BusyBox.
  # The -t flag has different semantics across implementations, so avoid it.
  mktemp -d 2>/dev/null || mktemp -d -t 'pipeops.XXXXXX' 2>/dev/null || {
    # Last-resort fallback for truly minimal systems
    _td="/tmp/pipeops-install-$$"
    mkdir -p "$_td"
    echo "$_td"
  }
}

# Try to download an asset. Returns 0 on success.
# Usage: try_download <url> <output_path>
try_download() {
  curl -fL --retry 3 --connect-timeout 10 -o "$2" "$1" 2>/dev/null
}

# Compare semantic versions (returns 0 if v1 >= v2, 1 otherwise)
# POSIX sh compatible - no arrays or bashisms
semver_gte() {
  _sv1="$1" _sv2="$2"
  # Strip leading 'v' if present
  _sv1="${_sv1#v}"; _sv2="${_sv2#v}"

  # Split on dots and compare major.minor.patch
  _old_ifs="$IFS"; IFS='.'
  set -- $_sv1; _maj1="${1:-0}"; _min1="${2:-0}"; _pat1="${3:-0}"
  set -- $_sv2; _maj2="${1:-0}"; _min2="${2:-0}"; _pat2="${3:-0}"
  IFS="$_old_ifs"

  # Strip any pre-release suffix (e.g., -beta, -rc1)
  _maj1="${_maj1%%-*}"; _min1="${_min1%%-*}"; _pat1="${_pat1%%-*}"
  _maj2="${_maj2%%-*}"; _min2="${_min2%%-*}"; _pat2="${_pat2%%-*}"

  if [ "$_maj1" -gt "$_maj2" ] 2>/dev/null; then return 0; fi
  if [ "$_maj1" -lt "$_maj2" ] 2>/dev/null; then return 1; fi
  if [ "$_min1" -gt "$_min2" ] 2>/dev/null; then return 0; fi
  if [ "$_min1" -lt "$_min2" ] 2>/dev/null; then return 1; fi
  if [ "$_pat1" -gt "$_pat2" ] 2>/dev/null; then return 0; fi
  if [ "$_pat1" -lt "$_pat2" ] 2>/dev/null; then return 1; fi
  return 0
}

# Get the latest release tag by semantic version from GitHub API
get_latest_version() {
  _glv_repo="$1"
  need_cmd grep
  need_cmd sed

  # Fetch all release tags from GitHub API (up to 100 releases)
  _glv_tags_url="https://api.github.com/repos/${_glv_repo}/releases?per_page=100"

  # Try to fetch releases
  if ! _glv_releases=$(curl -fsSL "$_glv_tags_url" 2>/dev/null); then
    warn "Failed to fetch releases from API, falling back to /releases/latest"
    echo "latest"
    return
  fi

  # Check if we got an empty response or API error
  if [ -z "$_glv_releases" ] || echo "$_glv_releases" | grep -Eq '"message".*"(rate limit|API rate limit|Not Found|Forbidden)"'; then
    warn "GitHub API unavailable or rate limited, falling back to /releases/latest"
    echo "latest"
    return
  fi

  # Parse JSON manually: extract non-prerelease tags
  # Extract all tag_name and prerelease pairs
  _glv_tags_list=$(echo "$_glv_releases" | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"|"prerelease"[[:space:]]*:[[:space:]]*(true|false)' | paste -d' ' - -)

  _glv_latest_tag=""
  _glv_current_tag=""
  _glv_is_prerelease=""

  echo "$_glv_tags_list" | while IFS= read -r _glv_line; do
    if echo "$_glv_line" | grep -q '"tag_name"'; then
      _glv_current_tag=$(echo "$_glv_line" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    fi
    if echo "$_glv_line" | grep -q '"prerelease"'; then
      _glv_is_prerelease=$(echo "$_glv_line" | sed -n 's/.*"prerelease"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')

      # Process the pair
      if [ -n "$_glv_current_tag" ] && [ "$_glv_is_prerelease" = "false" ]; then
        if [ -z "$_glv_latest_tag" ] || semver_gte "$_glv_current_tag" "$_glv_latest_tag"; then
          _glv_latest_tag="$_glv_current_tag"
        fi
      fi
      _glv_current_tag=""
      _glv_is_prerelease=""
    fi
  done

  # The while loop above runs in a subshell due to the pipe, so _glv_latest_tag
  # won't be visible here. Use a different approach: write to a temp file.
  _glv_result_file=$(make_tmpdir)/latest_version
  echo "$_glv_tags_list" | {
    _glv_latest_tag=""
    _glv_current_tag=""
    while IFS= read -r _glv_line; do
      if echo "$_glv_line" | grep -q '"tag_name"'; then
        _glv_current_tag=$(echo "$_glv_line" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      fi
      if echo "$_glv_line" | grep -q '"prerelease"'; then
        _glv_is_prerelease=$(echo "$_glv_line" | sed -n 's/.*"prerelease"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p')
        if [ -n "$_glv_current_tag" ] && [ "$_glv_is_prerelease" = "false" ]; then
          if [ -z "$_glv_latest_tag" ] || semver_gte "$_glv_current_tag" "$_glv_latest_tag"; then
            _glv_latest_tag="$_glv_current_tag"
          fi
        fi
        _glv_current_tag=""
      fi
    done
    echo "$_glv_latest_tag"
  } > "$_glv_result_file"

  _glv_latest_tag=$(cat "$_glv_result_file" 2>/dev/null)
  rm -f "$_glv_result_file"

  if [ -n "$_glv_latest_tag" ]; then
    echo "$_glv_latest_tag"
  else
    echo "latest"
  fi
}

main() {
  need_cmd curl
  need_cmd uname
  need_cmd mkdir
  need_cmd chmod
  need_cmd printf

  os=$(detect_os)
  arch=$(detect_arch)

  # Resolve version
  resolved_version=""
  if [ "${VERSION}" = "latest" ]; then
    info "Resolving latest version..."
    resolved_version=$(get_latest_version "$GH_REPO")
    if [ "$resolved_version" = "latest" ]; then
      # Fallback to GitHub's latest redirect
      base_url="https://github.com/${GH_REPO}/releases/latest/download"
      info "Using GitHub's latest release"
    else
      base_url="https://github.com/${GH_REPO}/releases/download/${resolved_version}"
      info "Detected latest version: ${resolved_version}"
    fi
  else
    resolved_version="$VERSION"
    base_url="https://github.com/${GH_REPO}/releases/download/${VERSION}"
  fi

  # Resolve asset filename; try common naming patterns until one downloads.
  # We avoid bash arrays for POSIX sh compatibility.
  asset_file=""
  if [ -n "${ASSET_FILE:-}" ]; then
    asset_file="${ASSET_FILE}"
  fi

  # Install prefix
  dest_dir=""
  if [ -n "${PREFIX:-}" ]; then
    dest_dir="${PREFIX%/}/bin"
  else
    if [ "$(id -u)" -eq 0 ]; then
      dest_dir="/usr/local/bin"
    else
      dest_dir="$HOME/.local/bin"
    fi
  fi

  sudo_cmd=""
  if [ ! -w "$dest_dir" ] 2>/dev/null; then
    if have_cmd sudo; then sudo_cmd="sudo -E"; fi
  fi

  info "OS=${os} ARCH=${arch}"

  tdir=$(make_tmpdir)
  trap 'rm -rf "${tdir:-}"' EXIT
  mkdir -p "$tdir"

  file_path=""
  download_url=""

  if [ -n "${asset_file}" ]; then
    # Explicit asset path provided
    download_url="${base_url}/${asset_file}"
    file_path="${tdir}/${asset_file##*/}"
    info "Downloading ${download_url}"
    try_download "$download_url" "$file_path" || die "Download failed: $download_url"
  else
    # Try candidate filenames sequentially (no arrays needed)
    ok=0
    tried=""
    for af in \
      "${ASSET_PREFIX}_${os}_${arch}.${ASSET_EXT}" \
      "${BINARY_NAME}_${os}_${arch}.${ASSET_EXT}" \
      "${BINARY_NAME}-cli_${os}_${arch}.${ASSET_EXT}" \
    ; do
      download_url="${base_url}/${af}"
      file_path="${tdir}/${af}"
      info "Downloading ${download_url}"
      if try_download "$download_url" "$file_path"; then
        asset_file="$af"
        ok=1
        break
      else
        tried="${tried}
  - ${download_url}"
      fi
    done
    [ "$ok" = 1 ] || die "Download failed. Tried:${tried}"
  fi

  try_verify_checksum "$file_path" "$download_url" "$base_url" "$asset_file"

  src_bin=""
  if [ "${ASSET_EXT}" = "tar.gz" ] || tar -tzf "$file_path" >/dev/null 2>&1; then
    need_cmd tar
    info "Extracting archive"
    tar -xzf "$file_path" -C "$tdir"
    # Try to find the binary by name
    if [ -f "${tdir}/${BINARY_NAME}" ]; then
      src_bin="${tdir}/${BINARY_NAME}"
    else
      # Use find with numeric permission mode for BusyBox compatibility
      # (-perm -u+x is GNU-only; -perm -100 is POSIX)
      src_bin=$(find "$tdir" -type f -name "${BINARY_NAME}" -perm -100 2>/dev/null | head -n1) || true
    fi
  else
    # treat as a raw binary
    src_bin="$file_path"
  fi

  [ -n "$src_bin" ] || die "Could not locate installed binary in asset. Check BINARY_NAME/ASSET_FILE."
  chmod +x "$src_bin" || true

  info "Installing to ${dest_dir}"
  ${sudo_cmd} mkdir -p "$dest_dir"
  if have_cmd install; then
    ${sudo_cmd} install -m 0755 "$src_bin" "${dest_dir}/${BINARY_NAME}"
  else
    ${sudo_cmd} cp "$src_bin" "${dest_dir}/${BINARY_NAME}"
    ${sudo_cmd} chmod 0755 "${dest_dir}/${BINARY_NAME}"
  fi

  info "Installed ${BINARY_NAME} -> ${dest_dir}/${BINARY_NAME}"
  case ":$PATH:" in
    *:"$dest_dir":*)
      ;;
    *)
      warn "${dest_dir} is not in PATH. Add this to your shell profile:"
      printf '\n    export PATH="%s:$PATH"\n\n' "$dest_dir"
      ;;
  esac
}

try_verify_checksum() {
  # Best-effort checksum verification. Modes:
  #   VERIFY=auto (default): verify if checksums found; warn on failure/missing
  #   VERIFY=strict: must verify; die on failure/missing
  #   VERIFY=0: skip verification
  _file_path="$1"
  _download_url="$2"
  _base_url="$3"
  _asset_file="$4"
  _mode="$VERIFY"

  case "$_mode" in
    0|false|no) return 0 ;;
    auto|strict) ;;
    *) _mode=auto ;;
  esac

  # Build list of checksum URLs to try (space-separated, no arrays)
  _sum_urls=""
  if [ -n "${CHECKSUMS_URL:-}" ]; then
    _sum_urls="${CHECKSUMS_URL}"
  fi
  if [ -n "${CHECKSUMS_ASSET:-}" ]; then
    _sum_urls="${_sum_urls} ${_base_url}/${CHECKSUMS_ASSET}"
  fi
  # common patterns
  _sum_urls="${_sum_urls} ${_download_url}.sha256"
  _sum_urls="${_sum_urls} ${_download_url}.sha256sum"
  _sum_urls="${_sum_urls} ${_download_url}.sha256.txt"
  _sum_urls="${_sum_urls} ${_base_url}/SHA256SUMS"
  _sum_urls="${_sum_urls} ${_base_url}/SHA256SUMS.txt"
  _sum_urls="${_sum_urls} ${_base_url}/checksums.txt"

  _basename="${_asset_file##*/}"
  _tmp_dir="$(dirname "$_file_path")"
  _ok=0

  for _url in $_sum_urls; do
    _sum_file="${_tmp_dir}/checksums"
    if curl -fsL -o "$_sum_file" "$_url" 2>/dev/null; then
      if do_verify_with_file "$_file_path" "$_sum_file" "$_basename"; then
        info "Checksum verified using ${_url##*/}"
        _ok=1
        break
      fi
    fi
  done

  if [ "$_ok" = 1 ]; then
    return 0
  fi

  if [ "$_mode" = strict ]; then
    die "Checksum verification failed or checksums not found"
  else
    warn "Could not verify checksum (no checksums found or mismatch)"
  fi
}

do_verify_with_file() {
  # Accepts either:
  #   - lines like: <hash>  <filename>
  #   - single hash only (we pair it with the asset filename)
  _vf_file_path="$1"
  _vf_sum_file="$2"
  _vf_basename="$3"

  if ! have_cmd sha256sum && ! have_cmd shasum; then
    warn "No sha256 verifier found (sha256sum/shasum). Skipping verification."
    return 1
  fi

  # Escape dots in basename for grep pattern
  _vf_pattern=$(printf '%s' "$_vf_basename" | sed 's/\./\\./g')

  # Does the checksum file contain an entry for our basename?
  if grep -Ei "$_vf_pattern" "$_vf_sum_file" >/dev/null 2>&1; then
    if have_cmd sha256sum; then
      (cd "$(dirname "$_vf_file_path")" && sha256sum -c "${_vf_sum_file}" --ignore-missing >/dev/null 2>&1)
    else
      # shasum fallback (macOS, some BSDs)
      _expected=$(grep -Ei "$_vf_pattern" "$_vf_sum_file" | awk '{print $1}' | head -n1)
      [ -n "$_expected" ] || return 1
      _actual=$(shasum -a 256 "$_vf_file_path" | awk '{print $1}')
      [ "$_expected" = "$_actual" ]
    fi
    return $?
  fi

  # Try single-hash file (64-hex chars only)
  if grep -Eq '^[a-fA-F0-9]{64}$' "$_vf_sum_file" 2>/dev/null; then
    _expected=$(head -n1 "$_vf_sum_file" | tr -d '\r\n')
    if have_cmd sha256sum; then
      _actual=$(sha256sum "$_vf_file_path" | awk '{print $1}')
    else
      _actual=$(shasum -a 256 "$_vf_file_path" | awk '{print $1}')
    fi
    [ "$_expected" = "$_actual" ]
    return $?
  fi

  return 1
}

main "$@"
