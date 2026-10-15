#!/usr/bin/env bash
# approve-kubelet-csrs.sh — SIRF s1/s2 ke "kubelet-serving" CSRs approve karo, sakht checks ke saath.
#
# Kyun: KubeletConfiguration mein serverTLSBootstrap: true hai, is liye har kubelet apne HTTPS serving
# certificate (port 10250) ke liye CSR bhejta hai. Kubernetes isay khud approve NAHI karta (security),
# aur jab tak approve na ho: kubectl logs/exec/port-forward "tls: internal error" dete hain.
#
# Istemaal (s1 pe, gohar se):  bash approve-kubelet-csrs.sh
# Idempotent hai: sirf Pending CSRs dekhti hai. Jo check fail ho, wo CSR chhor deti hai (deny NAHI karti).
# Backlog: isay baad mein automate karna hai (docs/backlog.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
log() { echo "[$(hostname)] [approve-csrs] $*"; }

approved=0; skipped=0
for csr in $(kubectl get csr -o json | jq -r '.items[]
    | select(.spec.signerName=="kubernetes.io/kubelet-serving")
    | select((.status.conditions // []) | length == 0)
    | .metadata.name'); do
  json="$(kubectl get csr "$csr" -o json)"
  user="$(jq -r .spec.username <<<"$json")"
  node="${user#system:node:}"

  # Check 1: requester system:node:<s1|s2> ho, aur system:nodes group mein ho
  if [[ "$user" != system:node:* || -z "${K8S_NODE_IP[$node]:-}" ]]; then
    log "SKIP ${csr}: requester '${user}' hamari node list (s1, s2) mein nahi"; skipped=$((skipped+1)); continue
  fi
  jq -e '.spec.groups | index("system:nodes")' <<<"$json" >/dev/null || { log "SKIP ${csr}: system:nodes group nahi"; skipped=$((skipped+1)); continue; }

  # Check 2: CSR ke andar maange gaye naam/IP SIRF usi node ke hon (koi aur naam ka cert na le sake)
  req="$(jq -r .spec.request <<<"$json" | base64 -d | openssl req -noout -text 2>/dev/null)"
  subject_cn="$(grep -oP 'Subject:.*CN\s*=\s*\K[^,]+' <<<"$req" | head -1)"
  sans="$(grep -A1 'Subject Alternative Name' <<<"$req" | tail -1 | tr -d ' ')"
  bad=""
  [[ "$subject_cn" == "$user" ]] || bad="CN '${subject_cn}' != ${user}"
  IFS=',' read -ra san_list <<<"$sans"
  for san in "${san_list[@]}"; do
    case "$san" in
      "DNS:${node}"|"IPAddress:${K8S_NODE_IP[$node]}") ;;
      *) bad="${bad:+$bad; }ghair-mutawaqqa SAN '${san}'" ;;
    esac
  done
  if [[ -n "$bad" ]]; then log "SKIP ${csr} (${user}): ${bad}"; skipped=$((skipped+1)); continue; fi

  kubectl certificate approve "$csr" >/dev/null
  log "APPROVED ${csr}: ${user}, SANs ${sans}"
  approved=$((approved+1))
done
log "DONE: ${approved} approve, ${skipped} skip"
