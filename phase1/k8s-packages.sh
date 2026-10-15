#!/usr/bin/env bash
# k8s-packages.sh — kubelet, kubeadm, kubectl, cri-tools (pinned) pkgs.k8s.io se install + apt-mark hold.
#
# Istemaal (s1, s2 pe, root se):  sudo bash k8s-packages.sh
# Idempotent hai. Containerd se PEHLE chalti hai, kyunke containerd.sh sandbox (pause) image ka
# naam "kubeadm config images list" se leti hai.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"

log()  { echo "[$(hostname)] [k8s-packages] $*"; }
fail() { echo "[$(hostname)] [k8s-packages] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
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

KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
LIST="/etc/apt/sources.list.d/kubernetes.list"
REPO="https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/"

# --- Step 1: Repo ki GPG key (sirf isi repo ke liye, "signed-by" ke zariye) ---------------
install -d -m 0755 /etc/apt/keyrings
tmp="$(mktemp)"
curl -fsSL "${REPO}Release.key" | gpg --dearmor --yes -o "$tmp"
if ! cmp -s "$tmp" "$KEYRING"; then
  install -m 0644 "$tmp" "$KEYRING"
  log "GPG key ${KEYRING} likhi"
fi
rm -f "$tmp"

# --- Step 2: apt source (minor version ki repo: v1.37 ke andar hi patch updates aate hain) --
DESIRED_LIST="deb [signed-by=${KEYRING}] ${REPO} /"
if [[ "$(cat "$LIST" 2>/dev/null)" != "$DESIRED_LIST" ]]; then
  echo "$DESIRED_LIST" > "$LIST"
  log "${LIST} likha"
fi
wait_apt_locks; apt-get update -o DPkg::Lock::Timeout=300 -qq

# --- Step 3: Exact version install + hold ----------------------------------------------
declare -A WANT=([kubelet]="$K8S_PKG_VERSION" [kubeadm]="$K8S_PKG_VERSION" [kubectl]="$K8S_PKG_VERSION" [cri-tools]="$CRI_TOOLS_PKG_VERSION")
to_install=()
for p in "${!WANT[@]}"; do
  [[ "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)" == "${WANT[$p]}" ]] || to_install+=("${p}=${WANT[$p]}")
done
if [[ ${#to_install[@]} -gt 0 ]]; then
  apt-mark unhold "${!WANT[@]}" >/dev/null 2>&1 || true
  apt-get install "${APT_OPTS[@]}" "${to_install[@]}"
  log "install kiye: ${to_install[*]}"
else
  log "kubelet/kubeadm/kubectl/cri-tools pehle se sahi version pe"
fi
# Hold: "apt upgrade" ghalti se Kubernetes version na badal de (upgrade sirf kubeadm upgrade ke zariye)
apt-mark hold "${!WANT[@]}" >/dev/null

# kubelet ko enable rakho (init/join se pehle ye crash-loop karega — normal hai, config abhi nahi)
systemctl enable kubelet >/dev/null 2>&1

# --- Verify ----------------------------------------------------------------------------
[[ "$(kubeadm version -o short)" == "$K8S_VERSION" ]] || fail "kubeadm version ${K8S_VERSION} nahi"
# Note: "apt-mark showhold | grep -q" pipefail ke saath kabhi kabhi ghalat fail deta hai (grep jaldi band →
# apt-mark ko SIGPIPE). Is liye output pehle variable mein.
held="$(apt-mark showhold)"
for p in kubelet kubeadm kubectl cri-tools; do
  grep -qx "$p" <<<"$held" || fail "${p} hold nahi hai"
done
log "verify: kubeadm $(kubeadm version -o short), kubelet $(kubelet --version | awk '{print $2}'), kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion); crictl $(crictl --version | awk '{print $NF}'); held: $(apt-mark showhold | grep -E '^(kube|cri-tools)' | xargs)"
log "DONE"
