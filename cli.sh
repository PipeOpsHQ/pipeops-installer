#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

# PipeOps CLI installer
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

tmpdir() {
  mktemp -d 2>/dev/null || mktemp -d -t pipeops
}

# Compare semantic versions (returns 0 if v1 >= v2, 1 otherwise)
semver_gte() {
  local v1="$1" v2="$2"
  # Strip leading 'v' if present
  v1="${v1#v}"; v2="${v2#v}"
  
  # Split versions into arrays
  IFS='.' read -ra ver1 <<< "$v1"
  IFS='.' read -ra ver2 <<< "$v2"
  
  # Compare major, minor, patch
  for i in 0 1 2; do
    local n1="${ver1[i]:-0}" n2="${ver2[i]:-0}"
    # Strip any pre-release suffix (e.g., -beta, -rc1)
    n1="${n1%%-*}"; n2="${n2%%-*}"
    if [ "$n1" -gt "$n2" ]; then return 0; fi
    if [ "$n1" -lt "$n2" ]; then return 1; fi
  done
  return 0
}

# Get the latest release tag by semantic version from GitHub API
get_latest_version() {
  local repo="$1"
  need_cmd grep
  need_cmd sed
  
  # Fetch all release tags from GitHub API
  local tags_url="https://api.github.com/repos/${repo}/releases"
  local releases
  
  # Try to fetch releases (limited to first 100)
  if ! releases=$(curl -fsSL "$tags_url" 2>/dev/null); then
    warn "Failed to fetch releases from API, falling back to /releases/latest"
    echo "latest"
    return
  fi
  
  # Check if we got an empty response or error
  if [ -z "$releases" ] || echo "$releases" | grep -q '"message".*"API rate limit exceeded"'; then
    warn "GitHub API unavailable or rate limited, falling back to /releases/latest"
    echo "latest"
    return
  fi
  
  # Parse JSON manually: extract non-prerelease tags
  # Format: each release has "tag_name": "vX.Y.Z", "prerelease": false/true
  local latest_tag=""
  local current_tag="" in_release=false prerelease=false
  
  while IFS= read -r line; do
    # Detect start of a release object
    if echo "$line" | grep -q '^ *{$'; then
      in_release=true
      current_tag=""
      prerelease=false
    fi
    
    # Extract tag_name
    if [ "$in_release" = true ] && echo "$line" | grep -q '"tag_name"'; then
      current_tag=$(echo "$line" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    fi
    
    # Extract prerelease status
    if [ "$in_release" = true ] && echo "$line" | grep -q '"prerelease"'; then
      if echo "$line" | grep -q '"prerelease": *true'; then
        prerelease=true
      fi
    fi
    
    # Detect end of a release object
    if echo "$line" | grep -q '^ *}[,]*$'; then
      # Process the release if we have a tag and it's not a prerelease
      if [ -n "$current_tag" ] && [ "$prerelease" = false ]; then
        if [ -z "$latest_tag" ] || semver_gte "$current_tag" "$latest_tag"; then
          latest_tag="$current_tag"
        fi
      fi
      in_release=false
    fi
  done <<< "$releases"
  
  if [ -n "$latest_tag" ]; then
    echo "$latest_tag"
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

  local os arch asset_file base_url download_url tdir dest_dir sudo_cmd src_bin resolved_version
  os=$(detect_os)
  arch=$(detect_arch)

  # Resolve version
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

  # Resolve asset filename; try common naming patterns until one downloads
  if [ -n "${ASSET_FILE:-}" ]; then
    asset_file="${ASSET_FILE}"
  else
    # Preferred naming used by PipeOps releases
    candidates=(
      "${ASSET_PREFIX}_${os}_${arch}.${ASSET_EXT}"
      "${BINARY_NAME}_${os}_${arch}.${ASSET_EXT}"
      "${BINARY_NAME}-cli_${os}_${arch}.${ASSET_EXT}"
    )
  fi

  # Install prefix
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
  if [ ! -w "$dest_dir" ]; then
    if have_cmd sudo; then sudo_cmd="sudo -E"; fi
  fi

  info "OS=${os} ARCH=${arch}"

  tdir=$(tmpdir)
  trap 'rm -rf "${tdir:-}"' EXIT

  local file_path
  mkdir -p "$tdir"
  if [ -n "${asset_file:-}" ]; then
    # Explicit asset path provided
    download_url="${base_url}/${asset_file}"
    file_path="${tdir}/${asset_file##*/}"
    info "Downloading ${download_url}"
    curl -fL --retry 3 --connect-timeout 10 -o "$file_path" "$download_url" || die "Download failed: $download_url"
  else
    # Try candidates until one succeeds
    local ok=0; local tried="";
    for af in "${candidates[@]}"; do
      download_url="${base_url}/${af}"
      file_path="${tdir}/${af##*/}"
      info "Downloading ${download_url}"
      if curl -fL --retry 3 --connect-timeout 10 -o "$file_path" "$download_url" ; then
        asset_file="$af"; ok=1; break
      else
        tried+="\n  - ${download_url}"
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
    # try to find the binary by name
    if [ -f "${tdir}/${BINARY_NAME}" ]; then
      src_bin="${tdir}/${BINARY_NAME}"
    else
      src_bin=$(find "$tdir" -type f -name "${BINARY_NAME}" -perm -u+x 2>/dev/null | head -n1 || true)
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
    *:"$dest_dir":*) ;;
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
  local file_path="$1" download_url="$2" base_url="$3" asset_file="$4"
  local mode="$VERIFY"
  case "$mode" in
    0|false|no) return 0 ;;
    auto|strict) ;;
    *) mode=auto ;;
  esac

  # locate checksum file URL
  local sum_urls=()
  if [ -n "${CHECKSUMS_URL:-}" ]; then
    sum_urls+=("$CHECKSUMS_URL")
  fi
  if [ -n "${CHECKSUMS_ASSET:-}" ]; then
    sum_urls+=("${base_url}/${CHECKSUMS_ASSET}")
  fi
  # common patterns
  sum_urls+=(
    "${download_url}.sha256"
    "${download_url}.sha256sum"
    "${download_url}.sha256.txt"
    "${base_url}/SHA256SUMS"
    "${base_url}/SHA256SUMS.txt"
    "${base_url}/checksums.txt"
  )

  local tmp_dir sum_file url ok=0 basename
  basename="$(basename "$asset_file")"
  tmp_dir="$(dirname "$file_path")"

  for url in "${sum_urls[@]}"; do
    sum_file="${tmp_dir}/checksums"
    if curl -fsL -o "$sum_file" "$url" 2>/dev/null ; then
      if do_verify_with_file "$file_path" "$sum_file" "$basename" ; then
        info "Checksum verified using $(basename "$url")"
        ok=1
        break
      fi
    fi
  done

  if [ "$ok" = 1 ]; then
    return 0
  fi

  if [ "$mode" = strict ]; then
    die "Checksum verification failed or checksums not found"
  else
    warn "Could not verify checksum (no checksums found or mismatch)"
  fi
}

do_verify_with_file() {
  # Accepts either:
  #   - lines like: <hash>  <filename>
  #   - single hash only (we pair it with the asset filename)
  local file_path="$1" sum_file="$2" basename="$3"
  local dir hash_only

  if ! have_cmd sha256sum && ! have_cmd shasum; then
    warn "No sha256 verifier found (sha256sum/shasum). Skipping verification."
    return 1
  fi

  # Does the checksum file contain an entry for our basename?
  if grep -Eiq "\b${basename//./\.}\b" "$sum_file"; then
    if have_cmd sha256sum; then
      (cd "$(dirname "$file_path")" && sha256sum -c "${sum_file}" --ignore-missing)
    else
      (cd "$(dirname "$file_path")" && shasum -a 256 -c "${sum_file}" 2>/dev/null | grep -vi 'No such file' || true)
      # shasum -c exits non-zero on missing files; re-check the exact file
      local expected
      expected="$(grep -Ei "\b${basename//./\.}\b" "$sum_file" | awk '{print $1}' | head -n1)"
      [ -n "$expected" ] || return 1
      local actual
      actual="$(shasum -a 256 "$file_path" | awk '{print $1}')"
      [ "$expected" = "$actual" ]
    fi
    return $?
  fi

  # Try single-hash file (64-hex chars only)
  if grep -Eq '^[a-fA-F0-9]{64}$' "$sum_file"; then
    local expected
    expected="$(head -n1 "$sum_file" | tr -d '\r\n')"
    local actual
    if have_cmd sha256sum; then
      actual="$(sha256sum "$file_path" | awk '{print $1}')"
    else
      actual="$(shasum -a 256 "$file_path" | awk '{print $1}')"
    fi
    [ "$expected" = "$actual" ]
    return $?
  fi

  return 1
}

main "$@"
