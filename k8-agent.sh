#!/usr/bin/env bash
set -Eeuo pipefail

# Version: 955c47e
# Last-Modified: 2025-10-31T03:54:04Z
# Source: https://get.pipeops.dev/k8-agent.sh

# PipeOps Kubernetes Agent installer
# Customize via env vars/flags:
#   VERSION          - Tag like v1.2.3; default latest
#   MANIFEST_URL     - Override manifest URL
#   --namespace/-n   - Namespace to deploy into (default: pipeops-system)
#   --recreate       - Delete existing Deployment and re-apply (handles immutable selector changes)
#   --deployment-name NAME - Deployment name to manage when recreating (default: pipeops-agent)

info() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { have_cmd "$1" || die "Missing required command: $1"; }

NAMESPACE="pipeops-system"
VERSION=${VERSION:-latest}
RECREATE=0
DEPLOY_NAME="pipeops-agent"

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace|-n)
      shift; NAMESPACE="${1:-$NAMESPACE}" ;;
    --manifest-url)
      shift; MANIFEST_URL="${1:-}" ;;
    --recreate)
      RECREATE=1 ;;
    --deployment-name)
      shift; DEPLOY_NAME="${1:-$DEPLOY_NAME}" ;;
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
  set +e
  apply_out=$(kubectl apply -n "$NAMESPACE" -f "$url" 2>&1)
  status=$?
  set -e

  if [ $status -ne 0 ]; then
    printf '%s\n' "$apply_out" >&2
    if echo "$apply_out" | grep -Eqi 'field is immutable|spec\.selector'; then
      if [ "$RECREATE" = "1" ]; then
        warn "Immutable selector detected; recreating deployment ${DEPLOY_NAME} in ${NAMESPACE}"
        kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found
        kubectl apply -n "$NAMESPACE" -f "$url"
      else
        die "Apply failed due to immutable selector. Re-run with --recreate or delete the deployment: kubectl delete deploy/${DEPLOY_NAME} -n ${NAMESPACE}"
      fi
    else
      die "Failed to apply manifest"
    fi
  else
    printf '%s\n' "$apply_out"
  fi

  info "Done. Check resources with: kubectl -n ${NAMESPACE} get all"
}

main "$@"
