#!/usr/bin/env bash
# registry.sh — s4 pe distribution registry (docker compose), TLS (Lab CA) + htpasswd (bcrypt) auth.
#
# Istemaal (s4 pe, root se):  sudo bash registry.sh
# Shart: lab-ca.sh aur docker.sh pehle chal chuki hon.
# Secrets (SIRF s4 pe, KABHI repo/docs/report mein nahi):
#   /root/registry-credentials/{ci-push,k8s-pull}.password  (600)  ← openssl rand
#   /root/registry-credentials/http-secret                  (600)
#   /srv/registry/auth/htpasswd, /srv/registry/certs/registry.key, /srv/registry/registry.env  (600)
# Idempotent: passwords/secret dobara NAHI bante; files badlen to hi registry restart hoti hai.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
log()  { echo "[$(hostname)] [registry] $*"; }
fail() { echo "[$(hostname)] [registry] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
[[ "$(hostname)" == "$REGISTRY_NODE" ]] || fail "sirf ${REGISTRY_NODE} pe"
command -v docker >/dev/null || fail "docker nahi — pehle docker.sh"
[[ -f "${CA_DIR}/${REGISTRY_HOST}.crt" ]] || fail "server cert nahi — pehle lab-ca.sh"
[[ -f "${SCRIPT_DIR}/registry/compose.yaml" && -f "${SCRIPT_DIR}/registry/config.yml" ]] || fail "registry/compose.yaml ya config.yml nahi mila"
grep -q "image: ${REGISTRY_IMAGE}$" "${SCRIPT_DIR}/registry/compose.yaml" || fail "compose.yaml ki image versions.sh (${REGISTRY_IMAGE}) se match nahi"
umask 077
changed=no
# Sirf farq ho to file rakho; farq ho to "changed" (restart chahiye)
put() {  # put <src> <dest> <mode>
  if ! cmp -s "$1" "$2"; then install -m "$3" -o root -g root "$1" "$2"; log "$2 likha"; changed=yes; fi
}

# --- Step 1: htpasswd tool (registry image mein nahi hai) ------------------------------------
if ! command -v htpasswd >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y -o DPkg::Lock::Timeout=300 apache2-utils >/dev/null
  log "apache2-utils (htpasswd) install kiya"
fi

# --- Step 2: Folders ------------------------------------------------------------------------------
install -d -m 0755 -o root -g root "$REGISTRY_DIR"
install -d -m 0700 -o root -g root "${REGISTRY_DIR}/certs" "${REGISTRY_DIR}/auth" "$CREDS_DIR"
install -d -m 0755 -o root -g root "${REGISTRY_DIR}/data"

# --- Step 3: Passwords + http secret (sirf pehli dafa; KABHI print nahi) ------------------------
for u in "${REGISTRY_USERS[@]}" http-secret; do
  f="${CREDS_DIR}/${u}"; [[ "$u" == "http-secret" ]] || f="${f}.password"
  if [[ ! -s "$f" ]]; then
    openssl rand -base64 33 | tr -d '\n/+=' > "$f"   # ~44 random characters
    chmod 600 "$f"; log "${f} banaya (600)"
  fi
done

# --- Step 4: htpasswd (bcrypt). Sab users ke passwords verify hon to file wohi rehti hai ------------
HTP="${REGISTRY_DIR}/auth/htpasswd"
htp_ok=yes
if [[ -f "$HTP" && "$(grep -c . "$HTP")" -eq ${#REGISTRY_USERS[@]} ]]; then
  for u in "${REGISTRY_USERS[@]}"; do
    htpasswd -v -i "$HTP" "$u" < "${CREDS_DIR}/${u}.password" >/dev/null 2>&1 || htp_ok=no
  done
else htp_ok=no; fi
if [[ "$htp_ok" == "no" ]]; then
  tmp="$(mktemp)"
  for u in "${REGISTRY_USERS[@]}"; do
    htpasswd -B -C 12 -i -n "$u" < "${CREDS_DIR}/${u}.password" | grep . >> "$tmp"   # password stdin se (argv mein nahi)
  done
  install -m 0600 -o root -g root "$tmp" "$HTP"; rm -f "$tmp"
  log "htpasswd banaya (bcrypt cost 12): ${REGISTRY_USERS[*]}"; changed=yes
else
  log "htpasswd pehle se theek (dono passwords verify)"
fi

# --- Step 5: registry.env (http secret) ------------------------------------------------------------
tmp="$(mktemp)"; printf 'REGISTRY_HTTP_SECRET=%s\n' "$(cat "${CREDS_DIR}/http-secret")" > "$tmp"
put "$tmp" "${REGISTRY_DIR}/registry.env" 0600; rm -f "$tmp"

# --- Step 6: TLS cert/key + compose/config (repo se) ---------------------------------------------
put "${CA_DIR}/${REGISTRY_HOST}.crt" "${REGISTRY_DIR}/certs/registry.crt" 0644
put "${CA_DIR}/${REGISTRY_HOST}.key" "${REGISTRY_DIR}/certs/registry.key" 0600
put "${SCRIPT_DIR}/registry/config.yml"  "${REGISTRY_DIR}/config.yml"  0644
put "${SCRIPT_DIR}/registry/compose.yaml" "${REGISTRY_DIR}/compose.yaml" 0644

# --- Step 7: Chalao (compose file badli ho to "up -d" khud recreate karta hai; baaqi files ke liye restart)
cd "$REGISTRY_DIR"
docker compose config --quiet || fail "compose.yaml invalid"
docker compose up -d --quiet-pull
if [[ "$changed" == "yes" ]]; then
  docker compose restart registry >/dev/null
  log "registry restart (config/cert/htpasswd badle)"
fi

# --- Verify: TLS (Lab CA se, -k NAHI) + auth zaroori (401) ------------------------------------------
code=""
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "${CA_DIR}/ca.crt" "https://${REGISTRY_HOST}/v2/" || true)"
  [[ "$code" == "401" ]] && break; sleep 2
done
[[ "$code" == "401" ]] || { docker compose logs --tail=20; fail "https://${REGISTRY_HOST}/v2/ ne ${code:-kuch nahi} diya (401 chahiye)"; }
state="$(docker compose ps --format '{{.Service}} {{.State}} {{.Status}}')"
log "verify: /v2/ → 401 (TLS OK, auth zaroori); ${state}"
log "DONE"
