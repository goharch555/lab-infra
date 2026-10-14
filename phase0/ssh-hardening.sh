#!/usr/bin/env bash
# ssh-hardening.sh — Step 9: SSH pe password login aur root login band karo.
#
# ⚠️ Isay TAB TAK mat chalao jab tak confirm na ho ke Windows (aur s1) se HAR node pe
#    key-based login chal raha hai. Warna aap khud ko lock-out kar sakte hain.
#
# Istemaal (node pe, root se):  sudo bash ssh-hardening.sh --i-confirmed-key-login
# Idempotent hai.
set -euo pipefail

log()  { echo "[$(hostname)] [ssh-hardening] $*"; }
fail() { echo "[$(hostname)] [ssh-hardening] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "root se chalao"
# Ghalti se chalne se bachao: explicit confirmation flag zaroori
[[ "${1:-}" == "--i-confirmed-key-login" ]] || fail "pehle key login confirm karo, phir --i-confirmed-key-login ke saath chalao"

# Safety: jis user ke liye ye kiya ja raha hai us ki authorized_keys khaali na ho
LOGIN_USER="${SUDO_USER:-gohar}"
AUTH_KEYS="$(getent passwd "$LOGIN_USER" | cut -d: -f6)/.ssh/authorized_keys"
[[ -s "$AUTH_KEYS" ]] || fail "${AUTH_KEYS} khaali/ghayab hai — password band kiya to lock-out ho jaoge"

# Drop-in file: sshd har setting ki PEHLI value maanta hai, aur sshd_config.d/*.conf
# alphabetical order mein parhi jati hain. "00-" naam se ye 50-cloud-init.conf se pehle parhi jayegi.
DROPIN="/etc/ssh/sshd_config.d/00-lab-hardening.conf"
DESIRED=$'# lab-infra phase0 — ssh-hardening.sh\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no'
if [[ "$(cat "$DROPIN" 2>/dev/null)" != "$DESIRED" ]]; then
  [[ -f "$DROPIN" ]] && cp -a "$DROPIN" "${DROPIN}.bak"
  printf '%s\n' "$DESIRED" > "$DROPIN"
  chmod 644 "$DROPIN"
  log "${DROPIN} likha"
fi

# Config test — fail ho to file wapas/hatao, reload MAT karo
if ! sshd -t; then
  if [[ -f "${DROPIN}.bak" ]]; then mv "${DROPIN}.bak" "$DROPIN"; else rm -f "$DROPIN"; fi
  fail "sshd -t fail hua; change wapas kar di, reload nahi kiya"
fi
rm -f "${DROPIN}.bak"

# Effective config verify (sshd -T asal maani hui values dikhata hai)
eff="$(sshd -T 2>/dev/null)"
grep -qx "passwordauthentication no" <<<"$eff" || fail "effective PasswordAuthentication 'no' nahi"
grep -qx "permitrootlogin no"        <<<"$eff" || fail "effective PermitRootLogin 'no' nahi"

# Sirf ab reload (restart nahi — maujooda SSH sessions nahi tootte)
systemctl reload ssh
log "DONE: password auth + root login band. Nayi terminal se key login test karo, purani session band mat karna."
