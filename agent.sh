#!/bin/sh
set -eu

# Version: e9f67b4
# Last-Modified: 2025-10-31T03:54:55Z
# Source: https://get.pipeops.dev/agent.sh

# Alias to Kubernetes agent bootstrap installer
# Usage:
#   curl -fsSL https://get.pipeops.dev/agent.sh | bash [-- args]

# Prefer bash if available for downstream compatibility, fall back to sh
if command -v bash >/dev/null 2>&1; then
  exec bash -c 'curl -fsSL https://get.pipeops.dev/k8-install.sh | bash -s -- "$@"' -- "$@"
else
  exec sh -c 'curl -fsSL https://get.pipeops.dev/k8-install.sh | sh -s -- "$@"' -- "$@"
fi
