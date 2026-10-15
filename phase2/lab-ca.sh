#!/usr/bin/env bash
# lab-ca.sh — s4 pe "Lab Root CA" (ECDSA P-256, 10 saal) + registry.lab.local ka server certificate (1 saal).
#
# Istemaal (s4 pe, root se):  sudo bash lab-ca.sh
# Nateeja:
#   /root/lab-ca/ca.key  (600)   ← CA ki PRIVATE key: KABHI repo ya kisi aur node pe nahi
#   /root/lab-ca/ca.crt          ← public; repo mein pki/lab-root-ca.crt
#   /root/lab-ca/registry.lab.local.{key,crt}  ← server cert/key (registry.sh /srv/registry/certs mein copy karti hai)
# Idempotent:
#   - CA mojood ho to dobara NAHI banta (naya CA = har node pe trust dobara).
#   - Server cert tab hi dobara banta hai jab na ho, SAN ghalat ho, CA se verify na ho, ya 30 din se kam bache hon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
log()  { echo "[$(hostname)] [lab-ca] $*"; }
fail() { echo "[$(hostname)] [lab-ca] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
[[ "$(hostname)" == "$REGISTRY_NODE" ]] || fail "CA sirf ${REGISTRY_NODE} pe banta hai (key yahin rehti hai)"

umask 077                                     # is script ki har nayi file sirf root parh sake
install -d -m 0700 -o root -g root "$CA_DIR"
CA_KEY="${CA_DIR}/ca.key"; CA_CRT="${CA_DIR}/ca.crt"
SRV_KEY="${CA_DIR}/${REGISTRY_HOST}.key"; SRV_CRT="${CA_DIR}/${REGISTRY_HOST}.crt"
SAN="DNS:${REGISTRY_HOST},IP:${REGISTRY_IP}"

# --- Step 1: Root CA (sirf agar nahi hai) ----------------------------------------------------
if [[ -f "$CA_KEY" && -f "$CA_CRT" ]]; then
  log "Root CA pehle se mojood — dobara nahi bana raha"
else
  [[ ! -f "$CA_KEY" && ! -f "$CA_CRT" ]] || fail "CA ki key ya cert mein se aik ghayab hai — khud dekho"
  openssl ecparam -name prime256v1 -genkey -noout -out "$CA_KEY"
  # CA extensions: sirf certificates sign kar sake (keyCertSign/cRLSign), aur iske neeche koi aur CA nahi (pathlen:0)
  openssl req -x509 -new -key "$CA_KEY" -sha256 -days "$CA_DAYS" -subj "$CA_SUBJECT" -out "$CA_CRT" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
  log "Root CA banaya: $(openssl x509 -in "$CA_CRT" -noout -subject -enddate | xargs)"
fi
chmod 600 "$CA_KEY"; chmod 644 "$CA_CRT"

# --- Step 2: Server certificate (registry.lab.local) -------------------------------------------
need_new=no
if [[ ! -f "$SRV_KEY" || ! -f "$SRV_CRT" ]]; then
  need_new=yes; reason="mojood nahi"
elif ! openssl verify -CAfile "$CA_CRT" "$SRV_CRT" >/dev/null 2>&1; then
  need_new=yes; reason="CA se verify nahi hota"
elif ! openssl x509 -in "$SRV_CRT" -noout -checkend $(( SERVER_RENEW_DAYS * 86400 )) >/dev/null; then
  need_new=yes; reason="${SERVER_RENEW_DAYS} din se kam bache"
elif [[ "$(openssl x509 -in "$SRV_CRT" -noout -ext subjectAltName | tail -1 | tr -d ' ')" != "DNS:${REGISTRY_HOST},IPAddress:${REGISTRY_IP}" ]]; then
  need_new=yes; reason="SAN mukhtalif"
fi

if [[ "$need_new" == "yes" ]]; then
  log "server cert bana raha hoon (${reason})"
  openssl ecparam -name prime256v1 -genkey -noout -out "${SRV_KEY}.new"
  openssl req -new -key "${SRV_KEY}.new" -subj "/CN=${REGISTRY_HOST}/O=lab-infra" -out "${CA_DIR}/server.csr"
  ext="$(mktemp)"
  cat > "$ext" <<EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = ${SAN}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
  openssl x509 -req -in "${CA_DIR}/server.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
    -days "$SERVER_DAYS" -sha256 -extfile "$ext" -out "${SRV_CRT}.new"
  rm -f "$ext" "${CA_DIR}/server.csr"
  mv "${SRV_KEY}.new" "$SRV_KEY"; mv "${SRV_CRT}.new" "$SRV_CRT"
  log "server cert banaya"
else
  log "server cert theek hai (valid, SAN sahi, ${SERVER_RENEW_DAYS}+ din baaqi)"
fi
chmod 600 "$SRV_KEY"; chmod 644 "$SRV_CRT"

# --- Verify -------------------------------------------------------------------------------------
openssl verify -CAfile "$CA_CRT" "$SRV_CRT" >/dev/null || fail "server cert CA se verify nahi"
grep -q "TLS Web Server Authentication" <<<"$(openssl x509 -in "$SRV_CRT" -noout -ext extendedKeyUsage)" || fail "EKU serverAuth nahi"
[[ "$(stat -c '%a' "$CA_DIR")" == "700" && "$(stat -c '%a' "$CA_KEY")" == "600" ]] || fail "CA folder/key permissions ghalat"
log "verify: chain OK; server: $(openssl x509 -in "$SRV_CRT" -noout -subject -enddate | xargs); SAN: ${SAN}"
log "DONE"
