#!/usr/bin/env bash
# install-calico.sh — Calico CNI, Tigera operator ke zariye (version pinned, manifests repo mein).
#
# Istemaal (s1 pe, gohar se; ~/.kube/config chahiye):  bash install-calico.sh
# Idempotent hai: server-side apply (dobara chalane pe sirf farq lagta hai).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
CDIR="${SCRIPT_DIR}/calico"

log()  { echo "[$(hostname)] [install-calico] $*"; }
fail() { echo "[$(hostname)] [install-calico] ERROR: $*" >&2; exit 1; }
kubectl get --raw=/readyz >/dev/null 2>&1 || fail "kubectl cluster tak nahi pohanch raha"

# --- Step 1: Manifests ki integrity (repo mein save hain, download nahi) ------------------
( cd "$CDIR" && sha256sum -c --quiet SHA256SUMS ) || fail "calico manifests ka sha256 match nahi"
grep -q "quay.io/tigera/operator:" "${CDIR}/tigera-operator.yaml" || fail "tigera-operator.yaml ajeeb hai"
grep -q "cidr: ${POD_SUBNET}$" "${CDIR}/installation.yaml" || fail "installation.yaml ka cidr ${POD_SUBNET} nahi"

# --- Step 2: CRDs (bohat bari file → server-side apply; client-side annotation limit se bachne ke liye)
kubectl apply --server-side --force-conflicts -f "${CDIR}/operator-crds.yaml" >/dev/null
kubectl wait --for=condition=Established crd/installations.operator.tigera.io --timeout=60s >/dev/null
log "CRDs applied"

# --- Step 3: Operator ------------------------------------------------------------------------
kubectl apply --server-side --force-conflicts -f "${CDIR}/tigera-operator.yaml" >/dev/null
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=300s
log "tigera-operator ready"

# --- Step 4: Installation (hamara config) -----------------------------------------------------
# Pehli dafa: apply. Baad mein: dobara apply NAHI (operator ipPools mein apne defaults bhar kar us field
# ka owner ban jata hai; dobara server-side apply conflict deta hai, aur --force-conflicts operator se
# kheench-taan karega). Is ke bajaye zaroori fields compare karo; farq ho to ruk jao, kyunke live
# cluster pe IP pool ka CIDR/encapsulation badalna aam apply ka kaam nahi.
if ! kubectl get installation default >/dev/null 2>&1; then
  kubectl apply --server-side -f "${CDIR}/installation.yaml" >/dev/null
  log "Installation applied — Calico components ka intezar (images pull hoti hain, kuch minute)"
else
  want="$(python3 -c 'import sys,yaml,json; d=yaml.safe_load(open(sys.argv[1]))["spec"]["calicoNetwork"]; print(json.dumps({"pools":[{k:p.get(k) for k in ("name","cidr","blockSize","encapsulation","natOutgoing","nodeSelector")} for p in d["ipPools"]],"autodetect":d.get("nodeAddressAutodetectionV4")},sort_keys=True))' "${CDIR}/installation.yaml")"
  have="$(kubectl get installation default -o json | jq -cS '.spec.calicoNetwork | {pools: [.ipPools[] | {name, cidr, blockSize, encapsulation, natOutgoing, nodeSelector}], autodetect: .nodeAddressAutodetectionV4}')"
  [[ "$(jq -cS . <<<"$want")" == "$have" ]] || fail "live Installation installation.yaml se mukhtalif hai — khud dekho (want=${want} have=${have})"
  log "Installation pehle se mojood aur installation.yaml se match (dobara apply nahi kiya)"
fi

# --- Verify: tigerastatus Available + nodes Ready ----------------------------------------------
for _ in $(seq 1 240); do   # 20 min: dheemi image downloads (s2 pe ~10 min lage)
  if grep -q True <<<"$(kubectl get tigerastatus calico -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)"; then break; fi
  sleep 5
done
grep -q True <<<"$(kubectl get tigerastatus calico -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" \
  || { kubectl get tigerastatus; kubectl get pods -A | grep -v Running; fail "Calico 20 min mein Available nahi hua"; }
kubectl get tigerastatus
kubectl wait --for=condition=Ready node --all --timeout=180s
# IP pool sahi bana?
grep -q "^${POD_SUBNET} CrossSubnet true" <<<"$(kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.cidr} {.spec.vxlanMode} {.spec.natOutgoing}{"\n"}' 2>/dev/null)" \
  || fail "IP pool ${POD_SUBNET}/CrossSubnet/natOutgoing nahi"
log "verify: tigerastatus Available, nodes Ready, IP pool ${POD_SUBNET} VXLANCrossSubnet natOutgoing"
log "DONE"
