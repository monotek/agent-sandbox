# agent-sandbox

A Podman container that replaces locally installed coding agents.
Instead of running `opencode`, `claude`, `gemini`, or `copilot` directly on
your machine, thin wrapper scripts in `~/.local/bin/` intercept those commands
and transparently launch them inside this container — giving every agent the
same reproducible environment, the same infrastructure tooling, and an
isolated filesystem.

## Concept

Coding agents need more than just their own binary: they call `kubectl`,
`helm`, `terraform`, `flux`, and a dozen other tools while working on
infrastructure-heavy projects. Installing and versioning all of that locally
is tedious and causes drift between machines. This container bundles everything
agents need, versioned via [mise](https://mise.jdx.dev/), and exposes it
through a zero-config command intercept pattern.

```
user types:  opencode
             │
             └─► ~/.local/bin/opencode  (agent-wrapper.sh symlink)
                         │
                         └─► podman run agent-sandbox opencode ...
                                         │
                                         ├─ mounts current directory as /home/agent/workdir
                                         ├─ mounts ~/agent-sandbox/.claude etc. (auto)
                                         ├─ mounts ~/agent-sandbox/.kube (explicit only)
                                         ├─ mounts ~/.gitconfig (read-only)
                                         ├─ forwards SSH agent socket
                                         ├─ appends AGENT_SANDBOX_MOUNTS
                                         ├─ sets working directory to /home/agent/workdir
                                         └─ --userns=keep-id:uid=1001,gid=1001
```

Your project files, agent configuration, and SSH identity are mounted in at
runtime — nothing sensitive is baked into the image.

---

## Quick Start

1. **Pull the image:**
   ```bash
   podman pull ghcr.io/monotek/agent-sandbox:main
   ```

2. **Clone this repo to a stable location and install the wrapper:**
   ```bash
   git clone https://github.com/monotek/agent-sandbox.git ~/gitrepos/agent-sandbox
   cd ~/gitrepos/agent-sandbox
   ln -sf "$(pwd)/agent-wrapper.sh" ~/.local/bin/agent-wrapper
   ln -sf agent-wrapper ~/.local/bin/opencode
   ln -sf agent-wrapper ~/.local/bin/claude
   ln -sf agent-wrapper ~/.local/bin/gemini
   ln -sf agent-wrapper ~/.local/bin/copilot
   ```

3. **(Optional) Copy your existing agent configs into `~/agent-sandbox/`:**

   The wrapper creates empty config directories on first run. If you already
   have agent configs on the host and want to pre-populate them, copy with
   `-L` to resolve any symlinks to real files — symlinks pointing outside the
   container's filesystem would silently break inside the container:

   ```bash
   cp -rL ~/.claude/.            ~/agent-sandbox/.claude/
   cp -rL ~/.config/opencode/.   ~/agent-sandbox/.config/opencode/
   cp -rL ~/.copilot/.           ~/agent-sandbox/.copilot/
   cp -rL ~/.gemini/.            ~/agent-sandbox/.gemini/
   cp -rL ~/.config/gh/.         ~/agent-sandbox/.config/gh/
   ```

   Skip any agents you don't use. Re-run after updating the originals.

4. **Run:**
   ```bash
   cd ~/gitrepos/my-project
   opencode
   ```

See [Configuration](#configuration) to pin a specific image, change paths, or pass API keys.

---

## Prerequisites

- **Podman ≥ 4.3** — the wrapper uses `--userns=keep-id:uid=1001,gid=1001` (introduced in Podman 4.3,
  October 2022) to map your host user to the container's `agent` user (UID/GID 1001) regardless of
  what UID you have locally. Files written to mounted volumes appear owned by your host user.

---

## Usage

### Wrapper scripts (recommended)

`agent-wrapper.sh` is a single script installed under multiple names. When invoked, it:

1. Mounts the current working directory as `/home/agent/workdir` inside the container
2. Sets the container working directory to `/home/agent/workdir`
3. Creates (if absent) and mounts all agent config directories from `AGENT_SANDBOX_DIR` (`~/agent-sandbox/` by default)
4. Mounts `~/.gitconfig` read-only — git identity inside the container
5. Forwards the SSH agent socket for git-over-SSH
6. Passes all CLI arguments unchanged to the container

#### Installation

> The Quick Start section above covers the common case. What follows is the full detail.

**Symlink — don't copy.** The wrapper loads `.env` from the repo root by resolving its
own real path. A copied script would look for `.env` in `~/.local/bin/` instead of the
repo. With a symlink, `git pull` in the repo also picks up any future wrapper changes
without reinstalling.

```bash
git clone https://github.com/monotek/agent-sandbox.git
cd agent-sandbox
ln -sf "$(pwd)/agent-wrapper.sh" ~/.local/bin/agent-wrapper
```

Then create one symlink per agent you want to intercept:

```bash
ln -sf agent-wrapper ~/.local/bin/opencode
ln -sf agent-wrapper ~/.local/bin/claude
ln -sf agent-wrapper ~/.local/bin/gemini
ln -sf agent-wrapper ~/.local/bin/copilot
```

**If you use mise locally to manage the agents**, `mise activate` injects each
tool's bin directory into `$PATH` via shell hooks that fire on every prompt,
overriding any PATH ordering. The solution is `activate.sh` — it defines
shell functions for each agent that take priority over every `$PATH` entry,
including mise-injected ones, without requiring you to uninstall the tools
from mise:

```bash
# ~/.zshrc or ~/.bashrc — after eval "$(mise activate ...)"
eval "$(~/gitrepos/agent-sandbox/activate.sh)"
```

The generated functions look like:

```bash
opencode() { command ~/.local/bin/opencode "$@"; }
claude()   { command ~/.local/bin/claude "$@"; }
gemini()   { command ~/.local/bin/gemini "$@"; }
copilot()  { command ~/.local/bin/copilot "$@"; }
```

Shell functions shadow every binary in `$PATH`, so `opencode` (for example)
calls the wrapper regardless of whether mise has also injected a local
`opencode` binary earlier in `$PATH`. The locally installed binaries remain
available for non-interactive use (scripts, CI) and mise continues to manage
their versions.

#### How it works

The wrapper mounts the current working directory to a fixed path inside the container:

```
$PWD  →  /home/agent/workdir  (container working directory)
```

In addition, the wrapper mounts when present:

- `~/.gitconfig` → `/home/agent/.gitconfig` (read-only) — git identity, when the file exists
- SSH agent socket → `/run/ssh-agent.sock` — when `$SSH_AUTH_SOCK` is set to a valid socket

#### Configuration

All settings are optional. The wrapper reads them from three sources in
increasing priority order:

1. **Built-in defaults** — hardcoded in the script
2. **`.env` file** — `<repo-root>/.env` (gitignored, never committed) — only loaded when the wrapper is installed as a symlink pointing into the repo
3. **Shell environment** — variables exported in the calling shell or set inline (`VAR=val opencode`)

**`.env` file (recommended for persistent per-machine config)**

Copy `.env.example` to `.env` in the repo root and uncomment the lines you
need. Because `.env` is gitignored, `git pull` will never touch it:

```bash
cp .env.example .env
```

```bash
# agent-sandbox/.env — not committed, safe to store local paths and preferences

AGENT_SANDBOX_DIR=/home/yourname/agent-sandbox
AGENT_SANDBOX_ENV=ANTHROPIC_API_KEY,OPENAI_API_KEY
```

For `AGENT_SANDBOX_MOUNTS` with **multiple** extra mounts, set the variable
in your shell profile instead — the `.env` parser handles single-line values
only:

```bash
# ~/.bashrc or ~/.zshrc
export AGENT_SANDBOX_MOUNTS="
/mnt/shared/data:/home/agent/data
/opt/company-certs:/home/agent/certs:ro
"
```

**Available variables**

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENT_SANDBOX_IMAGE` | `ghcr.io/monotek/agent-sandbox:main` | Image name / tag to run |
| `AGENT_SANDBOX_DIR` | `~/agent-sandbox` | Base directory for all agent configs and credentials. Subdirs `.claude`, `.config/opencode`, `.copilot`, `.gemini`, `.config/gh` are auto-mounted when present. |
| `AGENT_SANDBOX_KUBE` | — | Host path mounted read-only as `/home/agent/.kube`. Not mounted unless explicitly set. |
| `AGENT_SANDBOX_MOUNTS` | — | Newline-separated list of additional `-v` mount specs in `src:dst[:opts]` format |
| `AGENT_SANDBOX_ENV` | — | Comma-separated list of env-var **names** to forward into the container |

> `AGENT_SANDBOX_BIN` (`~/.local/bin` by default) is used only by `activate.sh` — not by the
> wrapper itself. Set it if your wrapper symlinks live somewhere other than `~/.local/bin`.

**One-off overrides** — set inline for a single invocation, no `.env` edit needed:

```bash
AGENT_SANDBOX_IMAGE=ghcr.io/monotek/agent-sandbox:v1.2.3 claude
AGENT_SANDBOX_ENV="ANTHROPIC_API_KEY,OPENAI_API_KEY" opencode
```

### Direct `podman run` (advanced)

For scripting or one-off use without the wrapper:

```bash
podman run -it --rm \
  --userns=keep-id:uid=1001,gid=1001 \
  -v "$PWD:/home/agent/workdir" \
  -v ~/agent-sandbox/.claude:/home/agent/.claude \
  -v ~/agent-sandbox/.config/opencode:/home/agent/.config/opencode \
  -v ~/agent-sandbox/.copilot:/home/agent/.copilot \
  -v ~/agent-sandbox/.gemini:/home/agent/.gemini \
  -v ~/.gitconfig:/home/agent/.gitconfig:ro \
  -w /home/agent/workdir \
  ghcr.io/monotek/agent-sandbox:main opencode

# Kubeconfig — optional, only if the agent needs cluster access:
#  -v ~/agent-sandbox/.kube:/home/agent/.kube:ro \

# Drop into a shell to explore the environment:
podman run -it --rm ghcr.io/monotek/agent-sandbox:main
```

---

## Host directory layout

```
~/
├─ .gitconfig                 # Git identity — auto-mounted read-only by wrapper
│
└─ agent-sandbox/             # Everything the agent can see — configs and credentials
    ├─ .claude/               # Claude Code config     (auto-mounted, writable)
    ├─ .copilot/              # Copilot CLI config     (auto-mounted, writable)
    ├─ .gemini/               # Gemini CLI config      (auto-mounted, writable)
    ├─ .config/
    │   ├─ opencode/          # OpenCode config        (auto-mounted, writable)
    │   └─ gh/                # GitHub CLI config      (auto-mounted, read-only)
    └─ .kube/                 # Kubeconfig (restricted) — mounted only when AGENT_SANDBOX_KUBE is set
        └─ config
```

### Security model

The wrapper mounts three categories of host resources:

**Agent configs** (`.claude`, `.config/opencode`, etc.) are auto-mounted writable from
`~/agent-sandbox/` when present. Agents write session state and preferences here.
These directories also hold **authentication tokens** for each agent's API. A
prompt-injected agent with write access could exfiltrate tokens or tamper with
configuration. Keep this tradeoff in mind when running agents against untrusted
repositories.

Because these directories often contain symlinks (e.g. managed by a dotfiles repo),
they are copied into `~/agent-sandbox/` as real files rather than mounted directly
from `~/`. Symlinks pointing outside the container's filesystem would silently
break — copying resolves them at copy time.

**Credentials** (`.kube/`, cloud CLI tokens, sops keys) are **never auto-mounted**.
Each one requires an explicit variable (`AGENT_SANDBOX_KUBE`, `AGENT_SANDBOX_MOUNTS`).
The `.kube` directory should contain a purpose-built kubeconfig with restricted
contexts and minimal RBAC permissions — not a copy of `~/.kube/config`.

Two independent layers of protection apply to credentials:

1. **Read-only mount (`:ro`)** — the agent cannot modify the credential files.
   It cannot overwrite a kubeconfig, rotate a token, or tamper with keys on the host.

2. **Read-only RBAC permissions** — the credentials themselves should only grant
   read access. Any `kubectl apply` or destructive call is rejected by the API server
   regardless of what the agent attempts. Applying suggestions remains a deliberate
   human action with a separate write-capable identity outside the container.

Neither layer alone is sufficient: a writable mount would let the agent replace its
own credentials, and write-capable RBAC would let it act on suggestions autonomously.

**Identity resources** — `~/.gitconfig` and the SSH agent socket are always forwarded
(when present) so that git works inside the container. `~/.gitconfig` is mounted
read-only; the SSH socket is forwarded without copying any key material.

---

## Build

The image is published to the GitHub Container Registry on every push to
`main` and for every release tag:

```
ghcr.io/monotek/agent-sandbox:main        # latest main branch
ghcr.io/monotek/agent-sandbox:v1.2.3      # specific release
ghcr.io/monotek/agent-sandbox:v1.2        # latest patch for minor
ghcr.io/monotek/agent-sandbox:v1          # latest minor for major
```

The wrapper defaults to `:main`. Pull it explicitly before first use or to
pick up updates:

```bash
podman pull ghcr.io/monotek/agent-sandbox:main
```

Building locally is only needed when you want to test changes to the
`Dockerfile` or `mise.toml` before pushing.

### Update tool versions

Before building, bump all pinned versions in `mise.toml` to the latest
releases. `mise upgrade --bump --local` rewrites the version numbers in the file.
It also installs the tools locally as a side effect — only the file change
matters for the container build.

```bash
mise upgrade --bump --local
```

### Build the image locally

A **GitHub personal access token** (PAT) is required — mise fetches several tools
from GitHub releases and the token prevents rate-limiting:

```bash
export GITHUB_TOKEN=ghp_...
```

With Podman:

```bash
podman build --secret id=github_token,env=GITHUB_TOKEN . -t agent-sandbox
```

With Docker (requires BuildKit):

```bash
DOCKER_BUILDKIT=1 docker build --secret id=github_token,env=GITHUB_TOKEN . -t agent-sandbox
```

The `GITHUB_TOKEN` is passed as a BuildKit secret — it is used only during
`mise install` and never written to any image layer.

Log the full build output to a file for debugging:

```bash
podman build --secret id=github_token,env=GITHUB_TOKEN . -t agent-sandbox 2>&1 | tee output.txt
```

---

## What's Inside

### Base system (`Dockerfile`)

Built on **Ubuntu 24.04** with these packages installed via `apt-get`:

| Package | Purpose |
|---------|---------|
| `build-essential` | C/C++ compiler and make — required for native Node.js addons, CGO, and Python C extensions |
| `ca-certificates` | TLS root certificates |
| `curl` | HTTP client; used to bootstrap mise |
| `git` | Version control |
| `gnupg` | GPG verification for Node.js tarballs |
| `libffi-dev` | FFI headers — required by Python `cffi`/`ctypes` based packages |
| `libssl-dev` | OpenSSL headers — required by Python `cryptography` and similar packages |
| `openssh-client` | SSH client for git-over-SSH and remote access |
| `unzip` | Required by mise to extract `.zip` archives |
| `zlib1g-dev` | zlib headers — required by Python compression packages |

A non-root `agent` user (UID/GID 1001) owns everything inside the container.
Tools are installed into that user's home directory, not system-wide.

The `entrypoint.sh` is minimal by design:

```bash
if [ $# -eq 0 ]; then exec /bin/bash; fi
exec "$@"
```

No arguments → interactive shell. Any arguments → run them directly. This
means you can run any tool in the image without a dedicated wrapper.

### Managed tools (`mise.toml`)

All versions are pinned. Update a version in `mise.toml` and rebuild to
upgrade.

#### Coding agents

| Tool | Command | Notes |
|------|---------|-------|
| `claude-code` | `claude` | Anthropic Claude Code agent |
| `opencode` | `opencode` | OpenCode AI coding agent |
| `gemini` | `gemini` | Google Gemini CLI agent |
| `copilot` | `copilot` | GitHub Copilot CLI |

#### Languages & runtimes

| Tool | Command | Notes |
|------|---------|-------|
| `go` | `go` | Go toolchain |
| `node` | `node` | Node.js runtime |
| `npm` | `npm` | Node package manager |
| `python` | `python` | Python runtime |
| `pipx` | `pipx` | Python app installer |
| `uv` | `uv` | Fast Python package manager (used by `azure-cli`) |

#### Kubernetes & GitOps

| Tool | Command | Notes |
|------|---------|-------|
| `kubectl` | `kubectl` | Kubernetes CLI |
| `helm` | `helm` | Kubernetes package manager |
| `kustomize` | `kustomize` | Kubernetes configuration layering |
| `flux2` | `flux` | Flux CD CLI |
| `flux-operator` | `flux-operator` | Flux Operator CLI |
| `flux-operator-mcp` | — | MCP server for Flux Operator |
| `istioctl` | `istioctl` | Istio service mesh CLI |
| `kyverno` | `kyverno` | Policy engine CLI |
| `kubeconform` | `kubeconform` | Kubernetes manifest validator |
| `azure-kubelogin` | `kubelogin` | Azure AD kubeconfig token helper |
| `grafana-kubernetes-plugin` | — | Grafana K8s plugin |

#### Cloud & infrastructure

| Tool | Command | Notes |
|------|---------|-------|
| `azure-cli` | `az` | Azure CLI |
| `terraform` | `terraform` | Infrastructure as code |
| `vault` | `vault` | HashiCorp Vault CLI |
| `sops` | `sops` | Secrets encryption/decryption |
| `age` | `age` | Modern encryption (used with sops) |

#### Utilities

| Tool | Command | Notes |
|------|---------|-------|
| `gh` | `gh` | GitHub CLI |
| `jq` | `jq` | JSON processor |
| `yq` | `yq` | YAML processor |
