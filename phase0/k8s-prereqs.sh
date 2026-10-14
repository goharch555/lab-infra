#!/usr/bin/env bash
# k8s-prereqs.sh — Kubernetes (kubeadm) ki OS zarooriyat. Koi runtime/Kubernetes install NAHI karti.
#
# Istemaal (node pe, root se):
#   sudo bash k8s-prereqs.sh              # s1, s2: swap off + kernel modules + sysctl
#   sudo bash k8s-prereqs.sh --swap-only  # s3: sirf swap off (k3s ke liye)
# Idempotent hai.
set -euo pipefail

MODE="${1:-full}"
log()  { echo "[$(hostname)] [k8s-prereqs] $*"; }
fail() { echo "[$(hostname)] [k8s-prereqs] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "root se chalao"
[[ "$MODE" == "full" || "$MODE" == "--swap-only" ]] || fail "na-maloom option: ${MODE}"

# =============================================================================
# Step 6: Swap band karo (abhi bhi, aur reboot ke baad bhi)
# =============================================================================
# Abhi ke liye swap band
if [[ -n "$(swapon --show --noheadings)" ]]; then
  swapoff -a
  log "swapoff -a kiya"
else
  log "swap pehle se band"
fi

# /etc/fstab mein swap wali har active line comment karo (taake reboot pe wapas na aaye)
if awk '$1 !~ /^#/ && $3 == "swap" {found=1} END {exit !found}' /etc/fstab; then
  [[ -f /root/fstab.bak-phase0 ]] || cp -a /etc/fstab /root/fstab.bak-phase0   # pehli dafa ka backup
  tmp="$(mktemp)"
  awk '$1 !~ /^#/ && $3 == "swap" {print "# disabled by lab-infra phase0: " $0; next} {print}' /etc/fstab > "$tmp"
  install -m 0644 -o root -g root "$tmp" /etc/fstab
  rm -f "$tmp"
  systemctl daemon-reload   # fstab se bane swap units refresh
  log "/etc/fstab mein swap line comment ki"
else
  log "/etc/fstab mein koi active swap line nahi"
fi

# Verify
[[ -z "$(swapon --show --noheadings)" ]] || fail "swap abhi bhi on hai"
log "verify: swap off"

if [[ "$MODE" == "--swap-only" ]]; then
  log "DONE (swap-only)"
  exit 0
fi

# =============================================================================
# Step 7: Kernel modules — overlay, br_netfilter (boot pe bhi load hon)
# =============================================================================
MODULES_FILE="/etc/modules-load.d/k8s.conf"
DESIRED_MODULES=$'overlay\nbr_netfilter'
if [[ "$(cat "$MODULES_FILE" 2>/dev/null)" != "$DESIRED_MODULES" ]]; then
  printf '%s\n' "$DESIRED_MODULES" > "$MODULES_FILE"
  log "${MODULES_FILE} likha"
fi
# Abhi load karo (modprobe already-loaded module pe kuch nahi karta)
modprobe overlay
modprobe br_netfilter
lsmod | grep -qw overlay      || fail "overlay load nahi hua"
lsmod | grep -qw br_netfilter || fail "br_netfilter load nahi hua"
log "verify: overlay + br_netfilter loaded"

# =============================================================================
# Step 8: sysctl — bridge traffic iptables se guzre, IP forwarding on
# =============================================================================
SYSCTL_FILE="/etc/sysctl.d/k8s.conf"
DESIRED_SYSCTL=$'net.bridge.bridge-nf-call-iptables  = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward                 = 1'
if [[ "$(cat "$SYSCTL_FILE" 2>/dev/null)" != "$DESIRED_SYSCTL" ]]; then
  printf '%s\n' "$DESIRED_SYSCTL" > "$SYSCTL_FILE"
  log "${SYSCTL_FILE} likha"
fi
sysctl --system >/dev/null

# Verify
for key in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
  [[ "$(sysctl -n "$key")" == "1" ]] || fail "${key} != 1"
done
log "verify: sysctl values = 1"
log "DONE"
