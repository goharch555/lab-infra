#!/usr/bin/env bash
# run-phase0.sh — s1 se Phase 0 ko har node pe chalata hai (scp + ssh).
#
# Istemaal (s1 pe, user gohar se):
#   ./run-phase0.sh              # sab nodes, tarteeb: s4 s3 s2 s1
#   ./run-phase0.sh s4 s3        # sirf diye gaye nodes
# Har node: files copy -> common.sh -> (k8s-prereqs.sh) -> zaroorat ho to reboot + intezar.
# Aik waqt mein aik node. Koi step fail ho to wahin ruk jata hai (set -e).
# ssh-hardening.sh yahan se NAHI chalti — wo alag, confirmation ke baad.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=inventory.sh
source "${SCRIPT_DIR}/inventory.sh"

SSH_USER="gohar"
REMOTE_DIR="/tmp/lab-infra-phase0"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
LOG_DIR="${SCRIPT_DIR}/logs"     # .gitignore mein hai
mkdir -p "$LOG_DIR"

log() { echo "[run-phase0] $(date -u +%H:%M:%S) $*"; }
in_list() { local x="$1"; shift; for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done; return 1; }

# Kaunse nodes chalane hain
if [[ $# -gt 0 ]]; then NODES=("$@"); else NODES=("${NODE_ORDER[@]}"); fi

# Reboot karo aur wapas aane ka intezar (max 5 min)
reboot_and_wait() {
  local node="$1" ip="$2" boot_before
  boot_before="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'cat /proc/sys/kernel/random/boot_id')"
  log "${node}: reboot kar raha hoon"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'sudo systemctl reboot' || true
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    sleep 5
    local boot_now
    boot_now="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    # boot_id badal gaya = node naye boot ke saath wapas aa gaya
    if [[ -n "$boot_now" && "$boot_now" != "$boot_before" ]]; then
      log "${node}: wapas aa gaya ($(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'uptime -p'))"
      return 0
    fi
  done
  log "${node}: ERROR 5 min mein wapas nahi aaya"; return 1
}

for node in "${NODES[@]}"; do
  ip="${NODE_IP[$node]:?unknown node ${node}}"
  logfile="${LOG_DIR}/${node}-$(date -u +%Y%m%dT%H%M%SZ).log"
  log "===== ${node} (${ip}) — ${NODE_ROLE[$node]} — log: ${logfile}"

  # Files node pe copy karo (purani copy hata kar)
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "rm -rf '${REMOTE_DIR}' && mkdir -p '${REMOTE_DIR}'"
  scp -q "${SSH_OPTS[@]}" "${SCRIPT_DIR}"/*.sh "${SSH_USER}@${ip}:${REMOTE_DIR}/"

  # common.sh
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "sudo bash '${REMOTE_DIR}/common.sh' '${node}'" 2>&1 | tee -a "$logfile"

  # k8s-prereqs.sh (s1/s2 full, s3 swap-only)
  if in_list "$node" "${K8S_NODES[@]}"; then
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "sudo bash '${REMOTE_DIR}/k8s-prereqs.sh'" 2>&1 | tee -a "$logfile"
  elif in_list "$node" "${SWAP_ONLY_NODES[@]}"; then
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "sudo bash '${REMOTE_DIR}/k8s-prereqs.sh' --swap-only" 2>&1 | tee -a "$logfile"
  fi

  # Reboot zaroori ho to (s1 ko yahan se reboot nahi karte — orchestrator khud s1 pe chal raha hai)
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" 'test -f /var/run/reboot-required'; then
    if [[ "$(hostname)" == "$node" ]]; then
      log "${node}: REBOOT_REQUIRED — ye wohi machine hai jahan se script chal rahi hai; khud 'sudo reboot' karo"
    else
      reboot_and_wait "$node" "$ip"
    fi
  fi
  log "===== ${node} mukammal"
done
log "Phase 0 run khatam: ${NODES[*]}"
