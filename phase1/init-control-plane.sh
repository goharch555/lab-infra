#!/usr/bin/env bash
# init-control-plane.sh — s1 pe kubeadm se control-plane banao (config FILE se), phir kubeconfig.
#
# Istemaal (s1 pe, root se):  sudo bash init-control-plane.sh
# Idempotent hai: cluster pehle se bana ho (/etc/kubernetes/admin.conf mojood) to init dobara NAHI hota.
# Fail ho to kubeadm reset NAHI karti — ruk kar error dikhati hai.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
CONFIG="${SCRIPT_DIR}/kubeadm-config.yaml"

log()  { echo "[$(hostname)] [init-control-plane] $*"; }
fail() { echo "[$(hostname)] [init-control-plane] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
[[ "$(hostname)" == "$CONTROL_PLANE_NODE" ]] || fail "ye sirf ${CONTROL_PLANE_NODE} pe chalti hai"
[[ -f "$CONFIG" ]] || fail "${CONFIG} nahi mila"
LOGIN_USER="${SUDO_USER:-gohar}"
LOGIN_HOME="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
export KUBECONFIG=/etc/kubernetes/admin.conf

# --- Step 1: Pre-checks -------------------------------------------------------------------
# controlPlaneEndpoint ka naam isi node ke IP pe resolve ho (Phase 0 ka /etc/hosts)
[[ "$(getent hosts "${CONTROL_PLANE_ENDPOINT%%:*}" | awk '{print $1}')" == "$CONTROL_PLANE_IP" ]] \
  || fail "${CONTROL_PLANE_ENDPOINT%%:*} ${CONTROL_PLANE_IP} pe resolve nahi hota"
# Config file mein version versions.sh se match kare
grep -q "kubernetesVersion: ${K8S_VERSION}$" "$CONFIG" || fail "kubeadm-config.yaml ka kubernetesVersion ${K8S_VERSION} nahi"
# Config file ki schema validation
kubeadm config validate --config "$CONFIG" >/dev/null || fail "kubeadm config validate fail"
log "config validate OK"

if [[ -f /etc/kubernetes/admin.conf ]]; then
  log "cluster pehle se bana hua hai (admin.conf mojood) — init skip"
else
  # --- Step 2: Images pehle pull (init tez aur network masla pehle pakra jaye) --------------
  kubeadm config images pull --config "$CONFIG"

  # --- Step 3: Dry-run — kuch badalta nahi, sirf dikhata hai kya hoga ------------------------
  log "dry-run chala raha hoon"
  dry_log="$(mktemp)"
  if ! kubeadm init --config "$CONFIG" --dry-run > "$dry_log" 2>&1; then
    tail -30 "$dry_log"; rm -f "$dry_log"; fail "kubeadm init --dry-run fail — asal init nahi kiya"
  fi
  grep -E "^\[preflight\]|WARNING|error" "$dry_log" | head -20 || true
  rm -f "$dry_log"
  log "dry-run OK"

  # --- Step 4: Asal init ---------------------------------------------------------------------
  # Output mein bootstrap token hota hai → ise sirf root-only file mein rakho, kahin commit nahi.
  init_log="/root/kubeadm-init-$(date -u +%Y%m%dT%H%M%SZ).log"
  log "kubeadm init chala raha hoon (output: ${init_log}, sirf root parh sakta hai)"
  ( umask 077; kubeadm init --config "$CONFIG" > "$init_log" 2>&1 ) || { tail -40 "$init_log"; fail "kubeadm init fail — reset NAHI kiya, upar error dekho"; }
  grep -vE "token|discovery-token|certificate-key" "$init_log" | grep -E "^\[(preflight|certs|kubeconfig|etcd|control-plane|kubelet-start|mark-control-plane|bootstrap-token|addons)\]" | tail -15 || true
  log "kubeadm init mukammal"
fi

# --- Step 5: kubeconfig gohar ke liye (600) -------------------------------------------------
install -d -m 0700 -o "$LOGIN_USER" -g "$LOGIN_USER" "${LOGIN_HOME}/.kube"
# Sirf tab likho jab file mojood hi na ho. Phase 3 ke baad is file mein doosre contexts (lab-mgmt) bhi
# hain — overwrite karne se wo mit jate. (Workload context ka naam phase3/kubeconfig-s1.sh "lab-workload" rakhti hai.)
if [[ ! -f "${LOGIN_HOME}/.kube/config" ]]; then
  install -m 0600 -o "$LOGIN_USER" -g "$LOGIN_USER" /etc/kubernetes/admin.conf "${LOGIN_HOME}/.kube/config"
  log "${LOGIN_HOME}/.kube/config likha (600)"
else
  log "${LOGIN_HOME}/.kube/config pehle se mojood — overwrite NAHI (doosre contexts mehfooz)"
fi

# --- Step 6: kubectl bash completion (sab users ke liye) ------------------------------------
COMP="/etc/bash_completion.d/kubectl"
tmp="$(mktemp)"; kubectl completion bash > "$tmp"
if ! cmp -s "$tmp" "$COMP"; then install -m 0644 "$tmp" "$COMP"; log "kubectl bash completion ${COMP}"; fi
rm -f "$tmp"

# --- Verify ----------------------------------------------------------------------------------
for _ in $(seq 1 60); do kubectl get --raw=/readyz >/dev/null 2>&1 && break; sleep 2; done
kubectl get --raw=/readyz >/dev/null || fail "API server ready nahi"
# Control-plane taint lagi rehni chahiye (production: s1 pe apps nahi)
grep -q "node-role.kubernetes.io/control-plane" <<<"$(kubectl get node "$CONTROL_PLANE_NODE" -o jsonpath='{.spec.taints[*].key}')" \
  || fail "control-plane taint nahi mili"
log "verify: API /readyz OK, taint node-role.kubernetes.io/control-plane:NoSchedule maujood"
kubectl get nodes -o wide
log "DONE (node NotReady rahega jab tak CNI (Calico) na lage — ye normal hai)"
