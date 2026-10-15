#!/usr/bin/env bash
# verify.sh — Phase 2 (registry.lab.local) ke 5 tests. s1 se chalao (gohar; kubectl + s4 pe ssh).
#
# Istemaal:  bash verify.sh
# Passwords: s4 ki /root/registry-credentials/ se stdin/memory mein — KABHI print, argv ya file mein nahi.
# Test resources: "phase2-test" namespace (aakhir mein delete), s4 pe docker logout (aakhir mein, har haal mein).
set -uo pipefail     # -e nahi: har test chalna chahiye

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
NS="phase2-test"
IMG="${REGISTRY_HOST}/${TEST_REPO}:${TEST_TAG}"
S4=(ssh -o BatchMode=yes -o ConnectTimeout=5 "gohar@${REGISTRY_IP}")
RESULTS=()
pass() { RESULTS+=("PASS  $1"); echo "  ✅ PASS: $1"; }
failt(){ RESULTS+=("FAIL  $1"); echo "  ❌ FAIL: $1"; }
hdr()  { echo; echo "=== $* ==="; }

cleanup() {
  echo; echo "--- cleanup: phase2-test namespace + s4 docker logout"
  kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1 && echo "  namespace deleted"
  "${S4[@]}" "docker logout ${REGISTRY_HOST} >/dev/null 2>&1" && echo "  s4: docker logout"
}
trap cleanup EXIT

# --- 1. curl (bina -k): TLS system trust se, auth zaroori → 401 ----------------------------------
hdr "1. s1 se: curl https://${REGISTRY_HOST}/v2/ (bina -k)"
code="$(curl -s -o /dev/null -w '%{http_code}' "https://${REGISTRY_HOST}/v2/")"; rc=$?
hdrs="$(curl -s -D - -o /dev/null "https://${REGISTRY_HOST}/v2/" | grep -iE '^(HTTP|www-authenticate|docker-distribution)' | tr -d '\r')"
echo "$hdrs" | sed 's/^/  /'
[[ $rc -eq 0 && "$code" == "401" ]] && pass "HTTPS OK (TLS verify), /v2/ → 401 (auth zaroori)" || failt "curl rc=${rc} code=${code}"

# --- 2. openssl s_client: chain verify -----------------------------------------------------------------
hdr "2. openssl s_client: certificate chain"
sc="$(openssl s_client -connect "${REGISTRY_HOST}:443" -servername "${REGISTRY_HOST}" -verify_hostname "${REGISTRY_HOST}" \
      -CApath /etc/ssl/certs -showcerts </dev/null 2>&1)"
grep -E "^depth=|Verify return code|Protocol *:|Cipher *:" <<<"$sc" | sed 's/^/  /' | head -8
srv="$(openssl x509 -noout -subject -issuer -enddate -ext subjectAltName,extendedKeyUsage <<<"$sc" 2>/dev/null)"
echo "$srv" | sed 's/^/  /'
grep -q "Verify return code: 0 (ok)" <<<"$sc" && pass "Verify return code: 0 (ok) — chain: ${REGISTRY_HOST} → Lab Root CA" || failt "chain verify"

# --- 3. s4: docker login (ci-push) + push ---------------------------------------------------------------
hdr "3. s4: docker login ci-push + push ${IMG}"
if "${S4[@]}" "set -eo pipefail
    docker pull -q ${TEST_SRC_IMAGE} >/dev/null
    docker tag ${TEST_SRC_IMAGE} ${IMG}
    out=\$(sudo cat ${CREDS_DIR}/ci-push.password | docker login ${REGISTRY_HOST} -u ci-push --password-stdin 2>&1) || { echo \"\$out\"; exit 1; }
    grep -i 'Login Succeeded' <<<\"\$out\" | sed 's/^/  /'
    docker push ${IMG} | tail -1 | sed 's/^/  /'"; then
  pass "ci-push login + push ${IMG}"
else failt "push"; fi

# --- 4. Kubernetes: imagePullSecret ke saath Running, bina secret 401 -------------------------------
hdr "4. Kubernetes pull test (${NS})"
t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create ns "$NS" >/dev/null
# k8s-pull ka password sirf memory mein (variable); dockerconfigjson stdin se → koi argv/file nahi
pw="$("${S4[@]}" "sudo cat ${CREDS_DIR}/k8s-pull.password")"
auth="$(printf '%s' "k8s-pull:${pw}" | base64 -w0)"; unset pw
printf '{"auths":{"%s":{"auth":"%s"}}}' "$REGISTRY_HOST" "$auth" \
  | kubectl -n "$NS" create secret generic regcred --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin >/dev/null
unset auth
echo "  Secret regcred (kubernetes.io/dockerconfigjson) banaya — sirf test; asal mein Sealed Secrets (Phase 5)"
cat <<EOF | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: with-secret}
spec:
  imagePullSecrets: [{name: regcred}]
  containers: [{name: c, image: ${IMG}, imagePullPolicy: Always, command: [sleep, "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: no-secret}
spec:
  containers: [{name: c, image: ${IMG}, imagePullPolicy: Always, command: [sleep, "3600"]}]
EOF
# (imagePullPolicy: Always — warna pehle pod ki cache ki hui image doosre pod ko bina auth mil jati)
if kubectl -n "$NS" wait --for=condition=Ready pod/with-secret --timeout=180s >/dev/null; then
  pass "with-secret: Running on $(kubectl -n "$NS" get pod with-secret -o jsonpath='{.spec.nodeName}'), image ${IMG} (digest $(kubectl -n "$NS" get pod with-secret -o jsonpath='{.status.containerStatuses[0].imageID}' | grep -o 'sha256:.\{12\}'))"
else failt "with-secret Running nahi"; kubectl -n "$NS" describe pod with-secret | sed -n '/Events/,$p' | tail -5; fi
reason=""
for _ in $(seq 1 30); do
  reason="$(kubectl -n "$NS" get pod no-secret -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')"
  [[ "$reason" == "ImagePullBackOff" ]] && break; sleep 3
done
msg="$(kubectl -n "$NS" get events --field-selector involvedObject.name=no-secret,reason=Failed -o jsonpath='{.items[0].message}')"
kubectl -n "$NS" get pods -o wide
echo "  no-secret event: ${msg}"
# Saboot 1: containerd ka message (401 ko wo "authorization failed: no basic auth credentials" likhta hai)
# Saboot 2: registry ke access log mein usi node se is test ke dauran manifest request pe 401
node_ip="$(kubectl -n "$NS" get pod no-secret -o jsonpath='{.status.hostIP}')"
reglog="$("${S4[@]}" "sudo docker logs --since ${t0} registry-registry-1 2>&1" | grep -E "^${node_ip} .*\"HEAD /v2/${TEST_REPO}/manifests/${TEST_TAG} [^\"]*\" 401 " | tail -1)"
echo "  registry log: ${reglog:-<nahi mila>}"
if [[ "$reason" == "ImagePullBackOff" ]] && grep -q "authorization failed: no basic auth credentials" <<<"$msg" && [[ -n "$reglog" ]]; then
  pass "no-secret: ImagePullBackOff — registry ne ${node_ip} ko 401 diya (bina credential pull mana)"
else failt "no-secret: reason=${reason}, 401 log=${reglog:+haan}"; fi

# --- 5. docker logout + config.json mein credential na rahe ----------------------------------------
hdr "5. s4: docker logout + ~/.docker/config.json"
"${S4[@]}" "docker logout ${REGISTRY_HOST}" | sed 's/^/  /'
left="$("${S4[@]}" "test -f ~/.docker/config.json && jq -r '.auths // {} | keys[]' ~/.docker/config.json; jq -r '.credsStore // empty' ~/.docker/config.json 2>/dev/null" || true)"
echo "  config.json auths/credsStore: '${left}'"
[[ -z "$left" ]] && pass "~/.docker/config.json mein koi credential nahi" || failt "config.json mein abhi bhi: ${left}"

hdr "Summary"
printf '  %s\n' "${RESULTS[@]}"
grep -q '^FAIL' <<<"$(printf '%s\n' "${RESULTS[@]}")" && exit 1 || exit 0
