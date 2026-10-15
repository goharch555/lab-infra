#!/usr/bin/env bash
# register-cluster.sh — workload cluster (lab-workload) ko s3 wale Argo CD (hub) mein register karo.
#
# Istemaal (s1 pe, gohar se):  bash register-cluster.sh
# - Login: phase3/argocd-cli.sh (password /root/argocd-admin-password se, CLI PROMPT pe — command line pe nahi).
# - "argocd cluster add lab-workload --name lab-workload": workload cluster mein argocd-manager SA +
#   ClusterRole/Binding + token Secret banata hai, aur s3 pe argocd namespace mein cluster Secret.
# - Output mein token / caData KABHI nahi (sirf naam, labels, keys).
# Idempotent: cluster pehle se registered ho to "cluster add" dobara nahi.
# Workload cluster pe is ke ilawa koi tabdeeli NAHI. Koi Application/AppProject NAHI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../phase3/versions.sh
source "${SCRIPT_DIR}/../phase3/versions.sh"
log()  { echo "[$(hostname)] [register-cluster] $*"; }
fail() { echo "[$(hostname)] [register-cluster] ERROR: $*" >&2; exit 1; }
W=(kubectl --context "$WORKLOAD_CONTEXT")
M=(kubectl --context "$MGMT_CONTEXT")
WANT_SERVER="https://k8s-api.lab.local:6443"
# JSON se secret-jaisi values hatao (bearerToken, caData, certData, keyData, password...)
redact() { jq 'walk(if type=="object" then with_entries(if (.key|test("(?i)token|caData|certData|keyData|password|secret")) and (.value|type=="string") then .value="<redacted>" else . end) else . end)'; }

# --- Step 1: Pre-checks -----------------------------------------------------------------------------
srv="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${WORKLOAD_CONTEXT}\")].cluster.server}")"
[[ "$srv" == "$WANT_SERVER" ]] || fail "context ${WORKLOAD_CONTEXT} ka server ${srv} hai (${WANT_SERVER} chahiye)"
log "context ${WORKLOAD_CONTEXT} → ${srv} ✓ (Argo CD bhi yahi URL use karega; s3 CoreDNS isay 192.168.2.11 pe resolve karta hai)"
"${W[@]}" get --raw=/readyz >/dev/null || fail "workload cluster tak nahi pohanch"

# --- Step 2: Login (password prompt pe) ---------------------------------------------------------------
bash "${SCRIPT_DIR}/../phase3/argocd-cli.sh" | grep -E "login OK|ERROR" || fail "argocd login fail"

# --- Step 3: cluster add (sirf agar registered nahi) ---------------------------------------------------
if argocd cluster list --grpc-web -o json | jq -e --arg s "$WANT_SERVER" '.[] | select(.server==$s)' >/dev/null; then
  log "cluster ${WANT_SERVER} pehle se registered — 'cluster add' skip"
else
  log "argocd cluster add ${WORKLOAD_CONTEXT} --name ${WORKLOAD_CONTEXT}"
  argocd cluster add "$WORKLOAD_CONTEXT" --name "$WORKLOAD_CONTEXT" --grpc-web --yes 2>&1 \
    | grep -viE "token|bearer" | sed 's/^/  /'
fi

# --- Step 4: Workload cluster mein kya bana (sirf metadata) ---------------------------------------------
echo; echo "--- workload cluster (${WORKLOAD_CONTEXT}): argocd-manager resources"
"${W[@]}" -n kube-system get serviceaccount argocd-manager -o wide
"${W[@]}" get clusterrole argocd-manager-role -o json | jq -c '{clusterrole: .metadata.name, rules: .rules}'
"${W[@]}" get clusterrolebinding argocd-manager-role-binding -o json | jq -c '{clusterrolebinding: .metadata.name, role: .roleRef.name, subjects: .subjects}'
"${W[@]}" -n kube-system get secret -o json | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/service-account.name"]=="argocd-manager")
   | "secret: \(.metadata.name)  type: \(.type)  keys: \(.data|keys|join(","))  (values NAHI dikhaye)"'

# --- Step 5: s3 pe cluster Secret (sirf metadata + keys) -------------------------------------------------
echo; echo "--- s3 (${MGMT_CONTEXT}) argocd namespace: cluster Secret"
"${M[@]}" -n "$ARGOCD_NS" get secret -l argocd.argoproj.io/secret-type=cluster -o json \
  | jq '.items[] | {name: .metadata.name, labels: .metadata.labels, type: .type, data_keys: (.data|keys), server: (.data.server|@base64d), clusterName: (.data.name|@base64d)}'

# --- Verify -------------------------------------------------------------------------------------------------
echo; argocd cluster list --grpc-web
echo; echo "--- argocd cluster get ${WORKLOAD_CONTEXT} (secrets <redacted>)"
argocd cluster get "$WORKLOAD_CONTEXT" --grpc-web -o json | redact
argocd cluster list --grpc-web -o json | jq -e --arg s "$WANT_SERVER" '.[] | select(.server==$s and .name=="lab-workload")' >/dev/null \
  || fail "lab-workload cluster list mein nahi"
"${W[@]}" -n kube-system get sa argocd-manager >/dev/null || fail "argocd-manager SA nahi"
[[ "$(argocd app list --grpc-web -o name | wc -l)" -eq 0 ]] || fail "koi Application mojood hai (nahi honi chahiye)"
log "verify: lab-workload registered (${WANT_SERVER}); argocd-manager SA/ClusterRole/Binding/token mojood; 0 Applications"
log "DONE"
