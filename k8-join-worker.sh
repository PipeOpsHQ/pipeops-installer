#!/usr/bin/env bash
set -Eeuo pipefail

# PipeOps Kubernetes join worker stub
# Usage:
#   export K3S_URL=...
#   export K3S_TOKEN=...
#   curl -fsSL https://get.pipeops.dev/k8-join-worker.sh | bash
# Options:
#   VERSION=vX.Y.Z   Pin to a specific tag (defaults to main/latest)

VERSION="${VERSION:-}"

if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
  URL="https://raw.githubusercontent.com/PipeOpsHQ/pipeops-k8-agent/main/scripts/join-worker.sh"
else
  URL="https://raw.githubusercontent.com/PipeOpsHQ/pipeops-k8-agent/${VERSION}/scripts/join-worker.sh"
fi

echo "==> Fetching join script from $URL" >&2
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp/join-worker.sh" "$URL"
chmod +x "$tmp/join-worker.sh"
exec bash "$tmp/join-worker.sh" "$@"

