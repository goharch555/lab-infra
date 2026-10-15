#!/usr/bin/env bash
# etcd-backup.sh — s1 pe etcdctl/etcdutl (chalte etcd ke version wale) + roz ka snapshot (systemd timer).
#
# Istemaal (s1 pe, root se):  sudo bash etcd-backup.sh
# Kya banta hai:
#   /usr/local/bin/etcdctl, etcdutl            — etcd release se (sha256 verify)
#   /usr/local/sbin/etcd-snapshot.sh           — aik snapshot + status check + 7 din purane delete
#   etcd-snapshot.service / etcd-snapshot.timer — roz 02:00 UTC (Persistent: machine band thi to boot pe)
#   /var/backups/etcd/                          — snapshots (700 root; in mein Secrets bhi hote hain!)
# Idempotent hai. Aakhir mein aik snapshot bana kar "etcdutl snapshot status" se verify karti hai.
set -euo pipefail

log()  { echo "[$(hostname)] [etcd-backup] $*"; }
fail() { echo "[$(hostname)] [etcd-backup] ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail "root se chalao"
MANIFEST="/etc/kubernetes/manifests/etcd.yaml"
[[ -f "$MANIFEST" ]] || fail "${MANIFEST} nahi — ye control-plane node nahi"

# --- Step 1: etcd ka version chalte static pod ki image se (3.7.0-0 -> 3.7.0) ----------------
ETCD_VERSION="$(grep -oP 'image:\s*\S+/etcd:\K[0-9]+\.[0-9]+\.[0-9]+' "$MANIFEST" | head -1)"
[[ -n "$ETCD_VERSION" ]] || fail "etcd version manifest se nahi mila"
log "chalta etcd: v${ETCD_VERSION}"

# --- Step 2: etcdctl + etcdutl install (sirf agar version mukhtalif ho) ------------------------
have="$(etcdutl version 2>/dev/null | awk '/etcdutl version/{print $3}' || true)"
if [[ "$have" != "$ETCD_VERSION" || "$(etcdctl version 2>/dev/null | awk '/etcdctl version/{print $3}')" != "$ETCD_VERSION" ]]; then
  base="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}"
  tarball="etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  curl -fsSL -o "${work}/${tarball}" "${base}/${tarball}"
  curl -fsSL -o "${work}/SHA256SUMS" "${base}/SHA256SUMS"
  ( cd "$work" && grep " ${tarball}\$" SHA256SUMS | sha256sum -c --quiet ) || fail "etcd tarball ka sha256 match nahi"
  tar -xzf "${work}/${tarball}" -C "$work" --strip-components=1 "etcd-v${ETCD_VERSION}-linux-amd64/etcdctl" "etcd-v${ETCD_VERSION}-linux-amd64/etcdutl"
  install -m 0755 "${work}/etcdctl" "${work}/etcdutl" /usr/local/bin/
  log "etcdctl + etcdutl v${ETCD_VERSION} install kiye (sha256 OK)"
else
  log "etcdctl/etcdutl pehle se v${ETCD_VERSION}"
fi

# --- Step 3: snapshot script ----------------------------------------------------------------
SNAP="/usr/local/sbin/etcd-snapshot.sh"
tmp="$(mktemp)"
cat > "$tmp" <<'SNAPEOF'
#!/usr/bin/env bash
# etcd-snapshot.sh — etcd ka aik snapshot lo, verify karo, 7 din se purane delete karo.
# (lab-infra/phase1/etcd-backup.sh ne install kiya; haath se edit mat karo)
set -euo pipefail
DIR="/var/backups/etcd"
KEEP_MINUTES=$((7 * 24 * 60))          # 7 din
PKI="/etc/kubernetes/pki/etcd"
install -d -m 0700 -o root -g root "$DIR"
out="${DIR}/etcd-snapshot-$(date -u +%Y%m%dT%H%M%SZ).db"

# (etcdctl v3.4+ mein API v3 default hai; ETCDCTL_API=3 ki zaroorat nahi — v3.7 isay "unrecognized" kehta hai)
# Snapshot pehle .part naam se; status check pass ho to hi asal naam (aadha snapshot kabhi "backup" na lage)
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert="${PKI}/ca.crt" --cert="${PKI}/healthcheck-client.crt" --key="${PKI}/healthcheck-client.key" \
  snapshot save "${out}.part"
etcdutl snapshot status "${out}.part" -w table
chmod 0600 "${out}.part"
mv "${out}.part" "$out"
echo "snapshot: ${out} ($(du -h "$out" | cut -f1))"

# Retention: 7 din se purane snapshots delete (aur koi bacha hua .part bhi)
find "$DIR" -maxdepth 1 -type f \( -name 'etcd-snapshot-*.db' -o -name 'etcd-snapshot-*.db.part' \) \
  -mmin +"$KEEP_MINUTES" -print -delete
SNAPEOF
if ! cmp -s "$tmp" "$SNAP"; then install -m 0700 -o root -g root "$tmp" "$SNAP"; log "${SNAP} likha"; fi
rm -f "$tmp"

# --- Step 4: systemd service + timer ---------------------------------------------------------
write_unit() {  # $1=path, $2=content — sirf farq ho to likho
  if [[ "$(cat "$1" 2>/dev/null)" != "$2" ]]; then printf '%s\n' "$2" > "$1"; log "$1 likha"; units_changed=yes; fi
}
units_changed=no
write_unit /etc/systemd/system/etcd-snapshot.service "[Unit]
Description=etcd snapshot backup (lab-infra phase1)
After=kubelet.service

[Service]
Type=oneshot
ExecStart=${SNAP}
Nice=10
IOSchedulingClass=idle"
write_unit /etc/systemd/system/etcd-snapshot.timer "[Unit]
Description=Roz etcd snapshot (lab-infra phase1)

[Timer]
OnCalendar=*-*-* 02:00:00 UTC
RandomizedDelaySec=10m
Persistent=true

[Install]
WantedBy=timers.target"
[[ "$units_changed" == "yes" ]] && systemctl daemon-reload
systemctl enable --now etcd-snapshot.timer >/dev/null 2>&1

# --- Step 5: abhi aik snapshot + verify ----------------------------------------------------------
systemctl start etcd-snapshot.service    # oneshot: khatam hone tak rukta hai; fail ho to non-zero
latest="$(ls -1t /var/backups/etcd/etcd-snapshot-*.db | head -1)"
[[ -s "$latest" ]] || fail "snapshot file nahi bani"
etcdutl snapshot status "$latest" -w table
systemctl is-enabled --quiet etcd-snapshot.timer || fail "timer enabled nahi"
log "verify: snapshot ${latest}; timer next: $(systemctl show etcd-snapshot.timer -p NextElapseUSecRealtime --value)"
log "DONE"
