#!/usr/bin/env bash
set -Eeuo pipefail

# PipeOps Kubernetes installer stub
# Usage:
#   curl -fsSL https://get.pipeops.dev/k8-install.sh | bash
# Options:
#   VERSION=vX.Y.Z   Pin to a specific tag (defaults to main/latest)

VERSION="${VERSION:-}"

if [ -z "$VERSION" ] || [ "$VERSION" = "latest" ]; then
  URL="https://raw.githubusercontent.com/PipeOpsHQ/pipeops-k8-agent/main/scripts/install.sh"
else
  URL="https://raw.githubusercontent.com/PipeOpsHQ/pipeops-k8-agent/${VERSION}/scripts/install.sh"
fi

echo "==> Fetching installer from $URL" >&2
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp/install.sh" "$URL"
chmod +x "$tmp/install.sh"
exec bash "$tmp/install.sh" "$@"

