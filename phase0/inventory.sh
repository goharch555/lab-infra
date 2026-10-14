#!/usr/bin/env bash
# inventory.sh — lab ka naqsha (nodes, IPs, network). Baaqi scripts isay "source" karti hain.
# Isay chalaya nahi jata, sirf source kiya jata hai.

# VMware NAT network
GATEWAY="192.168.2.2"
PREFIX="24"
DNS_SERVERS=("192.168.2.2" "8.8.8.8")

# Node -> IP
declare -A NODE_IP=(
  [s1]="192.168.2.11"
  [s2]="192.168.2.12"
  [s3]="192.168.2.13"
  [s4]="192.168.2.14"
)

# Node -> role (sirf documentation/log ke liye)
declare -A NODE_ROLE=(
  [s1]="workload k8s control-plane (kubeadm)"
  [s2]="workload k8s worker (kubeadm)"
  [s3]="management cluster (k3s + Argo CD)"
  [s4]="CI runner + container registry"
)

# /etc/hosts mein jane wali lines (har node pe same)
HOSTS_ENTRIES=(
  "192.168.2.11 s1 k8s-api.lab.local"
  "192.168.2.12 s2"
  "192.168.2.13 s3 argocd.lab.local"
  "192.168.2.14 s4 registry.lab.local"
)

# Chalane ki tarteeb: s1 aakhir mein, kyunke orchestrator s1 se chal raha hai
NODE_ORDER=(s4 s3 s2 s1)

# Kis node pe kaunsi prereqs script/mode
K8S_NODES=(s1 s2)      # poori k8s-prereqs (swap + modules + sysctl)
SWAP_ONLY_NODES=(s3)   # sirf swap off (k3s ke liye)
