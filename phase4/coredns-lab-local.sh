#!/usr/bin/env bash
# coredns-lab-local.sh — k3s (lab-mgmt) CoreDNS ko lab.local ke naam sikhao (coredns-custom ConfigMap).
#
# Istemaal (s1 pe, gohar se):  bash coredns-lab-local.sh
# Idempotent: ConfigMap badle to hi CoreDNS rollout restart (taake naya *.server import pakka load ho).
# Verify: argocd namespace mein temporary pod se nslookup + workload API tak HTTPS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../phase3/versions.sh
source "${SCRIPT_DIR}/../phase3/versions.sh"
log()  { echo "[$(hostname)] [coredns-lab-local] $*"; }
fail() { echo "[$(hostname)] [coredns-lab-local] ERROR: $*" >&2; exit 1; }
M=(kubectl --context "$MGMT_CONTEXT")
BUSYBOX="busybox:1.37.0"
CURL_IMG="curlimages/curl:8.16.0"
declare -A WANT=([k8s-api.lab.local]=192.168.2.11 [argocd.lab.local]=192.168.2.13 [registry.lab.local]=192.168.2.14)

# --- Step 1: ConfigMap apply (k3s ki apni "coredns" ConfigMap ko haath nahi lagate) -------------------
before="$("${M[@]}" -n kube-system get cm coredns-custom -o jsonpath='{.data}' 2>/dev/null || true)"
"${M[@]}" apply -f "${SCRIPT_DIR}/coredns-custom.yaml" >/dev/null
after="$("${M[@]}" -n kube-system get cm coredns-custom -o jsonpath='{.data}')"
if [[ "$before" != "$after" ]]; then
  log "coredns-custom ConfigMap apply (badla) → CoreDNS rollout restart"
  "${M[@]}" -n kube-system rollout restart deploy/coredns >/dev/null
  "${M[@]}" -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null || fail "CoreDNS rollout fail"
else
  log "coredns-custom pehle se theek"
fi
# CoreDNS ne config sahi parhi? (syntax error ho to pod crash/"plugin/..." errors)
# Sirf asal errors: [ERROR]/[FATAL] lines aur Corefile parsing errors ([INFO] plugin/reload waghera nahi)
errs="$("${M[@]}" -n kube-system logs deploy/coredns --since=5m 2>&1 | grep -E '^\[(ERROR|FATAL)\]|Error during parsing|Corefile:[0-9]+ - Error' | grep -v 'i/o timeout' || true)"
[[ -z "$errs" ]] || { echo "$errs" | tail -5; fail "CoreDNS logs mein errors"; }

# Temporary pod: banao → khatam hone ka intezar → logs → delete.
# ("kubectl run --rm -i" mein race hai: container attach se pehle khatam ho jaye to output gum.)
run_pod() {  # run_pod <name> <image> <cmd...>
  local name="$1" image="$2"; shift 2
  "${M[@]}" -n "$ARGOCD_NS" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  "${M[@]}" -n "$ARGOCD_NS" run "$name" --image="$image" --restart=Never --command -- "$@" >/dev/null
  for _ in $(seq 1 90); do
    ph="$("${M[@]}" -n "$ARGOCD_NS" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [[ "$ph" == "Succeeded" || "$ph" == "Failed" ]] && break; sleep 2
  done
  "${M[@]}" -n "$ARGOCD_NS" logs "$name" 2>&1
  "${M[@]}" -n "$ARGOCD_NS" delete pod "$name" --wait=false >/dev/null
}

# --- Verify 1: argocd namespace ke temporary pod se nslookup ---------------------------------------------
out="$(run_pod dns-lab-test "$BUSYBOX" sh -c 'for n in k8s-api.lab.local argocd.lab.local registry.lab.local; do r=$(nslookup -timeout=3 $n 2>/dev/null | awk "/^Address: /{print \$2}" | head -1); echo "$n $r"; done')"
echo "$out" | sed 's/^/  /'
for n in "${!WANT[@]}"; do
  grep -qx "${n} ${WANT[$n]}" <<<"$out" || fail "${n} → ${WANT[$n]} resolve nahi hua"
done
log "verify: pod (argocd ns) se lab.local naam resolve: k8s-api→192.168.2.11, argocd→192.168.2.13, registry→192.168.2.14"

# --- Verify 2: s3 ke pod se workload API tak (sirf reachability; -k is test mein, Argo CD khud CA se verify karta hai)
ver="$(run_pod api-reach-test "$CURL_IMG" curl -sk --max-time 10 https://k8s-api.lab.local:6443/version)"
echo "$ver" | sed 's/^/  /'
grep -q '"gitVersion"' <<<"$ver" || fail "s3 ke pod se https://k8s-api.lab.local:6443/version nahi mila"
log "verify: s3 pod → https://k8s-api.lab.local:6443/version → $(jq -r .gitVersion <<<"$ver" 2>/dev/null)"
log "DONE"
