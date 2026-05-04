#!/usr/bin/env bash
# agent-wrapper.sh — intercepts coding-agent commands and runs them inside the
# agent-sandbox container instead of executing them locally.
#
# INSTALLATION
#   Symlink this script — do NOT copy it — to ~/.local/bin/ under each agent
#   name you want to intercept:
#
#     ln -sf "$(pwd)/agent-wrapper.sh" ~/.local/bin/agent-wrapper
#     ln -sf agent-wrapper ~/.local/bin/opencode
#     ln -sf agent-wrapper ~/.local/bin/claude
#     ln -sf agent-wrapper ~/.local/bin/gemini
#     ln -sf agent-wrapper ~/.local/bin/copilot
#
#   A symlink is required because this script loads .env from the repo root by
#   resolving its own real path (see below).  A copied script would look for
#   .env in ~/.local/bin/ instead of the repo and never find it.  A symlink
#   also means git pull picks up future wrapper changes without reinstalling.
#
#   Make sure ~/.local/bin is early in your $PATH so these wrappers shadow any
#   locally installed agent binaries.
#
# CONFIGURATION  (all optional)
#
#   Persistent machine-local settings belong in a .env file in the repo root.
#   That file is gitignored so git pull will never overwrite it.
#   Copy .env.example to .env to get started.
#
#   NOTE: .env is loaded by resolving the real path of this script.  It is
#   only found when this file is installed as a symlink into the repo (the
#   recommended approach).  If you copy the script to ~/.local/bin/ instead,
#   the .env file will not be loaded.
#
#   Variables already exported in the calling shell take precedence over .env,
#   which in turn takes precedence over the built-in defaults below.
#
#   AGENT_SANDBOX_IMAGE      Image name / tag to run
#                            (default: ghcr.io/monotek/agent-sandbox:main)
#   AGENT_SANDBOX_DIR        Host directory that holds all agent configs and
#                            credentials (default: ~/agent-sandbox).
#                            Agent config subdirs (.claude, .config/opencode,
#                            .copilot, .gemini, .config/gh) are mounted
#                            automatically when they exist inside this directory.
#   AGENT_SANDBOX_KUBE       Host path to mount as /home/agent/.kube (read-only).
#                            Not set by default — no kubeconfig is mounted unless
#                            explicitly provided here.
#   AGENT_SANDBOX_ENV        Comma-separated list of host env-var names to pass
#                            into the container  (e.g. ANTHROPIC_API_KEY)
#   AGENT_SANDBOX_MOUNTS     Newline-separated list of additional -v mount specs
#                            in standard Docker/Podman format: /src:/dst[:opts]
#                            These are added on top of the auto-detected mounts.
#                            Example (in ~/.bashrc or shell profile):
#                              export AGENT_SANDBOX_MOUNTS="
#                              /mnt/shared/data:/home/agent/data
#                              /opt/certs:/home/agent/certs:ro
#                              "
#
# HOW IT WORKS
#   1. Mounts the current working directory as /home/agent/workdir inside the
#      container and sets that as the container working directory.
#   2. Mounts agent config directories from AGENT_SANDBOX_DIR that exist on the host.
#   3. Forwards the SSH agent socket so git-over-SSH works inside the container.
#   4. Appends any mounts from AGENT_SANDBOX_MOUNTS.
#   5. Passes all CLI arguments unchanged to the container command.

set -euo pipefail

# ---------------------------------------------------------------------------
# .env — load machine-local config from the repo root, if present.
# Shell environment variables always win over .env values.
# Handles: blank lines, # comments, optional leading 'export', quoted values.
# ---------------------------------------------------------------------------
_AS_DIR="$(dirname "$(realpath "$0")")"
if [[ -f "${_AS_DIR}/.env" ]]; then
  while IFS= read -r _as_line || [[ -n "${_as_line}" ]]; do
    [[ -z "${_as_line//[[:space:]]/}" || "${_as_line}" =~ ^[[:space:]]*# ]] && continue
    _as_line="${_as_line#export }"
    [[ "${_as_line}" != *=* ]] && continue
    _as_key="${_as_line%%=*}"
    _as_val="${_as_line#*=}"
    [[ "${_as_val}" == '"'*'"' ]] && _as_val="${_as_val:1:${#_as_val}-2}"
    [[ "${_as_val}" == "'"*"'" ]] && _as_val="${_as_val:1:${#_as_val}-2}"
    [[ -v "${_as_key}" ]] || export "${_as_key}=${_as_val}"
  done < "${_AS_DIR}/.env"
fi
unset _AS_DIR _as_line _as_key _as_val

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
IMAGE="${AGENT_SANDBOX_IMAGE:-ghcr.io/monotek/agent-sandbox:main}"
AGENT_CMD="$(basename "$0")"
SANDBOX_DIR="${AGENT_SANDBOX_DIR:-${HOME}/agent-sandbox}"
SANDBOX_DIR="${SANDBOX_DIR%/}"

# ---------------------------------------------------------------------------
# Working directory — mount CWD and use it as the container working directory
# ---------------------------------------------------------------------------
HOST_CWD="$(pwd)"
CONTAINER_CWD="/home/agent/workdir"
WORKDIR_MOUNT="${HOST_CWD}:${CONTAINER_CWD}"

# ---------------------------------------------------------------------------
# TTY flags — attach a pseudo-TTY only when stdin/stdout are terminals
# ---------------------------------------------------------------------------
TTY_FLAGS=()
[[ -t 0 && -t 1 ]] && TTY_FLAGS=(-it)

# ---------------------------------------------------------------------------
# Volume mounts
# ---------------------------------------------------------------------------
declare -a MOUNTS=()

MOUNTS+=(-v "${WORKDIR_MOUNT}")

mkdir -p \
  "${SANDBOX_DIR}/.claude" \
  "${SANDBOX_DIR}/.config/opencode" \
  "${SANDBOX_DIR}/.copilot" \
  "${SANDBOX_DIR}/.gemini" \
  "${SANDBOX_DIR}/.config/gh"

MOUNTS+=(-v "${SANDBOX_DIR}/.claude:/home/agent/.claude")
MOUNTS+=(-v "${SANDBOX_DIR}/.config/opencode:/home/agent/.config/opencode")
MOUNTS+=(-v "${SANDBOX_DIR}/.copilot:/home/agent/.copilot")
MOUNTS+=(-v "${SANDBOX_DIR}/.gemini:/home/agent/.gemini")
MOUNTS+=(-v "${SANDBOX_DIR}/.config/gh:/home/agent/.config/gh:ro")

[[ -n "${AGENT_SANDBOX_KUBE:-}" ]] && mkdir -p "${AGENT_SANDBOX_KUBE}"
[[ -n "${AGENT_SANDBOX_KUBE:-}" ]] && MOUNTS+=(-v "${AGENT_SANDBOX_KUBE}:/home/agent/.kube:ro")

[[ -f "${HOME}/.gitconfig" ]] && MOUNTS+=(-v "${HOME}/.gitconfig:/home/agent/.gitconfig:ro")

# ---------------------------------------------------------------------------
# SSH agent forwarding — lets git-over-SSH work without copying private keys
# ---------------------------------------------------------------------------
declare -a ENV_FLAGS=()

if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
  MOUNTS+=(-v "${SSH_AUTH_SOCK}:/run/ssh-agent.sock")
  ENV_FLAGS+=(-e "SSH_AUTH_SOCK=/run/ssh-agent.sock")
fi

# ---------------------------------------------------------------------------
# Extra mounts from AGENT_SANDBOX_MOUNTS (newline-separated /src:/dst[:opts])
# ---------------------------------------------------------------------------
while IFS= read -r mount_spec; do
  mount_spec="${mount_spec#"${mount_spec%%[![:space:]]*}"}"
  mount_spec="${mount_spec%"${mount_spec##*[![:space:]]}"}"
  [[ -n "${mount_spec}" ]] && MOUNTS+=(-v "${mount_spec}")
done <<< "${AGENT_SANDBOX_MOUNTS:-}"

# ---------------------------------------------------------------------------
# Optional env-var pass-through (names only, not values, via AGENT_SANDBOX_ENV)
# ---------------------------------------------------------------------------
IFS=',' read -ra EXTRA_VARS <<< "${AGENT_SANDBOX_ENV:-}"
for var in "${EXTRA_VARS[@]}"; do
  [[ -n "${var}" && -v "${var}" ]] && ENV_FLAGS+=(-e "${var}=${!var}")
done

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
exec podman run --rm \
  --userns=keep-id:uid=1001,gid=1001 \
  "${TTY_FLAGS[@]}" \
  "${MOUNTS[@]}" \
  "${ENV_FLAGS[@]}" \
  -w "${CONTAINER_CWD}" \
  "${IMAGE}" \
  "${AGENT_CMD}" "$@"
