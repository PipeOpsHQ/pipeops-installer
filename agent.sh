#!/usr/bin/env bash
set -Eeuo pipefail

# Version: e9f67b4
# Last-Modified: 2025-10-31T03:54:55Z
# Source: https://get.pipeops.dev/agent.sh

# Alias to Kubernetes agent bootstrap installer
# Usage:
#   curl -fsSL https://get.pipeops.dev/agent.sh | bash [-- args]

exec bash -c 'curl -fsSL https://get.pipeops.dev/k8-install.sh | bash -s -- "$@"' -- "$@"
