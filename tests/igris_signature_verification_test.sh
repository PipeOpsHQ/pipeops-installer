#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$tmp_dir/bin"

cat > "$tmp_dir/bin/cosign" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$COSIGN_LOG"
if [[ "${COSIGN_FAIL:-}" == "1" ]]; then
  exit 1
fi
SCRIPT
chmod +x "$tmp_dir/bin/cosign"

export IGRIS_INSTALLER_SKIP_MAIN=1
export PATH="$tmp_dir/bin:$PATH"
export COSIGN_LOG="$tmp_dir/cosign.log"
# shellcheck disable=SC1091
source "$repo_root/igris.sh"

printf 'abc123  aeon-agent_1.2.3_linux_x86_64.tar.gz\n' > "$tmp_dir/checksums.txt"
printf '{"fake":"bundle"}\n' > "$tmp_dir/checksums.txt.sigstore.bundle"

verify_checksum_manifest_signature \
  "$tmp_dir/checksums.txt" \
  "$tmp_dir/checksums.txt.sigstore.bundle" \
  "https://example.test/checksums.txt.sigstore.bundle"

grep -Fq -- 'verify-blob --bundle' "$COSIGN_LOG"
grep -Fq -- '--certificate-identity-regexp ^https://github.com/PipeOpsHQ/halo/\.github/workflows/release-agent.yml@refs/(heads|tags)/.*$' "$COSIGN_LOG"
grep -Fq -- '--certificate-oidc-issuer https://token.actions.githubusercontent.com' "$COSIGN_LOG"
grep -Fq -- "$tmp_dir/checksums.txt" "$COSIGN_LOG"

negative_output="$tmp_dir/igris-signature-negative.out"
if COSIGN_LOG="$tmp_dir/cosign-fail.log" COSIGN_FAIL=1 bash -c '
  set -euo pipefail
  export IGRIS_INSTALLER_SKIP_MAIN=1
  export PATH="$1/bin:$PATH"
  source "$2/igris.sh"
  verify_checksum_manifest_signature "$1/checksums.txt" "$1/checksums.txt.sigstore.bundle" "https://example.test/checksums.txt.sigstore.bundle"
' bash "$tmp_dir" "$repo_root" >"$negative_output" 2>&1; then
  fail "expected failed cosign verification to abort"
fi
grep -Fq -- 'Checksum manifest signature verification failed!' "$negative_output"

echo "ok: igris checksum manifest signature verification"
