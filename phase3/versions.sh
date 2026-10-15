#!/usr/bin/env bash
# versions.sh — Phase 3 (management cluster) ke pinned versions aur settings. Baaqi scripts isay "source" karti hain.

# k3s (s3) — k3s ka "stable" channel (update.k3s.io/v1-release/channels/stable), 2026-10-15
K3S_VERSION="v1.36.5+k3s1"
MGMT_NODE="s3"
MGMT_IP="192.168.2.13"
MGMT_CONTEXT="lab-mgmt"
WORKLOAD_CONTEXT="lab-workload"

# Helm (s3) — v4.3.1 sirf 1 din purana tha; aik release peeche (v4.3.0, 2026-09-09) liya
HELM_VERSION="v4.3.0"
HELM_SHA256="86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb"   # helm-v4.3.0-linux-amd64.tar.gz

# Argo CD
ARGOCD_CHART_REPO="https://argoproj.github.io/argo-helm"
ARGOCD_CHART_VERSION="10.10.5"     # argo/argo-cd chart
ARGOCD_VERSION="v3.5.5"            # chart ka appVersion (server) = CLI version
ARGOCD_NS="argocd"
ARGOCD_HOST="argocd.lab.local"

# Argo CD TLS cert (s3 pe key, s4 ki Lab Root CA se sign)
ARGOCD_TLS_DIR="/root/argocd-tls"  # s3 pe (700); key KABHI s3 se bahar nahi
CERT_DAYS=365
CERT_RENEW_DAYS=30
REGISTRY_IP="192.168.2.14"         # s4: Lab Root CA yahan hai (/root/lab-ca)
