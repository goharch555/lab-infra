#!/usr/bin/env bash
# sudoers-cleanup.sh — /etc/sudoers.d/ ki permissions theek karo (0440 root:root) aur purani,
# faltu files ko /root/sudoers-backup/ mein MOVE karo.
#
# Istemaal (node pe, root se):
#   sudo bash sudoers-cleanup.sh                          # sirf permissions
#   sudo bash sudoers-cleanup.sh nopasswd-sudo username   # permissions + ye files retire
#
# ⚠️ Chalane se pehle aik doosri root session khuli rakho (sudo toot jaye to wapsi ka raasta).
# Har badlao ke baad "visudo -c"; fail ho to wo badlao foran wapas.
# Idempotent hai.
set -euo pipefail

log()  { echo "[$(hostname)] [sudoers-cleanup] $*"; }
fail() { echo "[$(hostname)] [sudoers-cleanup] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "root se chalao"
DIR="/etc/sudoers.d"
BACKUP="/root/sudoers-backup"
LOGIN_USER="${SUDO_USER:-gohar}"
MY_RULE="${DIR}/90-${LOGIN_USER}-nopasswd"   # 00-sudo-nopasswd.sh wali file

# Badlao ke baad check: visudo -c chalao. Badli hui file "parsed OK" ho aur kahin syntax/parse error na ho.
# (Exit code akela kaafi nahi: jab tak DOOSRI files ki permission ghalat hai, visudo -c 1 deta hai.)
check() {
  local f="$1" out
  out="$(visudo -c 2>&1 || true)"
  echo "$out" | sed 's/^/    visudo -c: /'
  ! grep -qiE "syntax error|parse error" <<<"$out" || return 1
  [[ -z "$f" ]] && return 0
  ! grep -E "^${f}:" <<<"$out" | grep -qv "parsed OK"
}
# LOGIN_USER ka passwordless sudo abhi bhi chal raha hai?
nopasswd_ok() { grep -q "NOPASSWD: ALL" <<<"$(sudo -l -U "$LOGIN_USER" 2>/dev/null)"; }

# --- Step A: har file 0440 root:root ------------------------------------------
for f in "$DIR"/*; do
  [[ -f "$f" ]] || continue
  if [[ "$(stat -c '%a %U:%G' "$f")" != "440 root:root" ]]; then
    old_mode="$(stat -c '%a' "$f")"; old_own="$(stat -c '%U:%G' "$f")"
    chown root:root "$f"; chmod 0440 "$f"
    # Badlao ke baad check; fail ho to purani permission wapas
    if ! check "$f"; then
      chown "$old_own" "$f"; chmod "$old_mode" "$f"
      fail "${f} ki permission badalne ke baad visudo -c fail — wapas ${old_mode} ${old_own}"
    fi
    log "${f}: ${old_mode} ${old_own} -> 440 root:root (visudo -c OK)"
  fi
done

# --- Step B: purani files retire karo (MOVE, delete nahi) ---------------------
if [[ $# -gt 0 ]]; then
  # Shart: hamari apni rule file pehle se lagi ho, warna purani file hatane se sudo toot sakta hai
  [[ -f "$MY_RULE" ]] || fail "${MY_RULE} nahi hai — pehle 00-sudo-nopasswd.sh chalao"
  mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
  for name in "$@"; do
    f="${DIR}/${name}"
    [[ -f "$f" ]] || { log "${f} pehle se nahi hai (shayad retire ho chuki)"; continue; }
    mv "$f" "${BACKUP}/${name}"
    # Badlao ke baad: syntax theek ho AUR gohar ka NOPASSWD abhi bhi chale; warna wapas
    if ! check "" || ! nopasswd_ok; then
      mv "${BACKUP}/${name}" "$f"
      fail "${name} hatane ke baad visudo -c ya NOPASSWD check fail — file wapas rakh di"
    fi
    log "${f} -> ${BACKUP}/${name} (visudo -c OK, ${LOGIN_USER} NOPASSWD OK)"
  done
fi

# --- Verify: ab poora visudo -c exit 0 dena chahiye -------------------------------
visudo -c || fail "aakhri visudo -c fail"
nopasswd_ok || fail "${LOGIN_USER} ka NOPASSWD nahi chal raha"
log "DONE"
