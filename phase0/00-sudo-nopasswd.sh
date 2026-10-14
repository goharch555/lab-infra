#!/usr/bin/env bash
# 00-sudo-nopasswd.sh — user "gohar" ko bina password sudo do (taake s1 se scripts ssh pe chal sakein).
#
# Ye script password apne andar NAHI rakhti. Node pe interactive chalao, sudo aik dafa password poochega:
#   ssh -t gohar@<node-ip> 'bash -s' < 00-sudo-nopasswd.sh
# Idempotent hai.
set -euo pipefail

USER_NAME="${SUDO_USER:-$USER}"
FILE="/etc/sudoers.d/90-${USER_NAME}-nopasswd"
LINE="${USER_NAME} ALL=(ALL) NOPASSWD:ALL"

# Pehle se theek hai to kuch mat karo
if sudo -n true 2>/dev/null && [[ "$(sudo cat "$FILE" 2>/dev/null)" == "$LINE" ]]; then
  echo "[$(hostname)] passwordless sudo pehle se set hai"; exit 0
fi

# Temp file mein likho, visudo se syntax check, phir sahi permission (0440) ke saath install.
# (Ghalat sudoers file sudo ko hi tod deti hai, is liye check zaroori hai.)
tmp="$(mktemp)"
echo "$LINE" > "$tmp"
sudo visudo -cf "$tmp"
sudo install -m 0440 -o root -g root "$tmp" "$FILE"
rm -f "$tmp"

# Verify: cached password bhula kar non-interactive sudo
sudo -k
sudo -n true && echo "[$(hostname)] OK: passwordless sudo (${FILE})"
