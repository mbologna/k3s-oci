#!/usr/bin/env bash
# lib/two-phase-done.sh -- appended after the entry point (k3s-server.sh or
# k3s-agent.sh) by data.tf for two-phase OSes (see two-phase.sh). Reached only when
# the bootstrap ran to the end: retire the unit that re-runs it at boot.
# shellcheck disable=SC2154

touch "${K3S_OCI_DIR}/done"
systemctl disable "${K3S_OCI_UNIT}" 2>/dev/null || true
echo "==> Two-phase bootstrap complete; ${K3S_OCI_UNIT} disabled."
