#!/usr/bin/env bash
# argocd-cert.sh — argocd.lab.local ka TLS certificate: key + CSR s3 pe, signing s4 ki Lab Root CA se.
#
# Istemaal (s1 pe, gohar se; s3 aur s4 pe ssh + sudo):  bash argocd-cert.sh
# Network pe sirf PUBLIC cheezein jati hain: CSR (s3→s4), certificate (s4→s3), public key (s3→s1 check).
#   - Private key: sirf s3 ki /root/argocd-tls/ (700/600) mein banti aur rehti hai.
#   - CA key: sirf s4 ki /root/lab-ca/ mein.
# SAN/EKU/validity s4 ki taraf se tay hote hain (CSR ki maangi hui extensions use NAHI hoti).
# Idempotent: cert valid ho (CA se verify, SAN sahi, key match, 30+ din) to kuch nahi badalta.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
CA_CRT="${SCRIPT_DIR}/../pki/lab-root-ca.crt"
log()  { echo "[$(hostname)] [argocd-cert] $*"; }
fail() { echo "[$(hostname)] [argocd-cert] ERROR: $*" >&2; exit 1; }
S3=(ssh -o BatchMode=yes "gohar@${MGMT_IP}")
S4=(ssh -o BatchMode=yes "gohar@${REGISTRY_IP}")
[[ -f "$CA_CRT" ]] || fail "${CA_CRT} nahi"
KEY="${ARGOCD_TLS_DIR}/${ARGOCD_HOST}.key"
CRT="${ARGOCD_TLS_DIR}/${ARGOCD_HOST}.crt"
WANT_SAN="DNS:${ARGOCD_HOST},IPAddress:${MGMT_IP}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# Cert theek hai? (CA chain, SAN, EKU, expiry, aur s3 ki key se match — key ki sirf PUBLIC half aati hai)
cert_ok() {
  local crt="$1" pub="$2"
  openssl verify -CAfile "$CA_CRT" "$crt" >/dev/null 2>&1 || { echo "CA se verify nahi"; return 1; }
  [[ "$(openssl x509 -in "$crt" -noout -ext subjectAltName | tail -1 | tr -d ' ')" == "$WANT_SAN" ]] || { echo "SAN mukhtalif"; return 1; }
  grep -q "TLS Web Server Authentication" <<<"$(openssl x509 -in "$crt" -noout -ext extendedKeyUsage)" || { echo "EKU serverAuth nahi"; return 1; }
  openssl x509 -in "$crt" -noout -checkend $(( CERT_RENEW_DAYS * 86400 )) >/dev/null || { echo "${CERT_RENEW_DAYS} din se kam bache"; return 1; }
  [[ "$(openssl x509 -in "$crt" -noout -pubkey)" == "$(cat "$pub")" ]] || { echo "s3 ki key se match nahi"; return 1; }
}

# --- Step 1: s3 pe maujooda haalat (cert + public key) --------------------------------------------
"${S3[@]}" "sudo install -d -m 0700 -o root -g root ${ARGOCD_TLS_DIR}"
"${S3[@]}" "sudo test -f ${CRT} && sudo cat ${CRT}" > "${work}/current.crt" 2>/dev/null || true
"${S3[@]}" "sudo test -f ${KEY} && sudo openssl pkey -in ${KEY} -pubout" > "${work}/current.pub" 2>/dev/null || true
if [[ -s "${work}/current.crt" && -s "${work}/current.pub" ]] && reason="$(cert_ok "${work}/current.crt" "${work}/current.pub")"; then
  log "certificate theek hai — kuch nahi badla"
else
  log "naya certificate bana raha hoon (${reason:-mojood nahi})"

  # --- Step 2: s3 pe NAYI key + CSR (key s3 pe hi; sirf CSR stdout pe aata hai) ------------------------
  "${S3[@]}" "sudo bash -c 'umask 077; openssl ecparam -name prime256v1 -genkey -noout -out ${KEY}.new \
      && openssl req -new -key ${KEY}.new -subj \"/CN=${ARGOCD_HOST}/O=lab-infra\" -sha256'" > "${work}/req.csr"
  grep -q "verify OK" <<<"$(openssl req -in "${work}/req.csr" -noout -verify 2>&1)" || fail "CSR ka self-signature ghalat"
  [[ "$(openssl req -in "${work}/req.csr" -noout -subject)" == "subject=CN = ${ARGOCD_HOST}, O = lab-infra" ]] || fail "CSR subject ghalat"
  log "s3: key (${KEY}.new, 600) + CSR bana; CSR → s4"

  # --- Step 3: s4 pe Lab Root CA se sign (extensions s4 tay karta hai) -----------------------------------
  "${S4[@]}" "sudo bash -c 'set -e; umask 077; ext=\$(mktemp); csr=\$(mktemp); cat > \$csr
      printf \"%s\n\" \"basicConstraints = critical, CA:FALSE\" \"keyUsage = critical, digitalSignature\" \
        \"extendedKeyUsage = serverAuth\" \"subjectAltName = DNS:${ARGOCD_HOST},IP:${MGMT_IP}\" \
        \"subjectKeyIdentifier = hash\" \"authorityKeyIdentifier = keyid:always\" > \$ext
      openssl x509 -req -in \$csr -CA /root/lab-ca/ca.crt -CAkey /root/lab-ca/ca.key -CAserial /root/lab-ca/ca.srl \
        -days ${CERT_DAYS} -sha256 -extfile \$ext 2>/dev/null
      rm -f \$ext \$csr'" < "${work}/req.csr" > "${work}/new.crt"
  grep -q "BEGIN CERTIFICATE" "${work}/new.crt" || fail "s4 se signed certificate nahi aaya"
  log "s4: Lab Root CA ne sign kiya"

  # --- Step 4: s1 pe check (naya cert + s3 ki NAYI key ki public half) → phir hi s3 pe rakho -------------
  "${S3[@]}" "sudo openssl pkey -in ${KEY}.new -pubout" > "${work}/new.pub"
  reason="$(cert_ok "${work}/new.crt" "${work}/new.pub")" || fail "naya cert check fail: ${reason}"
  "${S3[@]}" "sudo bash -c 'umask 022; cat > ${CRT}.new && chmod 644 ${CRT}.new && mv ${KEY}.new ${KEY} && mv ${CRT}.new ${CRT}'" < "${work}/new.crt"
  log "s3: ${CRT} (644) + ${KEY} (600) rakhe"
fi

# --- Verify (repo wali public CA se) ----------------------------------------------------------------
"${S3[@]}" "sudo cat ${CRT}" > "${work}/final.crt"
"${S3[@]}" "sudo openssl pkey -in ${KEY} -pubout" > "${work}/final.pub"
openssl verify -CAfile "$CA_CRT" "${work}/final.crt"
reason="$(cert_ok "${work}/final.crt" "${work}/final.pub")" || fail "final check: ${reason}"
perms="$("${S3[@]}" "sudo stat -c '%a %n' ${ARGOCD_TLS_DIR} ${KEY} ${CRT}")"
grep -q "^700 ${ARGOCD_TLS_DIR}$" <<<"$perms" && grep -q "^600 ${KEY}$" <<<"$perms" || fail "permissions ghalat: ${perms}"
log "verify: $(openssl x509 -in "${work}/final.crt" -noout -subject -issuer -enddate | xargs); SAN ${WANT_SAN}; key s3 pe (600)"
log "DONE"
