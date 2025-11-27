#!/usr/bin/env bash
# PipeOps K8s Agent Uninstaller Wrapper
# Delegates to the upstream uninstall script from pipeopshq/pipeops-k8-agent

set -Eeuo pipefail

# Default values
: "${VERSION:=main}"
: "${GH_REPO:=PipeOpsHQ/pipeops-k8-agent}"

readonly VERSION GH_REPO

info() { echo "[INFO] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

main() {
  info "Fetching PipeOps agent uninstaller from ${GH_REPO}@${VERSION}..."

  # If UNINSTALL_K3S is set to true, we assume the user wants to force the uninstallation
  # This allows running the script in non-interactive mode (e.g. piped from curl)
  if [ "${UNINSTALL_K3S:-}" = "true" ]; then
    export FORCE=true
  fi

  local url="https://raw.githubusercontent.com/${GH_REPO}/${VERSION}/scripts/uninstall.sh"

  # Download and execute the upstream uninstaller
  if ! curl -fsSL "$url" | bash -s -- "$@"; then
    die "Uninstall failed. Check the output above for details."
  fi

  info "Uninstall complete!"
}

main "$@"
