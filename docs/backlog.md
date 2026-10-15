# Backlog: baad mein karne wale kaam

> Ye list waqt ke saath barhegi. Kaam ho jaye to `[x]` karo aur saath mein commit/doc ka hawala likho.

## Security
- [ ] **SSH hardening**: `phase0/ssh-hardening.sh --i-confirmed-key-login` chalana hai. Pehle confirm karo
      ke **Windows se har node** (s1–s4) pe key se login chal raha hai. Aik session khula rakh kar chalao.
- [ ] **etcd encryption at rest**: Secrets abhi etcd (aur snapshots) mein plain hain. `EncryptionConfiguration`
      (aescbc/kms) lagao, phir saare Secrets dobara likho.
- [ ] **Calico APIServer ka faisla**: `tigerastatus tiers` "Degraded: Waiting for Tigera API server" hai, kyunke
      APIServer install nahi kiya. Network policy ke `projectcalico.org/v3` resources (tiers, GlobalNetworkPolicy)
      chahiye hon to `APIServer` resource add karo; warna is status ko document karke chhor do.

## Kubernetes / Phase 1 ke baad
- [ ] **kubelet-serving CSR approval automate karna**: abhi `phase1/approve-kubelet-csrs.sh` haath se chalti hai
      (naye node, aur ~1 saal baad cert rotation pe dobara zaroorat). Option: `kubelet-csr-approver`
      controller (wohi checks: requester `system:node:<naam>`, SANs sirf node ka naam/IP).
- [ ] **etcd restore drill**: `docs/phase1.md` §7 wala restore asal mein chala kar dekho (VM snapshot ke
      baad, ya alag test cluster pe). Waqt note karo.
- [ ] **etcd backups node se bahar**: abhi sirf s1 ki disk pe (`/var/backups/etcd`). s4 ya NAS pe copy (encrypted).
- [ ] **`/etc/kubernetes/pki` ka backup**: CA keys etcd mein nahi; control-plane dobara banane ke liye zaroori.
      (⚠️ Kabhi git mein nahi.)
- [ ] **kubelet `systemReserved`/`kubeReserved`** aur **graceful node shutdown** (`shutdownGracePeriod`):
      OS/kubelet ke liye CPU/memory alag rakhna, aur poweroff pe pods ko saaf band hone ka waqt.
- [ ] **Certificates renewal plan**: kubeadm certs ~1 saal (Oct 2027). `kubeadm certs renew` ya upgrade se pehle reminder.

## VMware / lab
- [ ] **VM snapshots**: disk space ki kami. Space barhao ya external storage, phir har phase se pehle snapshot.
- [ ] **VMware DHCP range `.100–.253`**: taake static IPs (.11–.14) se kabhi takraav na ho.
- [ ] **pcnet32 → vmxnet3** (agar ab tak nahi hua): netplan pehle se MAC match + `set-name: ens33` pe hai
      (Phase 0 Step 12). Aik node aik waqt mein, pehle s4. Baad mein MAC check karo.
- [ ] **s2 (worker) ka CPU 2 → 4**: s1 pe 2 vCPU mein Calico startup ne node bitha diya tha. s2 abhi theek hai,
      lekin apps aane pe dekhna.
