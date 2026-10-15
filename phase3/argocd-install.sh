#!/usr/bin/env bash
# argocd-install.sh — s3 (k3s) pe Argo CD: helm (pinned) + TLS Secret + helm upgrade --install.
#
# Istemaal (s3 pe, root se):  sudo bash argocd-install.sh <path/to/lab-root-ca.crt>
#   (CA sirf verify ke liye: curl --cacert. s3 ke trust store ko nahi chhedti.)
# Shart: k3s.sh aur argocd-cert.sh (key/cert /root/argocd-tls/ mein) pehle chal chuki hon.
# - TLS Secret "argocd-server-tls" s3 ki key/cert se, kubectl ke zariye (BOOTSTRAP — baad mein cert-manager).
# - helm release sirf tab upgrade hoti hai jab chart version ya values badlen.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
VALUES="${SCRIPT_DIR}/argocd/values.yaml"
CA_CRT="${1:?lab-root-ca.crt ka path do (verify ke liye)}"
log()  { echo "[$(hostname)] [argocd-install] $*"; }
fail() { echo "[$(hostname)] [argocd-install] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
[[ "$(hostname)" == "$MGMT_NODE" ]] || fail "sirf ${MGMT_NODE} pe (TLS key yahin hai)"
[[ -f "$VALUES" ]] || fail "${VALUES} nahi"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KEY="${ARGOCD_TLS_DIR}/${ARGOCD_HOST}.key"; CRT="${ARGOCD_TLS_DIR}/${ARGOCD_HOST}.crt"
[[ -f "$KEY" && -f "$CRT" ]] || fail "TLS key/cert nahi — pehle argocd-cert.sh"

# --- Step 1: helm (pinned, sha256 verify) ----------------------------------------------------------
if [[ "$(helm version --template '{{.Version}}' 2>/dev/null || true)" != "$HELM_VERSION" ]]; then
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  tgz="helm-${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "${work}/${tgz}" "https://get.helm.sh/${tgz}"
  echo "${HELM_SHA256}  ${work}/${tgz}" | sha256sum -c --quiet || fail "helm tarball ka sha256 match nahi"
  tar -xzf "${work}/${tgz}" -C "$work" linux-amd64/helm
  install -m 0755 "${work}/linux-amd64/helm" /usr/local/bin/helm
  log "helm ${HELM_VERSION} install (sha256 OK)"
else
  log "helm pehle se ${HELM_VERSION}"
fi

# --- Step 2: Namespace + TLS Secret (key s3 se bahar nahi; kubectl apply = renewal pe update) ---------
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
before="$(kubectl -n "$ARGOCD_NS" get secret argocd-server-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
kubectl -n "$ARGOCD_NS" create secret tls argocd-server-tls --cert="$CRT" --key="$KEY" --dry-run=client -o yaml \
  | kubectl label --local -f - app.kubernetes.io/part-of=argocd app.kubernetes.io/managed-by=lab-infra-phase3 -o yaml \
  | kubectl apply -f - >/dev/null
after="$(kubectl -n "$ARGOCD_NS" get secret argocd-server-tls -o jsonpath='{.data.tls\.crt}')"
[[ "$before" == "$after" ]] && log "Secret argocd-server-tls pehle se theek" || log "Secret argocd-server-tls (kubernetes.io/tls) banaya/update kiya"

# --- Step 3: helm upgrade --install (sirf agar chart/values badle) -----------------------------------------
need=yes
if helm -n "$ARGOCD_NS" status argocd >/dev/null 2>&1; then
  cur_chart="$(helm -n "$ARGOCD_NS" list -f '^argocd$' -o json | jq -r '.[0].chart')"
  cur_status="$(helm -n "$ARGOCD_NS" list -f '^argocd$' -o json | jq -r '.[0].status')"
  same_values="$(python3 -c 'import sys,yaml; a=yaml.safe_load(open(sys.argv[1])) or {}; b=yaml.safe_load(sys.stdin) or {}; print(a==b)' "$VALUES" \
                 < <(helm -n "$ARGOCD_NS" get values argocd -o yaml))"
  if [[ "$cur_chart" == "argo-cd-${ARGOCD_CHART_VERSION}" && "$cur_status" == "deployed" && "$same_values" == "True" ]]; then
    need=no; log "helm release argocd pehle se ${cur_chart}, same values — upgrade nahi"
  fi
fi
if [[ "$need" == "yes" ]]; then
  log "helm upgrade --install argo-cd ${ARGOCD_CHART_VERSION} (images pull ho sakti hain — 15 min tak)"
  helm upgrade --install argocd argo-cd --repo "$ARGOCD_CHART_REPO" --version "$ARGOCD_CHART_VERSION" \
    -n "$ARGOCD_NS" -f "$VALUES" --wait --timeout 15m >/dev/null
  log "helm release deployed"
fi

# --- Step 4: Sab workloads ready ----------------------------------------------------------------------------
for w in $(kubectl -n "$ARGOCD_NS" get deploy,statefulset -o name); do
  kubectl -n "$ARGOCD_NS" rollout status "$w" --timeout=600s >/dev/null || fail "${w} ready nahi"
done
kubectl -n "$ARGOCD_NS" get pods -o wide
notrun="$(kubectl -n "$ARGOCD_NS" get pods --no-headers | awk '{split($2,a,"/"); if ($3!="Running" || a[1]!=a[2]) print $1}')"
[[ -z "$notrun" ]] || fail "pods Running/Ready nahi: ${notrun}"

# --- Verify: Ingress + HTTPS (Lab CA se, -k NAHI) + port 80 pe Argo CD nahi -------------------------------
kubectl -n "$ARGOCD_NS" get ingress argocd-server -o wide
code=""
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA_CRT" "https://${ARGOCD_HOST}/" || true)"
  [[ "$code" == "200" ]] && break; sleep 2
done
[[ "$code" == "200" ]] || fail "https://${ARGOCD_HOST}/ → ${code:-TLS/connection fail} (200 chahiye)"
http80="$(curl -s -o /dev/null -w '%{http_code}' "http://${ARGOCD_HOST}/" || true)"
[[ "$http80" != "200" ]] || fail "Argo CD plain HTTP (port 80) pe bhi mil raha hai"
log "verify: pods Running, https://${ARGOCD_HOST}/ → 200 (Lab CA), http:// → ${http80} (Argo CD nahi)"
log "DONE"
