#!/usr/bin/env bash
# netplan-safe-apply.sh — netplan apply karo; 30 second mein gateway na mile to purani config wapas lagao.
#
# Istemaal: netplan-safe-apply.sh <backup_dir> <gateway> [timeout_seconds]
#   <backup_dir> mein /etc/netplan ki purani *.yaml files honi chahiye.
#
# common.sh isay "systemd-run" ke zariye chalati hai, taake agar apply ke dauran
# SSH connection toot jaye to bhi ye script poori chale (aur zaroorat ho to rollback kare).
set -euo pipefail

BACKUP_DIR="${1:?backup dir do}"
GW="${2:?gateway do}"
TIMEOUT="${3:-30}"

log() { echo "[netplan-safe-apply] $*"; }

# Rollback: nayi files hatao, backup wali wapas rakho, phir apply
rollback() {
  log "ROLLBACK: ${TIMEOUT}s mein gateway ${GW} nahi mila, purani config wapas laga raha hoon"
  find /etc/netplan -maxdepth 1 -name '*.yaml' -delete
  cp -a "${BACKUP_DIR}"/*.yaml /etc/netplan/
  netplan generate
  netplan apply
  log "ROLLBACK mukammal"
  exit 1
}

# Rollback ke liye backup ka hona zaroori hai, warna apply hi mat karo
compgen -G "${BACKUP_DIR}/*.yaml" >/dev/null || { log "ERROR: ${BACKUP_DIR} mein koi yaml backup nahi"; exit 2; }

# Nayi config lagao (agar apply khud fail ho to bhi rollback)
log "netplan apply chala raha hoon"
netplan apply || rollback

# Har second check karo, TIMEOUT tak: default route gateway pe lag chuka ho AUR gateway ping ho.
# (Sirf ping kafi nahi: gateway same subnet mein hai, route lagne se pehle bhi ping ho jata hai.)
start=$SECONDS
while (( SECONDS - start < TIMEOUT )); do
  if grep -q "via ${GW} " <<<"$(ip -4 route show default)" && ping -c1 -W1 "$GW" >/dev/null 2>&1; then
    log "OK: default route + gateway ${GW} $((SECONDS - start))s mein mil gaye"
    exit 0
  fi
  sleep 1
done

rollback
