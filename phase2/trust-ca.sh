#!/usr/bin/env bash
# trust-ca.sh — Lab Root CA (sirf PUBLIC cert) ko node pe trust karwao + registry client config.
#
# Istemaal (node pe, root se):  sudo bash trust-ca.sh <path/to/lab-root-ca.crt>
#   - Har node:            /usr/local/share/ca-certificates/lab-root-ca.crt + update-ca-certificates
#   - Docker wala node (s4): /etc/docker/certs.d/registry.lab.local/ca.crt
#   - Kubernetes node (s1, s2): /etc/containerd/certs.d/registry.lab.local/{ca.crt,hosts.toml}
# skip_verify / insecure-registries KABHI nahi — script mile to fail karti hai.
# containerd restart NAHI karti (hosts.toml har pull pe parha jata hai) — verify karti hai ke restart na hua.
# Idempotent hai.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
log()  { echo "[$(hostname)] [trust-ca] $*"; }
fail() { echo "[$(hostname)] [trust-ca] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
CA_SRC="${1:?lab-root-ca.crt ka path do}"

# Sirf CA certificate ho, private key bilkul nahi
[[ "$(grep -c 'BEGIN CERTIFICATE' "$CA_SRC")" -eq 1 ]] || fail "${CA_SRC} mein aik certificate nahi"
! grep -q 'PRIVATE KEY' "$CA_SRC" || fail "${CA_SRC} mein PRIVATE KEY hai — ruk raha hoon"
grep -q "CA:TRUE" <<<"$(openssl x509 -in "$CA_SRC" -noout -ext basicConstraints)" || fail "ye CA certificate nahi"

changed_any=no
put() {  # put <src> <dest> <mode>
  if ! cmp -s "$1" "$2"; then install -D -m "$3" -o root -g root "$1" "$2"; log "$2 likha"; changed_any=yes; return 0; fi
  return 1
}

# --- Step 1: OS trust store (curl, openssl, Go programs, docker CLI waghera) -----------------------
if put "$CA_SRC" /usr/local/share/ca-certificates/lab-root-ca.crt 0644; then
  update-ca-certificates >/dev/null
  log "update-ca-certificates chalaya"
fi
grep -q "Lab Root CA" <<<"$(openssl crl2pkcs7 -nocrl -certfile /etc/ssl/certs/ca-certificates.crt | openssl pkcs7 -print_certs -noout)" \
  || fail "Lab Root CA system bundle mein nahi aaya"

# --- Step 2a: Docker (s4) --------------------------------------------------------------------------
if command -v dockerd >/dev/null; then
  put "$CA_SRC" "/etc/docker/certs.d/${REGISTRY_HOST}/ca.crt" 0644 || true
  # insecure-registries kahin nahi hona chahiye
  if [[ -f /etc/docker/daemon.json ]] && grep -q insecure-registries /etc/docker/daemon.json; then
    fail "/etc/docker/daemon.json mein insecure-registries hai"
  fi
  log "Docker: /etc/docker/certs.d/${REGISTRY_HOST}/ca.crt"
fi

# --- Step 2b: containerd (Kubernetes nodes) ---------------------------------------------------------
if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  # config_path dono jagah (phase1/containerd.sh) — warna hosts.toml parha hi nahi jayega
  [[ "$(grep -cE "^\s*config_path = '/etc/containerd/certs.d'" <<<"$(containerd config dump)")" -ge 2 ]] \
    || fail "containerd config_path /etc/containerd/certs.d set nahi (phase1/containerd.sh)"
  before="$(systemctl show containerd -p ActiveEnterTimestamp --value)"
  D="/etc/containerd/certs.d/${REGISTRY_HOST}"
  put "$CA_SRC" "${D}/ca.crt" 0644 || true
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# lab-infra phase2 (trust-ca.sh) — ${REGISTRY_HOST} ke liye containerd client config.
# skip_verify KABHI nahi: TLS Lab Root CA (ca.crt) se verify hota hai.
server = "https://${REGISTRY_HOST}"

[host."https://${REGISTRY_HOST}"]
  capabilities = ["pull", "resolve"]
  ca = "${D}/ca.crt"
EOF
  put "$tmp" "${D}/hosts.toml" 0644 || true
  rm -f "$tmp"
  # Kahin bhi skip_verify na ho
  ! grep -rqiE '^\s*skip_verify\s*=\s*true' /etc/containerd/certs.d/ || fail "certs.d mein skip_verify = true mila"
  after="$(systemctl show containerd -p ActiveEnterTimestamp --value)"
  [[ "$before" == "$after" ]] || fail "containerd restart hua?! (${before} → ${after})"
  log "containerd: ${D}/hosts.toml + ca.crt (restart nahi hua: active since ${after})"
fi

# --- Verify: system trust se HTTPS (bina -k / --cacert) → 401 ------------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' "https://${REGISTRY_HOST}/v2/" || true)"
[[ "$code" == "401" ]] || fail "https://${REGISTRY_HOST}/v2/ → ${code:-TLS fail} (401 chahiye)"
log "verify: curl https://${REGISTRY_HOST}/v2/ (bina -k) → 401"
[[ "$changed_any" == "yes" ]] || log "kuch nahi badla"
log "DONE"
