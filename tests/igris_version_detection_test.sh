#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$tmp_dir/hung-bin" "$tmp_dir/fast-bin"

export IGRIS_INSTALLER_SKIP_MAIN=1
# shellcheck source=../igris.sh
source "$repo_root/igris.sh"

cat > "$tmp_dir/hung-bin/igris" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  sleep 30
fi
SCRIPT
chmod +x "$tmp_dir/hung-bin/igris"

PATH="$tmp_dir/hung-bin:$PATH"
start_epoch="$(date +%s)"
hung_version="$(detect_installed_version 1)"
elapsed="$(( $(date +%s) - start_epoch ))"

if [[ "$hung_version" != "unknown" ]]; then
  fail "hanging version command returned $hung_version, want unknown"
fi
if (( elapsed > 4 )); then
  fail "hanging version command took ${elapsed}s, want a bounded timeout"
fi

cat > "$tmp_dir/fast-bin/igris" <<'SCRIPT'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "igris version 1.2.3"
fi
SCRIPT
chmod +x "$tmp_dir/fast-bin/igris"
PATH="$tmp_dir/fast-bin:$PATH"
hash -r

parsed_version="$(detect_installed_version 1)"
if [[ "$parsed_version" != "1.2.3" ]]; then
  fail "parsed version = $parsed_version, want 1.2.3"
fi

echo "ok: igris version detection is bounded and parses semver"
