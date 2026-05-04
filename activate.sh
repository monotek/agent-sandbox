#!/usr/bin/env bash
# activate.sh — prints shell function definitions that shadow locally installed
# coding agent binaries with the agent-sandbox container wrapper.
#
# Shell functions take priority over every PATH entry, including directories
# dynamically injected by `mise activate`, so agents run in the container
# regardless of whether they are also installed locally via mise.
#
# USAGE — add to ~/.zshrc or ~/.bashrc:
#   eval "$(~/gitrepos/agent-sandbox/activate.sh)"
#
# The wrapper symlinks must already exist under AGENT_SANDBOX_BIN.
# Run the installation steps in the README first.
#
# AGENT_SANDBOX_BIN   Directory containing the agent-wrapper symlinks
#                     (default: ~/.local/bin)

WRAPPER_BIN="${AGENT_SANDBOX_BIN:-${HOME}/.local/bin}"

for agent in opencode claude gemini copilot; do
  printf '%s() { command "%s/%s" "$@"; }\n' "${agent}" "${WRAPPER_BIN}" "${agent}"
done
