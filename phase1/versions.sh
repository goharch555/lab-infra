#!/usr/bin/env bash
# versions.sh — Phase 1 ke saare pinned versions aik jagah. Baaqi scripts isay "source" karti hain.
# Version badalna ho to SIRF yahan badlo (aur docs/phase1.md mein note karo).

# Kubernetes (pkgs.k8s.io/core:/stable:/v1.37)
K8S_MINOR="v1.37"
K8S_VERSION="v1.37.1"          # kubeadm kubernetesVersion
K8S_PKG_VERSION="1.37.1-1.1"   # apt package version (kubelet/kubeadm/kubectl)
CRI_TOOLS_PKG_VERSION="1.37.0-1.1"   # crictl (ab kubeadm ki dependency nahi, alag install)

# containerd (Docker ki official apt repo se, SIRF containerd.io)
CONTAINERD_PKG_VERSION="2.4.2-2~ubuntu.24.04~noble"

# Calico (Tigera operator)
CALICO_VERSION="v3.33.0"

# Cluster
CLUSTER_NAME="lab-workload"
CONTROL_PLANE_NODE="s1"
CONTROL_PLANE_IP="192.168.2.11"
CONTROL_PLANE_ENDPOINT="k8s-api.lab.local:6443"
WORKER_NODES=(s2)
declare -A K8S_NODE_IP=([s1]="192.168.2.11" [s2]="192.168.2.12")
POD_SUBNET="10.244.0.0/16"
SERVICE_SUBNET="10.96.0.0/12"
NODE_IFACE="ens33"
