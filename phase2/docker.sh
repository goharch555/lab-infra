#!/usr/bin/env bash
# docker.sh — s4 pe Docker CE (official apt repo), saare packages pinned + hold; gohar → docker group.
#
# Istemaal (s4 pe, root se):  sudo bash docker.sh
# ⚠️ docker group = root ke barabar access (docs/phase2.md dekho).
# Idempotent hai.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
log()  { echo "[$(hostname)] [docker] $*"; }
fail() { echo "[$(hostname)] [docker] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
[[ "$(hostname)" == "$REGISTRY_NODE" ]] || fail "Docker sirf ${REGISTRY_NODE} pe (k8s nodes pe NAHI)"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
# apt ke locks khaali hone ka intezar (boot ke baad apt-daily) — phase1/k8s-packages.sh jaisa
wait_apt_locks() {
  local i
  for i in $(seq 1 60); do
    fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1 || return 0
    [[ $i -eq 1 ]] && log "apt doosre process ke paas hai — intezar"
    sleep 5
  done
  fail "5 min baad bhi apt lock khaali nahi"
}
LOGIN_USER="${SUDO_USER:-gohar}"
KEYRING="/etc/apt/keyrings/docker.asc"
LIST="/etc/apt/sources.list.d/docker.list"
DOCKER_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# --- Step 1: Repo key (fingerprint verify) + source ----------------------------------------
install -d -m 0755 /etc/apt/keyrings
tmp="$(mktemp)"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp"
fpr="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
[[ "$fpr" == "$DOCKER_FPR" ]] || { rm -f "$tmp"; fail "Docker GPG key ka fingerprint ghalat: ${fpr}"; }
if ! cmp -s "$tmp" "$KEYRING"; then install -m 0644 "$tmp" "$KEYRING"; log "GPG key likhi (fingerprint OK)"; fi
rm -f "$tmp"
# shellcheck disable=SC1091
DESIRED_LIST="deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING}] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"
if [[ "$(cat "$LIST" 2>/dev/null)" != "$DESIRED_LIST" ]]; then echo "$DESIRED_LIST" > "$LIST"; log "${LIST} likha"; fi
wait_apt_locks; apt-get update -o DPkg::Lock::Timeout=300 -qq

# --- Step 2: Exact versions install + hold -------------------------------------------------------
declare -A WANT=(
  [docker-ce]="$DOCKER_CE_VERSION" [docker-ce-cli]="$DOCKER_CE_VERSION" [containerd.io]="$CONTAINERD_PKG_VERSION"
  [docker-buildx-plugin]="$BUILDX_VERSION" [docker-compose-plugin]="$COMPOSE_VERSION"
)
to_install=()
for p in "${!WANT[@]}"; do
  [[ "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)" == "${WANT[$p]}" ]] || to_install+=("${p}=${WANT[$p]}")
done
if [[ ${#to_install[@]} -gt 0 ]]; then
  apt-mark unhold "${!WANT[@]}" >/dev/null 2>&1 || true
  wait_apt_locks
  apt-get install "${APT_OPTS[@]}" "${to_install[@]}"
  log "install kiye: ${to_install[*]}"
else
  log "saare Docker packages pehle se sahi version pe"
fi
apt-mark hold "${!WANT[@]}" >/dev/null
systemctl enable --now docker containerd >/dev/null 2>&1

# --- Step 3: gohar → docker group (⚠️ = root access) ---------------------------------------------
if ! grep -qw docker <<<"$(id -nG "$LOGIN_USER")"; then
  usermod -aG docker "$LOGIN_USER"
  log "${LOGIN_USER} ko docker group mein daala (nayi login session se lagu hoga)"
fi

# --- Verify -------------------------------------------------------------------------------------
held="$(apt-mark showhold)"
for p in "${!WANT[@]}"; do grep -qx "$p" <<<"$held" || fail "${p} hold nahi"; done
docker info --format '{{.ServerVersion}} cgroup={{.CgroupDriver}}/{{.CgroupVersion}}' >/dev/null || fail "docker daemon nahi chal raha"
log "verify: docker $(docker version --format '{{.Server.Version}}'), compose $(docker compose version --short), buildx $(docker buildx version | awk '{print $2}'), containerd $(containerd --version | awk '{print $3}'); held: $(grep -E '^(docker|containerd)' <<<"$held" | xargs)"
log "DONE"
