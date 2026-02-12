#!/bin/sh
set -eu

# Version: 955c47e
# Last-Modified: 2025-10-31T03:54:04Z
# Source: https://get.pipeops.dev/k8-install.sh

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
tmp="$(mktemp -d 2>/dev/null || mktemp -d -t 'pipeops.XXXXXX')"
trap 'rm -rf "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp/install.sh" "$URL"
chmod +x "$tmp/install.sh"

# The upstream install.sh requires bash; prefer bash if available, fall back to sh
if command -v bash >/dev/null 2>&1; then
  exec bash "$tmp/install.sh" "$@"
else
  exec sh "$tmp/install.sh" "$@"
fi
