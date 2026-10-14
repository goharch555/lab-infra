#!/usr/bin/env bash
# common.sh — Phase 0: har node (s1..s4) pe base preparation.
#
# Istemaal (node pe, root se):   sudo bash common.sh <s1|s2|s3|s4>
# Idempotent hai: dobara chalane se sirf wohi cheez badalti hai jo desired state se mukhtalif ho.
# Agar upgrade ke baad reboot chahiye ho to aakhir mein "REBOOT_REQUIRED" print hota hai;
# reboot khud nahi karti — wo run-phase0.sh karti hai (aik waqt mein aik node).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=inventory.sh
source "${SCRIPT_DIR}/inventory.sh"

NODE="${1:?node ka naam do: s1|s2|s3|s4}"
log()  { echo "[${NODE}] [common] $*"; }
fail() { echo "[${NODE}] [common] ERROR: $*" >&2; exit 1; }

# --- Shuruaati checks ---------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "root se chalao (sudo bash common.sh ${NODE})"
[[ -n "${NODE_IP[$NODE]:-}" ]] || fail "'${NODE}' inventory mein nahi hai"
IP="${NODE_IP[$NODE]}"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Interface ka naam confirm karo: sirf wo interface jis pe is node ka IP laga hai
mapfile -t IFACES < <(ip -o -4 addr show | awk -v ip="$IP" '{split($4,a,"/"); if (a[1]==ip) print $2}')
[[ ${#IFACES[@]} -eq 1 ]] || fail "IP ${IP} aik hi interface pe hona chahiye, mila: '${IFACES[*]:-koi nahi}'"
IFACE="${IFACES[0]}"
DEFAULT_DEV="$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)"
[[ "$DEFAULT_DEV" == "$IFACE" ]] || fail "default route ${DEFAULT_DEV} pe hai, lekin IP ${IFACE} pe — ruk raha hoon"
log "node=${NODE} ip=${IP} iface=${IFACE} role='${NODE_ROLE[$NODE]}'"

# =============================================================================
# Step 1: Hostname aur /etc/hosts
# =============================================================================
# Hostname set karo (sirf agar mukhtalif ho)
if [[ "$(hostnamectl --static)" != "$NODE" ]]; then
  hostnamectl set-hostname "$NODE"
  log "hostname -> ${NODE}"
else
  log "hostname pehle se ${NODE}"
fi

# /etc/hosts: "127.0.1.1 <hostname>" line hatao (hostname ko asal IP pe resolve hona chahiye,
# loopback pe nahi), aur lab ka block markers ke darmiyan likho taake dobara chalane pe duplicate na bane.
HOSTS_BEGIN="# BEGIN lab-infra phase0 (managed — haath se edit mat karo)"
HOSTS_END="# END lab-infra phase0"
tmp_hosts="$(mktemp)"
awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" '
  $0==b {skip=1; next}
  $0==e {skip=0; next}
  skip {next}
  $1=="127.0.1.1" {next}
  {print}
' /etc/hosts > "$tmp_hosts"
{
  echo "$HOSTS_BEGIN"
  printf '%s\n' "${HOSTS_ENTRIES[@]}"
  echo "$HOSTS_END"
} >> "$tmp_hosts"
if ! cmp -s "$tmp_hosts" /etc/hosts; then
  [[ -f /root/hosts.bak-phase0 ]] || cp -a /etc/hosts /root/hosts.bak-phase0   # pehli dafa ka backup
  install -m 0644 -o root -g root "$tmp_hosts" /etc/hosts
  log "/etc/hosts update kiya"
else
  log "/etc/hosts pehle se theek"
fi
rm -f "$tmp_hosts"

# =============================================================================
# Step 2: Static IP (netplan) — wohi IP jo DHCP se aa raha tha
# =============================================================================
NETPLAN_FILE="/etc/netplan/01-static.yaml"
DNS_YAML="$(IFS=,; echo "${DNS_SERVERS[*]}" | sed 's/,/, /g')"
DESIRED_NETPLAN="$(cat <<EOF
# lab-infra phase0 — static IP (common.sh ne likha)
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: false
      dhcp6: false
      ignore-carrier: true
      addresses:
        - ${IP}/${PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_YAML}]
EOF
)"

# cloud-init ko network config dobara likhne se roko (warna reboot pe 50-cloud-init.yaml wapas aa sakti hai)
CI_DISABLE="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
if [[ "$(cat "$CI_DISABLE" 2>/dev/null)" != "network: {config: disabled}" ]]; then
  mkdir -p /etc/cloud/cloud.cfg.d
  echo "network: {config: disabled}" > "$CI_DISABLE"
  log "cloud-init network config disable kiya"
fi

# Kya kaam baaqi hai? (file mukhtalif / koi aur yaml mojood / address abhi bhi dynamic)
other_yaml="$(find /etc/netplan -maxdepth 1 -name '*.yaml' ! -path "$NETPLAN_FILE" | wc -l)"
current="$(cat "$NETPLAN_FILE" 2>/dev/null || true)"
if [[ "$current" == "$DESIRED_NETPLAN" && "$other_yaml" -eq 0 ]] \
   && ! ip -4 addr show dev "$IFACE" | grep -q dynamic; then
  log "static IP pehle se laga hua hai"
else
  # Purani netplan files ka backup (rollback isi se hoga)
  BACKUP_DIR="/root/netplan-backup/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$BACKUP_DIR"
  cp -a /etc/netplan/*.yaml "$BACKUP_DIR"/
  chmod 700 /root/netplan-backup
  log "netplan backup: ${BACKUP_DIR}"

  # Purani files hatao aur nayi static file likho (600: netplan world-readable files pe warning deta hai)
  find /etc/netplan -maxdepth 1 -name '*.yaml' ! -path "$NETPLAN_FILE" -delete
  printf '%s\n' "$DESIRED_NETPLAN" > "$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"; chown root:root "$NETPLAN_FILE"

  # Pehle generate (sirf syntax/config check, kuch apply nahi hota). Fail ho to backup wapas.
  if ! netplan generate; then
    find /etc/netplan -maxdepth 1 -name '*.yaml' -delete
    cp -a "$BACKUP_DIR"/*.yaml /etc/netplan/
    fail "netplan generate fail hua, purani files wapas rakh di"
  fi

  # Apply: systemd-run se alag unit mein, taake SSH toot bhi jaye to apply/rollback poora ho
  install -m 0755 "${SCRIPT_DIR}/netplan-safe-apply.sh" /usr/local/sbin/netplan-safe-apply.sh
  if ! systemd-run --quiet --wait --collect --unit="netplan-safe-apply-$(date +%s)" \
        /usr/local/sbin/netplan-safe-apply.sh "$BACKUP_DIR" "$GATEWAY" 30; then
    fail "netplan safe apply fail hua (rollback ho chuka). journalctl -u 'netplan-safe-apply-*' dekho"
  fi
  log "static IP apply ho gaya"
fi

# Verify: address "dynamic" nahi hona chahiye, default route gateway pe
# (networkd ko route lagane mein 1-2 second lag sakte hain, is liye 15s tak intezar)
for _ in $(seq 1 15); do
  ip -4 route show default | grep -q "via ${GATEWAY} dev ${IFACE}" && break
  sleep 1
done
ip -4 addr show dev "$IFACE" | grep -q "inet ${IP}/${PREFIX}" || fail "${IFACE} pe ${IP}/${PREFIX} nahi mila"
! ip -4 addr show dev "$IFACE" | grep -q dynamic || fail "${IFACE} pe address abhi bhi dynamic hai"
ip -4 route show default | grep -q "via ${GATEWAY} dev ${IFACE}" || fail "default route ${GATEWAY} pe nahi"
log "verify: ${IFACE} static ${IP}/${PREFIX}, default via ${GATEWAY}"

# =============================================================================
# Step 3: Timezone UTC + chrony (time sync)
# =============================================================================
# "UTC" aur "Etc/UTC" aik hi zone hain (Etc/UTC canonical naam hai), dono ko theek mano
tz="$(timedatectl show -p Timezone --value)"
if [[ "$tz" != "UTC" && "$tz" != "Etc/UTC" ]]; then
  timedatectl set-timezone UTC
  log "timezone -> UTC"
else
  log "timezone pehle se UTC"
fi

# chrony install (ye systemd-timesyncd ko khud hata deta hai)
if ! dpkg-query -W -f='${Status}' chrony 2>/dev/null | grep -q "install ok installed"; then
  apt-get update -o DPkg::Lock::Timeout=300
  apt-get install "${APT_OPTS[@]}" chrony
  log "chrony install kiya"
fi
systemctl enable --now chrony >/dev/null 2>&1

# Verify: "System clock synchronized: yes" ka intezar (max 120s)
synced=no
for _ in $(seq 1 60); do
  if [[ "$(timedatectl show -p NTPSynchronized --value)" == "yes" ]]; then synced=yes; break; fi
  sleep 2
done
[[ "$synced" == "yes" ]] || { chronyc sources -v || true; fail "120s mein clock synchronize nahi hui"; }
log "verify: System clock synchronized: yes ($(chronyc tracking | awk -F': ' '/Reference ID/{print $2}'))"

# =============================================================================
# Step 4: OS update + base packages
# =============================================================================
apt-get update -o DPkg::Lock::Timeout=300
apt-get full-upgrade "${APT_OPTS[@]}"
apt-get install "${APT_OPTS[@]}" curl ca-certificates gnupg git jq vim bash-completion
apt-get autoremove "${APT_OPTS[@]}"
log "packages up to date"

# =============================================================================
# Step 5: Disk report (SIRF report, kuch extend nahi)
# =============================================================================
log "---- disk report ----"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
df -h /
vgs 2>/dev/null || log "koi LVM volume group nahi"

# VG mein khaali jagah
while read -r vg vfree; do
  [[ -z "$vg" ]] && continue
  if [[ "$vfree" != "0" && "$vfree" != "0B" ]]; then
    log "REPORT: VG '${vg}' mein ${vfree} khaali hai (extend NAHI kiya)"
  fi
done < <(vgs --noheadings --units g -o vg_name,vg_free 2>/dev/null | awk '{print $1, $2}')

# Disk pe partition ke bahar khaali jagah (1 GiB se zyada ho to report)
while read -r disk; do
  free_sectors="$(sfdisk -F "/dev/${disk}" 2>/dev/null | awk '/^Unpartitioned space/{print $(NF-1)}')"
  if [[ -n "$free_sectors" ]] && (( free_sectors * 512 > 1073741824 )); then
    log "REPORT: /dev/${disk} pe $(( free_sectors * 512 / 1073741824 )) GiB unpartitioned (kuch NAHI kiya)"
  fi
done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')

# =============================================================================
# Reboot chahiye? (reboot run-phase0.sh karegi)
# =============================================================================
if [[ -f /var/run/reboot-required ]]; then
  log "REBOOT_REQUIRED ($(tr '\n' ' ' < /var/run/reboot-required.pkgs 2>/dev/null))"
else
  log "reboot ki zaroorat nahi"
fi
log "DONE"
