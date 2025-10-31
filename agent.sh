#!/usr/bin/env bash
set -Eeuo pipefail

# Alias to Kubernetes agent bootstrap installer
# Usage:
#   curl -fsSL https://get.pipeops.dev/agent.sh | bash [-- args]

exec bash -c 'curl -fsSL https://get.pipeops.dev/k8-install.sh | bash -s -- "$@"' -- "$@"

