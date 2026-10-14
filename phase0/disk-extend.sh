#!/usr/bin/env bash
# disk-extend.sh — root (/) ke LVM volume mein VG ki saari khaali jagah daalo, ONLINE (unmount ke baghair).
#
# Istemaal (node pe, root se):  sudo bash disk-extend.sh
# Idempotent hai: VG mein khaali jagah na ho to kuch nahi karti.
# Inventory mein DISK_EXTEND_NODES (abhi s1, s3) pe chalti hai.
set -euo pipefail

log()  { echo "[$(hostname)] [disk-extend] $*"; }
fail() { echo "[$(hostname)] [disk-extend] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "root se chalao"

# / kis device pe hai? LVM na ho to ruk jao (andaze se kuch nahi)
ROOT_SRC="$(findmnt -no SOURCE /)"
ROOT_FS="$(findmnt -no FSTYPE /)"
lvs "$ROOT_SRC" >/dev/null 2>&1 || fail "/ (${ROOT_SRC}) LVM logical volume nahi hai"

# LV ka asal path aur VG lvs se lo (hardcode nahi)
read -r LV_PATH VG_NAME < <(lvs --noheadings -o lv_path,vg_name "$ROOT_SRC" | awk '{print $1, $2}')
[[ -n "$LV_PATH" && -n "$VG_NAME" ]] || fail "lvs se LV path/VG nahi mila"
log "root: ${ROOT_SRC} (${ROOT_FS}) -> LV ${LV_PATH}, VG ${VG_NAME}"

# Sirf wahi filesystem jinhein lvextend -r online bara kar sakta hai
[[ "$ROOT_FS" == "ext4" || "$ROOT_FS" == "xfs" ]] || fail "filesystem ${ROOT_FS} ke liye ye script test nahi hui"

# Pehle ki haalat
log "pehle:"; df -h /

# VG mein kitne khaali extents hain? 0 ho to kuch mat karo
FREE_PE="$(vgs --noheadings -o vg_free_count "$VG_NAME" | tr -d ' ')"
if [[ "$FREE_PE" -eq 0 ]]; then
  log "VG ${VG_NAME} mein koi khaali jagah nahi — kuch nahi kiya"
  exit 0
fi
log "VG ${VG_NAME} mein $(vgs --noheadings --units g -o vg_free "$VG_NAME" | tr -d ' ') khaali (${FREE_PE} extents) — extend kar raha hoon"

# LV + filesystem dono aik saath bara karo (-r = resizefs), online
lvextend -r -l +100%FREE "$LV_PATH"

# Verify: VG mein ab 0 khaali, aur filesystem LV jitna bara
[[ "$(vgs --noheadings -o vg_free_count "$VG_NAME" | tr -d ' ')" -eq 0 ]] || fail "extend ke baad bhi VG mein jagah baaqi"
log "baad:"; df -h /
log "DONE"
