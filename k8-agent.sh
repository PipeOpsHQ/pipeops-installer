#!/usr/bin/env bash
set -Eeuo pipefail

# PipeOps Kubernetes Agent installer
# Customize via env vars/flags:
#   VERSION       - Tag like v1.2.3; default latest
#   MANIFEST_URL  - Override manifest URL
#   --namespace/-n  Namespace to deploy into (default: pipeops-system)

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have_cmd "$1" || die "Missing required command: $1"; }

NAMESPACE="pipeops-system"
VERSION=${VERSION:-latest}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace|-n)
      shift; NAMESPACE="${1:-$NAMESPACE}" ;;
    --manifest-url)
      shift; MANIFEST_URL="${1:-}" ;;
    --)
      shift; break ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift || true
done

default_manifest_url() {
  local repo="pipeopshq/pipeops-k8-agent"
  if [ "$VERSION" = "latest" ]; then
    printf 'https://raw.githubusercontent.com/%s/main/deployments/agent.yaml' "$repo"
  else
    printf 'https://raw.githubusercontent.com/%s/%s/deployments/agent.yaml' "$repo" "$VERSION"
  fi
}

main() {
  need_cmd kubectl
  need_cmd curl

  local url
  url=${MANIFEST_URL:-$(default_manifest_url)}

  info "Namespace: ${NAMESPACE}"
  info "Manifest: ${url}"

  # Ensure namespace exists
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    info "Creating namespace ${NAMESPACE}"
    kubectl create namespace "$NAMESPACE"
  fi

  # Apply manifest (namespaced resources will use -n; cluster-scope ignores it)
  info "Applying manifest"
  kubectl apply -n "$NAMESPACE" -f "$url"

  info "Done. Check resources with: kubectl -n ${NAMESPACE} get all"
}

main "$@"

