#!/usr/bin/env bash
# containerd.sh — containerd.io (Docker ki official apt repo se, Docker Engine NAHI) + Kubernetes ke liye config.
#
# Istemaal (s1, s2 pe, root se):  sudo bash containerd.sh
# Shart: k8s-packages.sh pehle chal chuki ho (sandbox image "kubeadm config images list" se aati hai).
# Idempotent hai: config sirf tab likhi aur containerd sirf tab restart hota hai jab kuch badla ho.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"

log()  { echo "[$(hostname)] [containerd] $*"; }
fail() { echo "[$(hostname)] [containerd] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
command -v kubeadm >/dev/null || fail "kubeadm nahi mila — pehle k8s-packages.sh chalao"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
# apt ke locks khaali hone ka intezar (max 5 min). Boot ke baad apt-daily/unattended-upgrades chal sakte
# hain; "DPkg::Lock::Timeout" sirf dpkg lock pe lagta hai, "apt-get update" wale lists lock pe nahi.
wait_apt_locks() {
  local i
  for i in $(seq 1 60); do
    fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1 || return 0
    [[ $i -eq 1 ]] && log "apt doosre process (apt-daily?) ke paas hai — intezar"
    sleep 5
  done
  fail "5 min baad bhi apt lock khaali nahi"
}

KEYRING="/etc/apt/keyrings/docker.asc"
LIST="/etc/apt/sources.list.d/docker.list"
DOCKER_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"   # Docker ki official repo key ka fingerprint
CONFIG="/etc/containerd/config.toml"
CERTS_D="/etc/containerd/certs.d"

# --- Step 1: Docker repo key (fingerprint verify karke) ---------------------------------
install -d -m 0755 /etc/apt/keyrings
tmp="$(mktemp)"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp"
fpr="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
[[ "$fpr" == "$DOCKER_FPR" ]] || { rm -f "$tmp"; fail "Docker GPG key ka fingerprint ghalat: ${fpr}"; }
if ! cmp -s "$tmp" "$KEYRING"; then install -m 0644 "$tmp" "$KEYRING"; log "GPG key ${KEYRING} likhi (fingerprint OK)"; fi
rm -f "$tmp"

# --- Step 2: apt source ---------------------------------------------------------------------
# shellcheck disable=SC1091
DESIRED_LIST="deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING}] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"
if [[ "$(cat "$LIST" 2>/dev/null)" != "$DESIRED_LIST" ]]; then echo "$DESIRED_LIST" > "$LIST"; log "${LIST} likha"; fi
wait_apt_locks; apt-get update -o DPkg::Lock::Timeout=300 -qq

# --- Step 3: SIRF containerd.io, exact version + hold ---------------------------------------
if [[ "$(dpkg-query -W -f='${Version}' containerd.io 2>/dev/null || true)" != "$CONTAINERD_PKG_VERSION" ]]; then
  apt-mark unhold containerd.io >/dev/null 2>&1 || true
  apt-get install "${APT_OPTS[@]}" "containerd.io=${CONTAINERD_PKG_VERSION}"
  log "containerd.io ${CONTAINERD_PKG_VERSION} install kiya"
else
  log "containerd.io pehle se ${CONTAINERD_PKG_VERSION}"
fi
apt-mark hold containerd.io >/dev/null
# Docker Engine install NAHI hona chahiye
! dpkg -s docker-ce >/dev/null 2>&1 || fail "docker-ce install hai — Phase 1 mein Docker Engine nahi chahiye"

# --- Step 4: config.toml = "containerd config default" + 3 badlaav --------------------------
# Sandbox (pause) image wohi jo kubeadm is Kubernetes version ke liye batata hai
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "$K8S_VERSION" 2>/dev/null | grep '/pause:')"
[[ -n "$PAUSE_IMAGE" ]] || fail "kubeadm se pause image nahi mili"

# Section ke andar hi key badlo (config_path do sections mein hai, is liye simple sed khatarnak hai)
#   SystemdCgroup  -> runc options section
#   config_path    -> CRI images registry section AUR transfer service section
#   sandbox        -> CRI images pinned_images section
desired="$(mktemp)"
containerd config default | awk -v pause="$PAUSE_IMAGE" -v certs="$CERTS_D" -v q="'" '
  BEGIN {
    S_RUNC = "[plugins." q "io.containerd.cri.v1.runtime" q ".containerd.runtimes.runc.options]"
    S_REG  = "[plugins." q "io.containerd.cri.v1.images" q ".registry]"
    S_XFER = "[plugins." q "io.containerd.transfer.v1.local" q "]"
    S_PIN  = "[plugins." q "io.containerd.cri.v1.images" q ".pinned_images]"
  }
  /^[[:space:]]*\[/ { sec=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", sec) }
  sec==S_RUNC && /^[[:space:]]*SystemdCgroup =/ { sub(/=.*/, "= true"); n1++ }
  sec==S_REG  && /^[[:space:]]*config_path =/   { sub(/=.*/, "= " q certs q); n2++ }
  sec==S_XFER && /^[[:space:]]*config_path =/   { sub(/=.*/, "= " q certs q); n3++ }
  sec==S_PIN  && /^[[:space:]]*sandbox =/       { sub(/=.*/, "= " q pause q); n4++ }
  { print }
  END { if (n1!=1 || n2!=1 || n3!=1 || n4!=1) { printf "awk: badlaav count ghalat (%d %d %d %d)\n", n1,n2,n3,n4 > "/dev/stderr"; exit 3 } }
' > "$desired" || { rm -f "$desired"; fail "config.toml banana fail (containerd default config ka format badla?)"; }

install -d -m 0755 "$CERTS_D"
changed=no
if ! cmp -s "$desired" "$CONFIG"; then
  [[ -f "$CONFIG" && ! -f "${CONFIG}.orig-package" ]] && cp -a "$CONFIG" "${CONFIG}.orig-package"   # package wali asal file
  install -m 0644 "$desired" "$CONFIG"
  changed=yes
  log "${CONFIG} likhi (SystemdCgroup=true, config_path=${CERTS_D} x2, sandbox=${PAUSE_IMAGE})"
else
  log "${CONFIG} pehle se theek"
fi
rm -f "$desired"

# --- Step 5: crictl ko containerd ka socket batao ------------------------------------------
CRICTL_CONF="/etc/crictl.yaml"
DESIRED_CRICTL=$'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\ntimeout: 10\ndebug: false'
if [[ "$(cat "$CRICTL_CONF" 2>/dev/null)" != "$DESIRED_CRICTL" ]]; then
  printf '%s\n' "$DESIRED_CRICTL" > "$CRICTL_CONF"; log "${CRICTL_CONF} likha"
fi

# --- Step 6: containerd chalao (config badli ho to restart) ---------------------------------
systemctl enable containerd >/dev/null 2>&1
if [[ "$changed" == "yes" ]] || ! systemctl is-active --quiet containerd; then
  systemctl restart containerd
  log "containerd restart kiya"
fi

# --- Verify: effective config (containerd ne asal mein kya parha) -------------------------
for _ in $(seq 1 15); do crictl info >/dev/null 2>&1 && break; sleep 1; done
eff="$(containerd config dump)"
grep -qE "^\s*SystemdCgroup = true" <<<"$eff"                 || fail "SystemdCgroup true nahi"
[[ "$(grep -cE "^\s*config_path = '${CERTS_D}'" <<<"$eff")" -ge 2 ]] || fail "config_path dono jagah nahi"
grep -qE "^\s*sandbox = '${PAUSE_IMAGE}'" <<<"$eff"           || fail "sandbox image ${PAUSE_IMAGE} nahi"
! grep -qE '^disabled_plugins = \[.*cri' <<<"$eff"             || fail "CRI plugin disabled hai"
crictl info >/dev/null                                         || fail "crictl containerd se baat nahi kar pa raha"
log "verify: $(containerd --version | awk '{print $3}'), CRI OK, SystemdCgroup=true, certs.d x2, sandbox=${PAUSE_IMAGE}, held=$(apt-mark showhold | grep -x containerd.io)"
log "DONE"
