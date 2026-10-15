#!/usr/bin/env bash
# verify.sh — Phase 4a ke tests. s1 se chalao (gohar). Koi secret value print nahi hoti.
#   bash verify.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../phase3/versions.sh
source "${SCRIPT_DIR}/../phase3/versions.sh"
M=(kubectl --context "$MGMT_CONTEXT")
W=(kubectl --context "$WORKLOAD_CONTEXT")
REPO_URL="git@github.com:goharch555/platform-gitops.git"
KEY="/root/argocd-repo-key/platform-gitops"
RESULTS=()
pass() { RESULTS+=("PASS  $1"); echo "  ✅ PASS: $1"; }
failt(){ RESULTS+=("FAIL  $1"); echo "  ❌ FAIL: $1"; }
hdr()  { echo; echo "=== $* ==="; }

# --- 1. CoreDNS lab.local (DNS + workload API reachability, s3 ke pods se) -------------------------
hdr "1. k3s CoreDNS: lab.local (coredns-custom)"
"${M[@]}" -n kube-system get cm coredns-custom -o jsonpath='{.data.lab-local\.server}' | sed 's/^/  /'
if out="$(bash "${SCRIPT_DIR}/coredns-lab-local.sh" 2>&1)"; then
  grep -E "verify:" <<<"$out" | sed 's/^/  /'; pass "pods se k8s-api/argocd/registry.lab.local resolve + workload API /version"
else echo "$out" | tail -5; failt "CoreDNS lab.local"; fi

# --- 2. Login (password prompt pe) ---------------------------------------------------------------------
hdr "2. argocd login (stored password, prompt pe)"
lo="$(bash "${SCRIPT_DIR}/../phase3/argocd-cli.sh" 2>&1)"   # pehle poora output (pipe | grep -q + pipefail = SIGPIPE ghalat FAIL)
grep -E "login OK|ERROR" <<<"$lo" | sed 's/^/  /'
grep -q "login OK" <<<"$lo" && pass "login OK" || failt "login"

# --- 3. Cluster registration --------------------------------------------------------------------------
hdr "3. argocd cluster list / get lab-workload"
argocd cluster list --grpc-web 2>&1 | sed 's/^/  /'
cj="$(argocd cluster get "$WORKLOAD_CONTEXT" --grpc-web -o json 2>/dev/null)"
jq '{server, name, insecure: .config.tlsClientConfig.insecure, connection: .connectionState.status, serverVersion, applications: .info.applicationsCount}' <<<"$cj" | sed 's/^/  /'
st="$(jq -r .connectionState.status <<<"$cj")"
[[ "$(jq -r .server <<<"$cj")" == "https://k8s-api.lab.local:6443" && "$(jq -r .config.tlsClientConfig.insecure <<<"$cj")" == "false" ]] \
  && [[ "$st" == "Successful" || "$st" == "Unknown" ]] \
  && pass "lab-workload registered (TLS verify on), status ${st}" || failt "cluster lab-workload (${st})"

# --- 4. Workload cluster mein argocd-manager resources ---------------------------------------------------
hdr "4. Workload cluster: argocd-manager"
ok=yes
"${W[@]}" -n kube-system get sa argocd-manager >/dev/null 2>&1 || ok=no
"${W[@]}" get clusterrole argocd-manager-role >/dev/null 2>&1 || ok=no
"${W[@]}" get clusterrolebinding argocd-manager-role-binding >/dev/null 2>&1 || ok=no
tok="$("${W[@]}" -n kube-system get secret argocd-manager-long-lived-token -o jsonpath='{.type}' 2>/dev/null)"
echo "  sa/argocd-manager, clusterrole/argocd-manager-role, clusterrolebinding/argocd-manager-role-binding, secret type=${tok}"
[[ "$ok" == yes && "$tok" == "kubernetes.io/service-account-token" ]] && pass "argocd-manager SA + ClusterRole + Binding + token Secret" || failt "argocd-manager resources"
# Argo CD asal mein kaunsi credential use karta hai? (sirf QISM + TokenReview ka user — value kabhi nahi)
cs_json="$("${M[@]}" -n "$ARGOCD_NS" get secret -l argocd.argoproj.io/secret-type=cluster -o json \
          | jq --arg s "https://k8s-api.lab.local:6443" '.items[] | select((.data.server|@base64d)==$s)')"
ckeys="$(jq -c '.data.config|@base64d|fromjson|{keys:keys, tls:((.tlsClientConfig // {})|keys)}' <<<"$cs_json")"
echo "  cluster Secret config keys: ${ckeys}"
if jq -e '.tls|index("certData") or index("keyData")' <<<"$ckeys" >/dev/null; then
  failt "Argo CD credential: client certificate (certData/keyData) — argocd-manager token chahiye (phase4/use-sa-token.sh)"
elif jq -e '.keys|index("bearerToken")' <<<"$ckeys" >/dev/null; then
  # Token workload cluster ke TokenReview ko pipe se; jawab mein sirf user (TokenReview spec.token wapas bhejta hai — filter)
  who="$(jq '{apiVersion:"authentication.k8s.io/v1",kind:"TokenReview",spec:{token:(.data.config|@base64d|fromjson|.bearerToken)}}' <<<"$cs_json" \
         | "${W[@]}" create -f - -o json | jq -r '"\(.status.authenticated) \(.status.user.username)"')"
  echo "  TokenReview: ${who}"
  [[ "$who" == "true system:serviceaccount:kube-system:argocd-manager" ]] \
    && pass "Argo CD credential: bearer token (argocd-manager)" || failt "bearer token argocd-manager ka nahi: ${who}"
else
  failt "Argo CD credential: na token na cert (${ckeys})"
fi
unset cs_json
# Argo CD Secrets pe last-applied annotation nahi honi chahiye (us mein key/token ki copy hoti hai)
la="$("${M[@]}" -n "$ARGOCD_NS" get secret -o json | jq -r '.items[] | select(.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]) | .metadata.name')"
[[ -z "$la" ]] && pass "argocd namespace ke kisi Secret pe last-applied annotation nahi" || failt "last-applied annotation (secret copy): ${la//$'\n'/, }"

# --- 5. Repository connection ------------------------------------------------------------------------------
hdr "5. argocd repo list"
argocd repo list --grpc-web 2>&1 | sed 's/^/  /'
rs="$(argocd repo list --grpc-web -o json | jq -r --arg u "$REPO_URL" '.[] | select(.repo==$u) | .connectionState.status')"
[[ "$rs" == "Successful" ]] && pass "platform-gitops CONNECTION STATUS Successful" || failt "repo status: ${rs:-nahi mila}"

# --- 6. Deploy key READ-ONLY (asal push ki koshish; kamyab ho to foran branch delete) ----------------------
hdr "6. Deploy key read-only: push → refs/heads/readonly-test"
d="$(mktemp -d)"; chmod 755 "$d"
awk '$1=="github.com"' <<<"$("${M[@]}" -n "$ARGOCD_NS" get cm argocd-ssh-known-hosts-cm -o jsonpath='{.data.ssh_known_hosts}')" > "${d}/kh"; chmod 644 "${d}/kh"
G="ssh -i ${KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=${d}/kh -o StrictHostKeyChecking=yes"
sudo env GIT_SSH_COMMAND="$G" git clone -q "$REPO_URL" "${d}/r" 2>/dev/null
pout="$(sudo env GIT_SSH_COMMAND="$G" git -C "${d}/r" push origin HEAD:refs/heads/readonly-test 2>&1)"; prc=$?
sudo rm -rf "$d"
echo "$pout" | head -2 | sed 's/^/  /'
if [[ $prc -ne 0 ]] && grep -q "marked as read only" <<<"$pout"; then
  pass "deploy key read-only (push mana: 'marked as read only')"
else
  failt "deploy key se push KAMYAB hua (write access on!)"
  git push -q "$REPO_URL" --delete readonly-test 2>&1 && echo "  readonly-test branch account key se delete ki"
fi
git ls-remote "$REPO_URL" | sed 's/^/  remote: /'

# --- 7. Koi Application / AppProject (default ke ilawa) / ApplicationSet nahi --------------------------------
hdr "7. Koi Application/AppProject/ApplicationSet nahi"
na="$("${M[@]}" -n "$ARGOCD_NS" get applications.argoproj.io --no-headers 2>/dev/null | wc -l)"
np="$("${M[@]}" -n "$ARGOCD_NS" get appprojects.argoproj.io --no-headers 2>/dev/null | awk '$1!="default"' | wc -l)"
ns="$("${M[@]}" -n "$ARGOCD_NS" get applicationsets.argoproj.io --no-headers 2>/dev/null | wc -l)"
echo "  applications=${na}, appprojects (default ke ilawa)=${np}, applicationsets=${ns}"
[[ "$na" -eq 0 && "$np" -eq 0 && "$ns" -eq 0 ]] && pass "0 Applications, sirf 'default' AppProject, 0 ApplicationSets" || failt "Application/AppProject/ApplicationSet mile"

hdr "Summary"
printf '  %s\n' "${RESULTS[@]}"
grep -q '^FAIL' <<<"$(printf '%s\n' "${RESULTS[@]}")" && exit 1 || exit 0
