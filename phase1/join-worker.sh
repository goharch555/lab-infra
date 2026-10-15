#!/usr/bin/env bash
# join-worker.sh — worker node(s) ko cluster mein join karo, JoinConfiguration FILE ke zariye.
#
# Istemaal (s1 pe, gohar se):  bash join-worker.sh [s2 ...]     (default: versions.sh ka WORKER_NODES)
# Token + CA hash runtime pe banta hai (kubeadm token create --print-join-command, 30 min TTL),
# node pe /root/ mein 600 file mein jata hai, join ke baad file aur token dono delete.
# Idempotent: node pehle se cluster mein ho to skip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
TMPL="${SCRIPT_DIR}/kubeadm-join.yaml.tmpl"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

log()  { echo "[$(hostname)] [join-worker] $*"; }
fail() { echo "[$(hostname)] [join-worker] ERROR: $*" >&2; exit 1; }
[[ "$(hostname)" == "$CONTROL_PLANE_NODE" ]] || fail "s1 se chalao"
kubectl get --raw=/readyz >/dev/null 2>&1 || fail "kubectl cluster tak nahi pohanch raha"

NODES=("$@"); [[ ${#NODES[@]} -gt 0 ]] || NODES=("${WORKER_NODES[@]}")

for node in "${NODES[@]}"; do
  ip="${K8S_NODE_IP[$node]:?${node} versions.sh mein nahi}"
  remote() { ssh "${SSH_OPTS[@]}" "gohar@${ip}" "$@"; }

  # --- Idempotency: pehle se joined? --------------------------------------------------------
  if kubectl get node "$node" >/dev/null 2>&1; then
    log "${node} pehle se cluster mein hai — skip"; continue
  fi
  if remote 'sudo test -f /etc/kubernetes/kubelet.conf'; then
    fail "${node} pe /etc/kubernetes/kubelet.conf hai lekin node cluster mein nahi — khud dekho (reset NAHI kar raha)"
  fi

  # --- Pre-checks on worker -----------------------------------------------------------------
  grep -q "^${CONTROL_PLANE_IP} " <<<"$(remote "getent hosts ${CONTROL_PLANE_ENDPOINT%%:*}")" || fail "${node}: ${CONTROL_PLANE_ENDPOINT%%:*} resolve nahi"
  remote 'systemctl is-active --quiet containerd && sudo crictl info >/dev/null' || fail "${node}: containerd/CRI theek nahi"
  remote "timeout 5 bash -c '</dev/tcp/${CONTROL_PLANE_ENDPOINT%%:*}/${CONTROL_PLANE_ENDPOINT##*:}'" || fail "${node}: API ${CONTROL_PLANE_ENDPOINT} tak TCP nahi"
  log "${node}: pre-checks OK"

  # --- Token + CA hash (runtime pe; sirf variables mein, kabhi print/commit nahi) -------------
  join_cmd="$(sudo kubeadm token create --ttl 30m --description "join ${node} via join-worker.sh" --print-join-command)"
  token="$(grep -oP -- '--token \K\S+' <<<"$join_cmd")"
  ca_hash="$(grep -oP -- '--discovery-token-ca-cert-hash \K\S+' <<<"$join_cmd")"
  [[ "$token" =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ && "$ca_hash" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "token/hash parse nahi hua"
  token_id="${token%%.*}"
  unset join_cmd
  log "${node}: bootstrap token bana (id ${token_id}, 30 min TTL)"

  # Token jo bhi ho, script khatam hone pe delete ho
  cleanup() {
    remote 'sudo shred -u /root/kubeadm-join.yaml 2>/dev/null || sudo rm -f /root/kubeadm-join.yaml' || true
    sudo kubeadm token delete "$token_id" >/dev/null 2>&1 && log "token ${token_id} delete kiya" || true
  }
  trap cleanup EXIT

  # --- JoinConfiguration node pe likho (stdin se; token command-line/argv mein nahi aata) -----
  sed -e "s|__TOKEN__|${token}|" -e "s|__CA_HASH__|${ca_hash}|" -e "s|__NODE__|${node}|" -e "s|__NODE_IP__|${ip}|" "$TMPL" \
    | remote 'sudo install -m 0600 -o root -g root /dev/stdin /root/kubeadm-join.yaml'
  unset token ca_hash

  # --- Dry-run, phir asal join ------------------------------------------------------------------
  remote 'sudo kubeadm join --config /root/kubeadm-join.yaml --dry-run >/tmp/kubeadm-join-dryrun.log 2>&1' \
    || { remote 'tail -25 /tmp/kubeadm-join-dryrun.log'; fail "${node}: join --dry-run fail — asal join nahi kiya"; }
  log "${node}: join dry-run OK"
  remote 'sudo bash -c "umask 077; kubeadm join --config /root/kubeadm-join.yaml > /root/kubeadm-join-$(date -u +%Y%m%dT%H%M%SZ).log 2>&1"' \
    || { remote 'sudo bash -c "tail -25 \$(ls -t /root/kubeadm-join-*.log | head -1)"'; fail "${node}: kubeadm join fail — reset NAHI kiya"; }
  log "${node}: kubeadm join mukammal"
  cleanup; trap - EXIT

  # --- Verify: node registered ---------------------------------------------------------------
  for _ in $(seq 1 30); do kubectl get node "$node" >/dev/null 2>&1 && break; sleep 2; done
  kubectl get node "$node" >/dev/null || fail "${node} cluster mein nazar nahi aaya"
  log "${node}: cluster mein register (Ready hone mein Calico ko 1-3 min lagte hain)"
done
log "DONE"
