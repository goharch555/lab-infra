#!/usr/bin/env bash
# k3s.sh — s3 pe k3s (management cluster) — pinned version, config file install se PEHLE.
#
# Istemaal (s3 pe, root se):  sudo bash k3s.sh
# - /etc/rancher/k3s/config.yaml likhti hai (node-ip, tls-san, kubeconfig 0600, secrets-encryption).
# - Install script k3s ke USI version ke git tag se download (temp file; repo mein nahi), phir
#   INSTALL_K3S_VERSION ke saath chalti hai. Installer k3s binary ka sha256 khud verify karta hai.
# Idempotent: sahi version chal raha ho to install dobara nahi; config badli ho to sirf restart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
log()  { echo "[$(hostname)] [k3s] $*"; }
fail() { echo "[$(hostname)] [k3s] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
[[ "$(hostname)" == "$MGMT_NODE" ]] || fail "sirf ${MGMT_NODE} pe"
[[ -z "$(swapon --show --noheadings)" ]] || fail "swap on hai (Phase 0 k8s-prereqs --swap-only)"

# --- Step 1: config.yaml (install se PEHLE, taake pehli start hi sahi settings se ho) -------------
CFG="/etc/rancher/k3s/config.yaml"
DESIRED="$(cat <<EOF
# lab-infra phase3 (k3s.sh) — management cluster (s3)
node-ip: ${MGMT_IP}
tls-san:
  - ${MGMT_NODE}
  - ${MGMT_IP}
write-kubeconfig-mode: "0600"
secrets-encryption: true
# cluster-cidr 10.42.0.0/16 aur service-cidr 10.43.0.0/16 (k3s defaults) — workload cluster
# (10.244/16, 10.96/12) aur LAN (192.168.2.0/24) se overlap nahi. Traefik + ServiceLB ON (default).
EOF
)"
install -d -m 0755 /etc/rancher/k3s
cfg_changed=no
if [[ "$(cat "$CFG" 2>/dev/null)" != "$DESIRED" ]]; then
  printf '%s\n' "$DESIRED" > "$CFG"; chmod 600 "$CFG"
  cfg_changed=yes; log "${CFG} likha"
fi

# --- Step 2: Install (sirf agar version mukhtalif ho) ------------------------------------------------
have="$(k3s --version 2>/dev/null | awk '/^k3s version/{print $3}' || true)"
if [[ "$have" != "$K3S_VERSION" ]]; then
  log "k3s ${have:-<nahi>} → ${K3S_VERSION} install kar raha hoon"
  inst="$(mktemp)"; trap 'rm -f "$inst"' EXIT
  curl -fsSL -o "$inst" "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION}/install.sh"
  [[ "$(head -1 "$inst")" == "#!/bin/sh" ]] || fail "install.sh ajeeb hai"
  INSTALL_K3S_VERSION="$K3S_VERSION" sh "$inst"
  cfg_changed=no     # installer ne k3s naye config ke saath shuru kiya
  log "k3s install mukammal"
else
  log "k3s pehle se ${K3S_VERSION}"
fi
systemctl enable k3s >/dev/null 2>&1
if [[ "$cfg_changed" == "yes" ]]; then systemctl restart k3s; log "config badli → k3s restart"; fi
systemctl is-active --quiet k3s || systemctl start k3s

# --- Verify -------------------------------------------------------------------------------------------
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for _ in $(seq 1 60); do
  [[ "$(kubectl get node "$MGMT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && break
  sleep 5
done
[[ "$(kubectl get node "$MGMT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]] || fail "node Ready nahi"
# kube-system: saare deployments available (coredns, local-path, metrics-server, traefik).
# 15 min tak: Traefik ka deployment helm-install job ke baad banta hai, aur pehli dafa images download hoti hain.
for _ in $(seq 1 180); do
  dep_ok="$(kubectl -n kube-system get deploy -o jsonpath='{range .items[*]}{.metadata.name}={.status.availableReplicas}/{.spec.replicas} {end}')"
  [[ -n "$dep_ok" ]] && ! grep -qE '=(/|0/)' <<<"$dep_ok" && grep -q 'traefik=' <<<"$dep_ok" && break
  sleep 5
done
kubectl -n kube-system get deploy
grep -qE '=(/|0/)' <<<"$dep_ok" && fail "kube-system deployments available nahi: ${dep_ok}"
enc="$(k3s secrets-encrypt status)"
grep -q "Encryption Status: Enabled" <<<"$enc" || { echo "$enc"; fail "secrets encryption enabled nahi"; }
[[ "$(stat -c '%a' /etc/rancher/k3s/k3s.yaml)" == "600" ]] || fail "k3s.yaml 600 nahi"
log "verify: $(k3s --version | head -1 | awk '{print $3}'), node Ready, kube-system deployments OK, $(grep 'Encryption Status' <<<"$enc"), k3s.yaml 600"
log "DONE"
