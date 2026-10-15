#!/usr/bin/env bash
# verify.sh — Phase 3 (k3s management cluster + Argo CD) ke 8 tests. s1 se chalao (gohar).
#   bash verify.sh
# Kuch badalta nahi (sirf parhta hai). argocd CLI pehle se logged in honi chahiye (argocd-cli.sh).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
M=(kubectl --context "$MGMT_CONTEXT")
S3=(ssh -o BatchMode=yes "gohar@${MGMT_IP}")
RESULTS=()
pass() { RESULTS+=("PASS  $1"); echo "  ✅ PASS: $1"; }
warn() { RESULTS+=("WARN  $1"); echo "  ⚠️  WARN: $1"; }
failt(){ RESULTS+=("FAIL  $1"); echo "  ❌ FAIL: $1"; }
hdr()  { echo; echo "=== $* ==="; }

# --- 1. k3s node + saare pods -------------------------------------------------------------------------
hdr "1. k3s node + pods (lab-mgmt)"
"${M[@]}" get nodes -o wide
[[ "$("${M[@]}" get node "$MGMT_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]] \
  && pass "s3 Ready ($("${M[@]}" get node "$MGMT_NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}'))" || failt "s3 Ready nahi"
"${M[@]}" get pods -A -o wide
# Job pods (Succeeded/Completed) theek hain; baaqi sab Running + Ready
bad="$("${M[@]}" get pods -A -o json | jq -r '.items[] | select(.status.phase!="Succeeded")
        | select(.status.phase!="Running" or ([.status.containerStatuses[]?.ready] | all | not)) | "\(.metadata.namespace)/\(.metadata.name)"')"
[[ -z "$bad" ]] && pass "saare pods Running+Ready (Completed jobs alag)" || failt "pods: ${bad//$'\n'/, }"
rs_run="$("${M[@]}" get pods -A -o json | jq -r '.items[] | select(.status.phase=="Running") | select([.status.containerStatuses[].restartCount]|add > 0) | "\(.metadata.name)=\([.status.containerStatuses[].restartCount]|add)"')"
rs_job="$("${M[@]}" get pods -A -o json | jq -r '.items[] | select(.status.phase=="Succeeded") | select([.status.containerStatuses[].restartCount]|add > 0) | "\(.metadata.name)=\([.status.containerStatuses[].restartCount]|add)"')"
[[ -z "$rs_run" ]] && pass "chalte pods: restarts 0" || failt "chalte pods mein restarts: ${rs_run//$'\n'/, }"
[[ -z "$rs_job" ]] || warn "Completed job pods ke retries: ${rs_job//$'\n'/, } (k3s helm-install jobs ka aam rawaiyya)"

# --- 2. Argo CD pods ---------------------------------------------------------------------------------------
hdr "2. Argo CD pods (argocd namespace)"
"${M[@]}" -n "$ARGOCD_NS" get pods -o wide
abad="$("${M[@]}" -n "$ARGOCD_NS" get pods --no-headers | awk '$3!="Running" && $3!="Completed" {print $1}')"
[[ -z "$abad" ]] && pass "argocd pods Running" || failt "argocd pods: ${abad//$'\n'/, }"

# --- 3. HTTPS (bina -k) ------------------------------------------------------------------------------------
hdr "3. s1 se: curl https://${ARGOCD_HOST}/ (bina -k)"
body="$(curl -s -w '\nHTTP_CODE=%{http_code}' "https://${ARGOCD_HOST}/")"; rc=$?
code="$(sed -n 's/^HTTP_CODE=//p' <<<"$body")"; title="$(grep -o '<title>[^<]*</title>' <<<"$body" | head -1)"
echo "  rc=${rc} code=${code} ${title}"
http80="$(curl -s -o /dev/null -w '%{http_code}' "http://${ARGOCD_HOST}/")"
echo "  http://${ARGOCD_HOST}/ (port 80) → ${http80}"
[[ $rc -eq 0 && "$code" == "200" && "$title" == "<title>Argo CD</title>" ]] && pass "HTTPS 200, HTML '${title}' (TLS verify OK)" || failt "https rc=${rc} code=${code}"
[[ "$http80" != "200" ]] && pass "plain HTTP pe Argo CD nahi (${http80})" || failt "Argo CD port 80 (HTTP) pe bhi mil raha hai"

# --- 4. openssl s_client ---------------------------------------------------------------------------------
hdr "4. openssl s_client ${ARGOCD_HOST}:443"
sc="$(openssl s_client -connect "${ARGOCD_HOST}:443" -servername "$ARGOCD_HOST" -verify_hostname "$ARGOCD_HOST" -CApath /etc/ssl/certs </dev/null 2>&1)"
grep -E "^depth=|Verify return code|Protocol *:" <<<"$sc" | sed 's/^/  /' | head -5
openssl x509 -noout -subject -issuer -enddate -ext subjectAltName <<<"$sc" 2>/dev/null | sed 's/^/  /'
grep -q "Verify return code: 0 (ok)" <<<"$sc" && pass "Verify return code: 0 (ok)" || failt "s_client verify"

# --- 5. argocd version + user ------------------------------------------------------------------------------
hdr "5. argocd version + get-user-info"
ver="$(argocd version --grpc-web 2>&1)"; echo "$ver" | grep -E "^argocd(-server)?:" | sed 's/^/  /'
cv="$(awk '/^argocd: /{print $2}' <<<"$ver" | cut -d+ -f1)"; sv="$(awk '/^argocd-server: /{print $2}' <<<"$ver" | cut -d+ -f1)"
[[ -n "$cv" && "$cv" == "$sv" && "$cv" == "$ARGOCD_VERSION" ]] && pass "client = server = ${cv}" || failt "version client=${cv} server=${sv}"
ui="$(argocd account get-user-info --grpc-web 2>&1)"; echo "$ui" | sed 's/^/  /'
grep -q "Logged In: true" <<<"$ui" && grep -q "Username: admin" <<<"$ui" && pass "logged in as admin" || failt "get-user-info"

# --- 6. argocd cluster list --------------------------------------------------------------------------------
hdr "6. argocd cluster list"
cl="$(argocd cluster list --grpc-web -o json 2>&1)"
argocd cluster list --grpc-web 2>&1 | sed 's/^/  /'
n="$(jq 'length' <<<"$cl" 2>/dev/null)"; srv="$(jq -r '.[0].server' <<<"$cl" 2>/dev/null)"
[[ "$n" == "1" && "$srv" == "https://kubernetes.default.svc" ]] && pass "sirf in-cluster (s3); workload cluster register nahi" || failt "cluster list: n=${n} ${srv}"

# --- 7. s3 resources ----------------------------------------------------------------------------------------
hdr "7. s3: allocated requests + asal usage"
"${M[@]}" describe node "$MGMT_NODE" | sed -n '/Allocated resources/,/Events/p' | sed -n '1,8p'
"${M[@]}" top node "$MGMT_NODE" 2>&1 || true
"${M[@]}" -n "$ARGOCD_NS" top pods 2>&1 || true
"${S3[@]}" 'free -h; uptime' | sed 's/^/  /'
alloc_cpu="$("${M[@]}" describe node "$MGMT_NODE" | awk '/Allocated resources/{f=1} f && $1=="cpu"{print $2, $3; exit}')"
alloc_mem="$("${M[@]}" describe node "$MGMT_NODE" | awk '/Allocated resources/{f=1} f && $1=="memory"{print $2, $3; exit}')"
pass "allocated requests: cpu ${alloc_cpu}, memory ${alloc_mem}"

# --- 8. k3s secrets encryption ----------------------------------------------------------------------------
hdr "8. k3s secrets-encrypt status"
enc="$("${S3[@]}" 'sudo k3s secrets-encrypt status' 2>&1)"; echo "$enc" | sed 's/^/  /'
grep -q "Encryption Status: Enabled" <<<"$enc" && pass "secrets encryption at rest: Enabled" || failt "secrets encryption"

hdr "Summary"
printf '  %s\n' "${RESULTS[@]}"
grep -q '^FAIL' <<<"$(printf '%s\n' "${RESULTS[@]}")" && exit 1 || exit 0
