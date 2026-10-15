# Backlog: baad mein karne wale kaam

> Ye list waqt ke saath barhegi. Kaam ho jaye to `[x]` karo aur saath mein commit/doc ka hawala likho.

## Security
- [ ] **SSH hardening**: `phase0/ssh-hardening.sh --i-confirmed-key-login` chalana hai. Pehle confirm karo
      ke **Windows se har node** (s1–s4) pe key se login chal raha hai. Aik session khula rakh kar chalao.
- [ ] **[Phase 6] etcd encryption at rest**: Secrets abhi etcd (aur snapshots) mein plain hain.
      `EncryptionConfiguration` (aescbc/kms) lagao, phir saare Secrets dobara likho.
- [ ] **Calico APIServer** *(faisla 2026-10-15: abhi NAHI)*: `tigerastatus tiers` "Degraded: Waiting for Tigera
      API server" rahega. Hum **Kubernetes NetworkPolicy** use karenge, Calico ke `projectcalico.org/v3` tiers nahi.
      Tiers/GlobalNetworkPolicy chahiye hon tab `APIServer` resource add karna.

## Kubernetes / Phase 1 ke baad
- [ ] **kubelet-serving CSR approval automate karna**: abhi `phase1/approve-kubelet-csrs.sh` haath se chalti hai
      (naye node, aur ~1 saal baad cert rotation pe dobara zaroorat). Option: `kubelet-csr-approver`
      controller (wohi checks: requester `system:node:<naam>`, SANs sirf node ka naam/IP).
- [ ] **etcd restore drill**: `docs/phase1.md` §7 wala restore asal mein chala kar dekho (VM snapshot ke
      baad, ya alag test cluster pe). Waqt note karo.
- [ ] **[Phase 6] etcd backups node se bahar**: abhi sirf s1 ki disk pe (`/var/backups/etcd`). s4 ya NAS pe copy (encrypted).
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
- [ ] **s2 (worker) ka CPU 2 → 4: apps se pehle 4 vCPU** *(faisla 2026-10-15)*. s1 pe 2 vCPU mein Calico
      startup ne node bitha diya tha. Pehli app deploy karne se pehle s2 ko 4 vCPU dena hai.

## Registry (Phase 2 ke baad)
- [ ] **Registry server cert renewal**: `registry.lab.local` cert **Oct 15, 2027** ko expire hoga. `phase2/lab-ca.sh`
      (30 din pehle khud naya banati hai) + `registry.sh` + reminder/alert. Lab Root CA: Oct 2036.
- [ ] **Lab CA private key ka backup** (offline, encrypted): s4 ki disk gayi to naye certs ke liye nayi CA + har node pe trust dobara.
- [ ] **Pull-only credentials / RBAC**: htpasswd mein `k8s-pull` bhi push kar sakta hai. Zaroorat ho to Harbor
      (robot accounts, scanning) pe jana.
- [ ] **Cached images ke liye auth**: `AlwaysPullImages` admission ya kubelet ka "ensure secret pulled images"
      feature dekhna (multi-tenant ho to zaroori).
- [ ] **Registry data backup** (`/srv/registry/data`) aur GC ka schedule (registry read-only window mein).
- [ ] **Docker group**: `gohar` docker group mein hai (= root). CI runner ke liye alag user / rootless builder (Phase 4).

## PKI / certificates (Phase 3 ke baad)
- [ ] **Root CA offline + intermediate CA**: abhi Lab Root CA ki key s4 pe "online" hai aur har cert seedha root
      se sign hota hai. Behtar: root key offline (encrypted, VM se bahar), aik **intermediate CA** roz ke signing ke
      liye (cert-manager/s4). Intermediate leak ho to sirf usay revoke/badlo, root nahi.
- [ ] **CA key ka offline backup** (encrypted; `/root/lab-ca/ca.key`): s4 ki disk gayi to nayi CA + har node pe trust dobara.
- [ ] **Registry cert renewal (Oct 15, 2027)**: `phase2/lab-ca.sh` + `registry.sh` (30 din pehle khud naya).
- [ ] **argocd.lab.local cert renewal (Oct 15, 2027)**: `phase3/argocd-cert.sh` + `argocd-install.sh`
      (Secret update). Behtar: **cert-manager** (Lab CA → ClusterIssuer) jo renewal khud kare.

## Argo CD
- [ ] **[Phase 6] Argo CD SSO + RBAC**: abhi sirf local `admin` (password s1 `/root/argocd-admin-password`). OIDC (Dex/
      Keycloak) + `argocd-rbac-cm` (read-only default, admin sirf group ko), phir local admin **disable**.
- [ ] **Argo CD resources review**: workload cluster (Phase 4) register aur apps aane ke baad `kubectl top` se
      application-controller / repo-server ki requests/limits dobara set karna.
- [ ] **Management cluster backup**: k3s datastore (`k3s etcd-snapshot` ya sqlite backup) + Argo CD config
      (`argocd admin export`). Hub gaya to sab spokes ka control gaya.

## GitOps (Phase 4a ke baad)
- [ ] **Argo CD ki workload credential: admin cert → argocd-manager token** *(faisla 2026-10-15: abhi jaisa hai)*.
      `argocd cluster add` (v3.5.5) ne cluster Secret mein s1 kubeconfig ka `kubernetes-admin` client cert/key rakha
      (revoke nahi ho sakta, Oct 14, 2027 tak valid; audit mein insaan aur Argo CD ka farq nahi). Badalna: cluster
      Secret `config` = argocd-manager-long-lived-token ka `bearerToken` + `caData` (stdin se, declarative), cert/key
      hatao, `argocd cluster get` Successful. Phir admin cert ki rotation (`kubeadm certs renew admin.conf`) bhi socho.
- [ ] **argocd-manager ki permissions scoped karna**: abhi workload cluster mein `argocd-manager-role` = `*/*/*`
      (cluster-admin). Options: `argocd cluster add --namespace ...` (sirf chund namespaces), ya apna ServiceAccount +
      custom ClusterRole (`--service-account`), aur AppProject mein `clusterResourceWhitelist`. Long-lived token ki
      rotation bhi.
- [ ] **Deploy key rotation** (platform-gitops): nayi ED25519 key → GitHub pe read-only add → `repo-credentials.sh`
      (Secret update) → `argocd repo list` Successful → `verify.sh` (read-only push test) → purani key GitHub se delete.
      Backup: s1 `/root/argocd-repo-key/`.
- [ ] **Real internal DNS**: abhi `lab.local` teen jagah haath se hai (har node ki `/etc/hosts`, k3s `coredns-custom`).
      Aik internal DNS server (misal CoreDNS/PowerDNS/BIND on s4, ya router) + VMware DHCP/netplan DNS us pe, aur k3s/
      kubeadm CoreDNS mein `forward lab.local <dns>`.

