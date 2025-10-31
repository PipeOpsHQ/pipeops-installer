# PipeOps Installer (GitHub Pages)

This repo serves install scripts and manifests under your custom domain so users can run:

- CLI: `curl -fsSL https://get.pipeops.dev/cli.sh | bash`
- K8s agent: `curl -fsSL https://get.pipeops.dev/k8-agent.sh | bash`
- Optional direct manifest: `kubectl apply -f https://get.pipeops.dev/k8-agent.yaml`

Adjust variables in the scripts to match your release assets and binary naming.

## Files

- `cli.sh` — Installs the PipeOps CLI from GitHub Releases (auto-detects OS/arch).
- `k8-install.sh` — Delegates to the upstream cluster/agent installer (`scripts/install.sh`).
- `agent.sh` — Alias wrapper to `k8-install.sh` for convenience.
- `k8-agent.sh` — Applies the PipeOps Kubernetes agent manifest (defaults to your GitHub Releases; can be pinned).
- `k8-agent.yaml` — Placeholder manifest (replace with your pinned agent manifest if you want a stable path).
- `k8-join-worker.sh` — Delegates to the upstream worker join script (`scripts/join-worker.sh`).
- `CNAME` — Custom domain for GitHub Pages (`get.pipeops.dev`).
- `.nojekyll` — Disables Jekyll processing so files serve as raw assets.
- `index.html` — Minimal landing page with usage examples.
- `.github/workflows/sync-k8-agent.yml` — Keeps a pinned copy of the latest agent manifest in this repo.

## Publish under your domain

1. Push this folder as a repo, e.g. `pipeopshq/pipeops-installer`.
2. GitHub → Settings → Pages:
   - Source: Deploy from a branch → `main` → `/ (root)`.
   - Custom domain: `get.pipeops.dev` (or edit `CNAME`).
   - Enforce HTTPS.
3. DNS: create a CNAME record at your DNS provider:
   - `get` → `pipeopshq.github.io`
4. Wait for certificate provisioning (minutes to an hour).

## Keep k8-agent.yaml pinned automatically

This repo includes a workflow that fetches the latest `k8-agent.yaml` from `pipeopshq/pipeops-k8-agent` releases and commits it here.

- Triggers:
  - Manual: Actions → “Sync K8s Agent Manifest” → Run
  - Scheduled: every 6 hours
  - Optional: `repository_dispatch` with type `k8_agent_released` and payload `{ "tag": "vX.Y.Z" }` from the agent repo

- Files it updates:
  - `k8-agent/k8-agent-vX.Y.Z.yaml` (versioned copy)
  - `k8-agent.yaml` (stable pointer to the most recent)

In `pipeopshq/pipeops-k8-agent` you can add a step after creating a release to notify this repo:

```yaml
- name: Notify installer repo
  if: github.event_name == 'release' && github.event.action == 'published'
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    curl -sS -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      https://api.github.com/repos/pipeopshq/pipeops-installer/dispatches \
      -d '{"event_type":"k8_agent_released","client_payload":{"tag":"'"${{ github.event.release.tag_name }}"'"}}'
```

## Customize scripts

- `cli.sh` variables to verify/update:
  - `GH_REPO` (default: `pipeopshq/pipeops-cli`)
  - `BINARY_NAME` (default: `pipeops`)
  - Asset naming pattern defaults to `${BINARY_NAME}_${OS}_${ARCH}.tar.gz` (Linux/Darwin and amd64/arm64). Adjust if your release assets differ.
  - Optional: `VERSION=v1.2.3` to pin; otherwise uses `latest`.

- `k8-agent.sh` variables to verify/update:
  - `MANIFEST_URL` default points to `pipeopshq/pipeops-k8-agent` releases latest.
  - Optional: set `VERSION=v1.2.3` to pin to a specific release.
  - Optional: replace `k8-agent.yaml` in this repo and set `MANIFEST_URL=https://get.pipeops.dev/k8-agent.yaml` for a domain-stable manifest.

## Usage

- Install latest CLI to a standard location (`~/.local/bin` or `/usr/local/bin` if sudo is available):

  ```sh
  curl -fsSL https://get.pipeops.dev/cli.sh | bash
  ```

- Install a specific version:

  ```sh
  VERSION=v1.2.3 curl -fsSL https://get.pipeops.dev/cli.sh | bash
  ```

- Install to a custom prefix:

  ```sh
  PREFIX=/opt/pipeops curl -fsSL https://get.pipeops.dev/cli.sh | bash
  ```

- Install the Kubernetes agent into a namespace (creates if missing):

  ```sh
  curl -fsSL https://get.pipeops.dev/k8-agent.sh | bash -s -- --namespace pipeops-system
  ```

- Apply a pinned manifest directly (after you replace `k8-agent.yaml`):

  ```sh
  kubectl apply -f https://get.pipeops.dev/k8-agent.yaml
  ```

- Bootstrap a cluster and install the agent (served from this installer domain; delegates to upstream installer):

  ```sh
  curl -fsSL https://get.pipeops.dev/k8-install.sh | bash
  # or the alias
  curl -fsSL https://get.pipeops.dev/agent.sh | bash
  ```

- Pin a specific installer version:

  ```sh
  VERSION=v1.2.3 curl -fsSL https://get.pipeops.dev/k8-install.sh | bash
  ```

- Join a worker node to a cluster via upstream join script (served from this installer domain):

  ```sh
  export K3S_URL=https://<server>:6443
  export K3S_TOKEN=<token>
  curl -fsSL https://get.pipeops.dev/k8-join-worker.sh | bash
  ```

### Bootstrap vs. Apply Manifest

- Bootstrap (`k8-install.sh` / `agent.sh`): provisions/bootstraps the cluster environment and installs the agent via upstream installer.
- Apply (`k8-agent.sh`): applies a Kubernetes manifest to an existing cluster/context. Use this when your cluster is already running.

### Handling immutable selector error

If you see: `Deployment "pipeops-agent" is invalid: spec.selector ... field is immutable`, it means an older Deployment exists with different labels. Fix:

- One-time recreate via the installer:

  ```sh
  curl -fsSL https://get.pipeops.dev/k8-agent.sh | bash -s -- --namespace pipeops-system --recreate
  ```

- Or manually delete then apply:

  ```sh
  kubectl delete deploy/pipeops-agent -n pipeops-system
  curl -fsSL https://get.pipeops.dev/k8-agent.sh | bash -s -- --namespace pipeops-system
  ```

## Security notes

- Prefer pinning versions for production (`VERSION=vX.Y.Z`).
- Checksums: `cli.sh` attempts to verify checksums automatically when present (`VERIFY=auto`).
  - Strict mode: `VERIFY=strict curl -fsSL https://get.pipeops.dev/cli.sh | bash` will fail if no checksum is found or if it mismatches.
  - Override checksum asset/name via `CHECKSUMS_ASSET=checksums.txt` or full `CHECKSUMS_URL=...`.
