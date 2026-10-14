#!/usr/bin/env bash
# verify.sh — Phase 0 ki report. Node pe chalao (kuch badalti nahi, sirf parhti hai).
#   bash verify.sh
# s1 se sab nodes ki report:
#   for ip in 192.168.2.1{1..4}; do ssh gohar@$ip 'bash -s' < verify.sh; done
set -euo pipefail

node="$(hostname)"
iface="$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
section() { echo; echo "--- $* ---"; }

echo "================= ${node} ================="
section hostnamectl;  hostnamectl | grep -E "Static hostname|Operating System|Kernel"
section "ip -4 addr show ${iface}"; ip -4 addr show "$iface"
section "ip route";   ip route
section "resolvectl query github.com"; resolvectl query github.com
section timedatectl;  timedatectl | grep -E "Time zone|synchronized"
section "free -h";    free -h
section nproc;        nproc
section "df -h /";    df -h /
section lsblk;        lsblk

if [[ "$node" == "s1" || "$node" == "s2" || "$node" == "s3" ]]; then
  section "swapon --show (khaali hona chahiye)"; swapon --show
fi
if [[ "$node" == "s1" || "$node" == "s2" ]]; then
  section "lsmod overlay/br_netfilter"; lsmod | grep -E "overlay|br_netfilter"
  section "sysctl net.ipv4.ip_forward"; sysctl net.ipv4.ip_forward
fi
section "getent hosts"; getent hosts k8s-api.lab.local registry.lab.local argocd.lab.local
