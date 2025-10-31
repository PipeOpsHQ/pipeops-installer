# Repository Guidelines

## Project Structure & Module Organization
- Root contains install scripts and served assets for GitHub Pages.
- Scripts: `cli.sh` (Unix CLI installer), `cli.ps1` (Windows), `k8-install.sh`, `k8-join-worker.sh`, `k8-agent.sh`, `agent.sh` (alias to k8 installer).
- Manifests: `k8-agent.yaml` (Kubernetes agent). Keep placeholders; do not commit real secrets.
- Site assets: `index.html`, `CNAME`, `.nojekyll`.
- CI: `.github/workflows/sync-k8-agent.yml` keeps `k8-agent.yaml` pinned to the latest release.

## Build, Test, and Development Commands
- No build step; scripts run as-is.
- Bash syntax/lint: `bash -n cli.sh`, `shellcheck -x cli.sh` (and other `*.sh`) if available.
- YAML lint: `yamllint k8-agent.yaml` (optional).
- K8s dry run: `kubectl apply -f k8-agent.yaml --dry-run=client -o yaml`.
- Local smoke tests:
  - CLI: `VERSION=v1.2.3 bash cli.sh` (installs to `~/.local/bin` when non-root).
  - K8s agent: `bash k8-agent.sh -n pipeops-system` (requires `kubectl` context).

## Coding Style & Naming Conventions
- Shell: Bash only. Start with `#!/usr/bin/env bash` and `set -Eeuo pipefail`.
- Indentation: 2 spaces; quote variables; prefer `local` for function vars; use `readonly` for constants.
- Common helpers: keep `info`, `warn`, `die`, `have_cmd`, `need_cmd` patterns.
- Naming: scripts `k8-*.sh`; env/config UPPER_SNAKE (`VERSION`, `GH_REPO`); locals/functions lower_snake (`dest_dir`, `detect_os`).
- YAML: namespace `pipeops-system`; labels under `app.kubernetes.io/*`.

## Testing Guidelines
- Validate new flags preserve piped usage: `curl -fsSL .../cli.sh | bash -s -- --help` style must still work.
- For Kubernetes changes, test against a disposable cluster (kind/minikube) and verify RBAC applies cleanly.
- Keep scripts idempotent and safe to re-run.

## Commit & Pull Request Guidelines
- Conventional Commits style. Examples:
  - `feat(cli): add VERIFY=strict mode`
  - `fix(k8): correct namespace creation logic`
  - `chore(agent): bump k8-agent.yaml to v1.2.3`
- PRs should include: concise description, linked issues, test commands/output, and note any public URL or filename changes.
- Ensure executables have the bit set (`chmod +x *.sh`).

## Security & Configuration Tips
- Prefer pinned releases for production: `VERSION=vX.Y.Z`.
- Enable checksum verification where possible: `VERIFY=strict curl -fsSL https://get.pipeops.dev/cli.sh | bash`.
- Do not commit tokens or cluster names; keep placeholders in `k8-agent.yaml` and populate via installers.
- RBAC currently uses broad access; minimize scopes when feasible before changing defaults.

