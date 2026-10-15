#!/usr/bin/env bash
# verify.sh — Phase 1 cluster ke 7 tests. Test resources "phase1-test" namespace mein, aakhir mein delete.
#
# Istemaal (s1 pe, gohar se):  bash verify.sh
# Har test PASS / WARN / FAIL. Koi FAIL ho to exit 1.
set -uo pipefail     # -e nahi: har test chalna chahiye, nateeja aakhir mein

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
NS="phase1-test"
BUSYBOX="busybox:1.37.0"
NGINX="nginx:1.29.1-alpine"
RESULTS=()
pass() { RESULTS+=("PASS  $1"); echo "  ✅ PASS: $1"; }
warn() { RESULTS+=("WARN  $1"); echo "  ⚠️  WARN: $1"; }
failt(){ RESULTS+=("FAIL  $1"); echo "  ❌ FAIL: $1"; }
hdr()  { echo; echo "=== $* ==="; }

# Test namespace: shuru mein saaf, aakhir mein (kuch bhi ho) delete
kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null
kubectl create ns "$NS" >/dev/null
trap 'echo; echo "phase1-test namespace delete kar raha hoon..."; kubectl delete ns "$NS" --wait=true >/dev/null && echo "namespace deleted"' EXIT

# --- 1. Nodes -------------------------------------------------------------------------------
hdr "1. Nodes"
kubectl get nodes -o wide
ok=yes
for n in "${!K8S_NODE_IP[@]}"; do
  ready="$(kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  ip="$(kubectl get node "$n" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
  ver="$(kubectl get node "$n" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null)"
  [[ "$ready" == "True" && "$ip" == "${K8S_NODE_IP[$n]}" && "$ver" == "$K8S_VERSION" ]] || { ok=no; echo "  ${n}: Ready=${ready} IP=${ip} version=${ver}"; }
done
[[ "$ok" == yes ]] && pass "nodes s1,s2 Ready, sahi IPs, ${K8S_VERSION}" || failt "nodes"

# --- 2. Pods --------------------------------------------------------------------------------
hdr "2. Saare pods"
kubectl get pods -A -o wide
notrun="$(kubectl get pods -A --no-headers | grep -v "$NS" | awk '{split($3,a,"/"); if ($4!="Running" || a[1]!=a[2]) print $1"/"$2" "$3" "$4}')"
restarts="$(kubectl get pods -A --no-headers | grep -v "$NS" | awk '$5!="0" {print $1"/"$2"="$5}')"
if [[ -n "$notrun" ]]; then failt "pods Running/Ready nahi: ${notrun//$'\n'/, }"
else pass "saare pods Running + Ready"; fi
if [[ -n "$restarts" ]]; then warn "restarts > 0: $(echo $restarts)"; else pass "kisi pod ka restart nahi"; fi

# --- 3. DNS ---------------------------------------------------------------------------------
hdr "3. DNS (temporary pod se nslookup)"
# DNS UDP hai: aik akela packet gum ho sakta hai, is liye har naam ke liye 3 koshishen (har koshish dikhai jati hai)
if out="$(kubectl -n "$NS" run dns-test --image="$BUSYBOX" --restart=Never --rm -i --quiet --command -- sh -c '
      for name in kubernetes.default.svc.cluster.local github.com; do
        for try in 1 2 3; do
          if nslookup -timeout=3 "$name" >/tmp/o 2>&1 && grep -q "^Address: [0-9]" /tmp/o; then
            echo "RESULT $name OK try=$try $(grep "^Address: [0-9]" /tmp/o | head -1)"; break
          fi
          echo "RESULT $name try=$try fail"; [ "$try" = 3 ] && echo "RESULT $name FAILED"
        done
      done' 2>&1)"; then
  grep "^RESULT" <<<"$out" | sed 's/^RESULT /  /'
  grep -q "^RESULT kubernetes.default.svc.cluster.local OK .*Address: 10.96.0.1$" <<<"$out" && pass "kubernetes.default -> 10.96.0.1" || failt "kubernetes.default resolve nahi"
  grep -q "^RESULT github.com OK" <<<"$out" && pass "github.com resolve (bahar ka DNS) $(grep -o 'github.com OK try=[0-9]' <<<"$out")" || failt "github.com resolve nahi"
  grep -q " try=[23] " <<<"$out" && warn "DNS: kisi lookup ko retry chahiye para (upar dekho)"
else echo "$out" | tail -5; failt "DNS test pod"; fi

# --- 4. Cross-node pod networking -------------------------------------------------------------
hdr "4. Cross-node ping (s1 <-> s2)"
cat <<EOF | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: net-s1}
spec:
  nodeSelector: {kubernetes.io/hostname: s1}
  tolerations: [{key: node-role.kubernetes.io/control-plane, operator: Exists, effect: NoSchedule}]
  containers: [{name: c, image: ${BUSYBOX}, command: [sleep, "3600"]}]
---
apiVersion: v1
kind: Pod
metadata: {name: net-s2}
spec:
  nodeSelector: {kubernetes.io/hostname: s2}
  containers: [{name: c, image: ${BUSYBOX}, command: [sleep, "3600"]}]
EOF
if kubectl -n "$NS" wait --for=condition=Ready pod/net-s1 pod/net-s2 --timeout=180s >/dev/null; then
  ip1="$(kubectl -n "$NS" get pod net-s1 -o jsonpath='{.status.podIP}')"
  ip2="$(kubectl -n "$NS" get pod net-s2 -o jsonpath='{.status.podIP}')"
  kubectl -n "$NS" get pods -o wide
  r1="$(kubectl -n "$NS" exec net-s1 -- ping -c3 -W2 "$ip2" 2>&1 | tail -2)"; echo "  s1 -> s2 (${ip2}): $(head -1 <<<"$r1")"
  r2="$(kubectl -n "$NS" exec net-s2 -- ping -c3 -W2 "$ip1" 2>&1 | tail -2)"; echo "  s2 -> s1 (${ip1}): $(head -1 <<<"$r2")"
  grep -q " 0% packet loss" <<<"$r1" && grep -q " 0% packet loss" <<<"$r2" && pass "pod-to-pod s1<->s2 ping, 0% loss" || failt "cross-node ping"
else failt "net test pods Ready nahi hue"; fi
kubectl -n "$NS" delete pod net-s1 net-s2 --wait=false >/dev/null 2>&1

# --- 5. Service (ClusterIP) -----------------------------------------------------------------------
hdr "5. nginx Deployment + ClusterIP Service"
kubectl -n "$NS" create deployment web --image="$NGINX" --replicas=2 >/dev/null
kubectl -n "$NS" expose deployment web --port=80 --type=ClusterIP >/dev/null
if kubectl -n "$NS" rollout status deploy/web --timeout=180s >/dev/null; then
  kubectl -n "$NS" get deploy,svc,endpointslices -o wide
  if out="$(kubectl -n "$NS" run curl-test --image="$BUSYBOX" --restart=Never --rm -i --quiet --command -- \
        wget -qO- -T 5 "http://web.${NS}.svc.cluster.local" 2>&1)" && grep -q "Welcome to nginx" <<<"$out"; then
    pass "Service web.${NS} (ClusterIP) se nginx jawab"
  else echo "$out" | tail -3; failt "Service curl"; fi
else failt "nginx deployment ready nahi"; fi

# --- 6. Certificates ------------------------------------------------------------------------------
hdr "6. kubeadm certs check-expiration"
certs="$(sudo kubeadm certs check-expiration 2>&1)"; echo "$certs"
grep -qE "invalid|expired" <<<"$certs" && failt "koi certificate expired/invalid" || pass "certificates valid"

# --- 7. etcd health + backup timer ---------------------------------------------------------------
hdr "7. etcd health + backup"
E=(sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt
   --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key)
"${E[@]}" endpoint health -w table && "${E[@]}" endpoint status -w table && pass "etcd healthy" || failt "etcd health"
systemctl list-timers etcd-snapshot.timer --no-pager | head -2
latest="$(sudo bash -c 'ls -1t /var/backups/etcd/etcd-snapshot-*.db 2>/dev/null | head -1')"
if systemctl is-enabled --quiet etcd-snapshot.timer && systemctl is-active --quiet etcd-snapshot.timer && [[ -n "$latest" ]]; then
  sudo etcdutl snapshot status "$latest" -w table
  pass "backup timer active, latest snapshot ${latest##*/}"
else failt "etcd backup timer/snapshot"; fi

# --- Summary ------------------------------------------------------------------------------------
hdr "Summary"
printf '  %s\n' "${RESULTS[@]}"
grep -q '^FAIL' <<<"$(printf '%s\n' "${RESULTS[@]}")" && exit 1 || exit 0
