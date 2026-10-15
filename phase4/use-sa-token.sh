#!/usr/bin/env bash
# use-sa-token.sh — Argo CD (s3) ki lab-workload credential: kubernetes-admin client cert → argocd-manager SA token.
#
# Istemaal (s1 pe, gohar se):  bash use-sa-token.sh
# Kyun: Argo CD v3.5.5 "cluster add" kubeconfig mein client cert/key ho to SA token phenk deta hai
#       (cmd/util/cluster.go NewCluster: "set bearer token only if the key/cert data is absent").
#       Admin cert revoke nahi ho sakta (Oct 2027 tak valid) aur audit mein Argo CD/insaan alag nahi dikhte.
# Kaise: cluster Secret ki SIRF "config" key badalti hai:
#          {"bearerToken": <argocd-manager token>, "tlsClientConfig": {"insecure": false, "caData": <SA token Secret ka ca.crt>}}
#        Token/CA sirf pipe se (kubectl → jq → kubectl apply stdin); kabhi print/file nahi.
#        SERVER-SIDE apply: client-side apply poori object (token samet) "last-applied-configuration" annotation
#        mein bhi likh deta — aur Argo CD cluster ki annotations "argocd cluster get" mein dikhata hai.
# Idempotent: config pehle se sahi ho (sirf bearerToken + caData, token = SA ka token) to kuch nahi badalta.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../phase3/versions.sh
source "${SCRIPT_DIR}/../phase3/versions.sh"
log()  { echo "[$(hostname)] [use-sa-token] $*"; }
fail() { echo "[$(hostname)] [use-sa-token] ERROR: $*" >&2; exit 1; }
M=(kubectl --context "$MGMT_CONTEXT" -n "$ARGOCD_NS")
W=(kubectl --context "$WORKLOAD_CONTEXT" -n kube-system)
SERVER="https://k8s-api.lab.local:6443"
SA_SECRET="argocd-manager-long-lived-token"

# Cluster Secret ka naam server se dhoondo (naam hardcode nahi)
CS="$("${M[@]}" get secret -l argocd.argoproj.io/secret-type=cluster -o json \
      | jq -r --arg s "$SERVER" '.items[] | select((.data.server|@base64d)==$s) | .metadata.name')"
[[ -n "$CS" && "$(wc -l <<<"$CS")" -eq 1 ]] || fail "server ${SERVER} ka aik cluster Secret nahi mila"
"${W[@]}" get secret "$SA_SECRET" >/dev/null || fail "${SA_SECRET} nahi (argocd cluster add?)"

# Haalat: sirf keys ke naam + token ka sha256 compare (values kabhi bahar nahi)
state() {
  { "${M[@]}" get secret "$CS" -o json; "${W[@]}" get secret "$SA_SECRET" -o json; } | jq -rs '
    (.[0].data.config | @base64d | fromjson) as $c | .[1] as $t |
    { keys: ($c|keys), tls_keys: (($c.tlsClientConfig // {})|keys),
      token_match: (($c.bearerToken // "") == ($t.data.token|@base64d)),
      ca_match: (($c.tlsClientConfig.caData // "") == $t.data["ca.crt"]),
      insecure: ($c.tlsClientConfig.insecure // false) } | tojson'
}
s="$(state)"
if [[ "$(jq -r '.token_match and .ca_match and (.insecure==false) and (.tls_keys|index("certData")|not) and (.tls_keys|index("keyData")|not)' <<<"$s")" == "true" ]]; then
  log "cluster Secret ${CS} pehle se argocd-manager token pe hai — kuch nahi badla"
else
  log "pehle: config keys $(jq -c .keys <<<"$s"), tlsClientConfig keys $(jq -c .tls_keys <<<"$s")"
  # Naya config sirf pipe mein banta hai; SSA patch mein sirf data.config (server/name/labels wahi rehte hain)
  { "${M[@]}" get secret "$CS" -o json; "${W[@]}" get secret "$SA_SECRET" -o json; } | jq -s '
      .[0] as $c | .[1] as $t |
      { apiVersion: "v1", kind: "Secret",
        metadata: { name: $c.metadata.name, namespace: $c.metadata.namespace },
        data: { config: ( { bearerToken: ($t.data.token | @base64d),
                            tlsClientConfig: { insecure: false, caData: $t.data["ca.crt"] } } | tojson | @base64 ) } }' \
    | "${M[@]}" apply --server-side --force-conflicts --field-manager=lab-infra-phase4 -f - >/dev/null
  log "cluster Secret ${CS}: config = {bearerToken, tlsClientConfig{insecure:false, caData}} (server-side apply)"
fi

# --- Verify -------------------------------------------------------------------------------------------
s="$(state)"
echo "  config keys: $(jq -c .keys <<<"$s")  tlsClientConfig keys: $(jq -c .tls_keys <<<"$s")  token=SA token: $(jq -r .token_match <<<"$s")  ca=SA ca.crt: $(jq -r .ca_match <<<"$s")"
[[ "$(jq -r '.keys == ["bearerToken","tlsClientConfig"] and .tls_keys == ["caData","insecure"] and .token_match and .ca_match and (.insecure==false)' <<<"$s")" == "true" ]] \
  || fail "cluster Secret config ummeed ke mutabiq nahi"
anns="$("${M[@]}" get secret "$CS" -o json | jq -r '.metadata.annotations // {} | keys | join(",")')"
grep -q "last-applied-configuration" <<<"$anns" && fail "cluster Secret pe last-applied annotation hai (token copy!)"
srv="$("${M[@]}" get secret "$CS" -o json | jq -r '"\(.data.server|@base64d) \(.data.name|@base64d)"')"
[[ "$srv" == "${SERVER} ${WORKLOAD_CONTEXT}" ]] || fail "server/name badal gaye: ${srv}"
log "verify: sirf bearerToken + caData (certData/keyData nahi), server/name wahi, koi last-applied annotation nahi"
log "DONE"
