#!/usr/bin/env bash
# versions.sh — Phase 2 (registry) ke pinned versions aur settings. Baaqi scripts isay "source" karti hain.

# Registry
REGISTRY_HOST="registry.lab.local"
REGISTRY_IP="192.168.2.14"
REGISTRY_NODE="s4"
REGISTRY_IMAGE="registry:3.1.2@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8"   # tag + digest pin
REGISTRY_DIR="/srv/registry"
REGISTRY_USERS=(ci-push k8s-pull)
CREDS_DIR="/root/registry-credentials"     # passwords (600) — sirf s4 pe, KABHI repo mein nahi

# Lab CA (sirf s4 pe; private key KABHI kahin aur nahi)
CA_DIR="/root/lab-ca"
CA_SUBJECT="/CN=Lab Root CA/O=lab-infra"
CA_DAYS=3650           # 10 saal
SERVER_DAYS=365        # 1 saal
SERVER_RENEW_DAYS=30   # itne din reh jayen to server cert dobara banao

# Docker CE (s4) — Docker ki official apt repo
DOCKER_CE_VERSION="5:29.9.1-1~ubuntu.24.04~noble"
CONTAINERD_PKG_VERSION="2.4.2-2~ubuntu.24.04~noble"   # cluster (phase1) wala hi version
BUILDX_VERSION="0.38.0-1~ubuntu.24.04~noble"
COMPOSE_VERSION="5.6.0-1~ubuntu.24.04~noble"

# Test image (verify.sh) — chhoti public image, pinned tag
TEST_SRC_IMAGE="busybox:1.37.0"
TEST_REPO="test/busybox"
TEST_TAG="1.37.0"
