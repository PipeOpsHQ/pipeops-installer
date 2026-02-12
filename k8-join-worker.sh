#!/bin/sh
set -eu

# Version: e9f67b4
# Last-Modified: 2025-10-31T03:54:55Z
# Source: https://get.pipeops.dev/k8-join-worker.sh

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
tmp="$(mktemp -d 2>/dev/null || mktemp -d -t 'pipeops.XXXXXX')"
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp/join-worker.sh" "$URL"
chmod +x "$tmp/join-worker.sh"

# Prefer bash if available, fall back to sh
if command -v bash >/dev/null 2>&1; then
  exec bash "$tmp/join-worker.sh" "$@"
else
  exec sh "$tmp/join-worker.sh" "$@"
fi
