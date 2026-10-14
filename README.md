# lab-infra

Mere ghar ke lab ka **Infrastructure as Code** repo. Is mein har node ko tayyar karne wali scripts
aur un ki documentation hai (Roman Urdu mein, taake revision asaan ho).

> ⚠️ **Ye repo PUBLIC hai.** Is mein kabhi koi password, private key, token, kubeconfig ya
> certificate ki private key commit nahi karni. `.gitignore` in cheezon ko rokta hai, lekin har
> commit se pehle `git diff --cached` khud zaroor dekho.

## Lab ka naqsha

4 VMware VMs, sab **Ubuntu 24.04 LTS**, user `gohar`. Network VMware NAT hai: `192.168.2.0/24`,
gateway aur DNS dono `192.168.2.2`.

| Node | IP             | Hostname aliases       | Role                                         |
|------|----------------|------------------------|----------------------------------------------|
| s1   | 192.168.2.11   | `k8s-api.lab.local`    | Workload Kubernetes **control-plane** (kubeadm) |
| s2   | 192.168.2.12   | –                      | Workload Kubernetes **worker** (kubeadm)     |
| s3   | 192.168.2.13   | `argocd.lab.local`     | **Management cluster** (k3s + Argo CD)       |
| s4   | 192.168.2.14   | `registry.lab.local`   | **CI runner + container registry**           |

```
                    VMware NAT  (gateway + DNS 192.168.2.2)
                                 |
     +-------------+-------------+-------------+-------------+
     |             |                           |             |
  s1 .11        s2 .12                      s3 .13        s4 .14
  k8s CP        k8s worker                  k3s +         CI runner +
  (kubeadm)     (kubeadm)                   Argo CD       registry
  \_____ workload cluster _____/            (mgmt)
```

- Saari scripts **s1** se chalti hain; s1 se baaqi nodes pe key-based SSH hai.
- Har node ka IP **static** hai (wohi jo pehle DHCP deta tha).

## Phases

| Phase | Kaam | Status |
|-------|------|--------|
| **0** | Node preparation: hostname, `/etc/hosts`, static IP, UTC + chrony, OS update, swap/kernel prereqs, (SSH hardening alag) | ✅ (SSH hardening baaqi — Windows key login confirm hone ke baad) |
| 1 | Container runtime (containerd) + kubeadm se workload cluster (s1 + s2) | ⏳ |
| 2 | CNI (pod network) + basic cluster checks | ⏳ |
| 3 | s3 pe k3s management cluster + Argo CD | ⏳ |
| 4 | s4 pe container registry + CI runner | ⏳ |
| 5 | GitOps: Argo CD se workload cluster pe apps deploy | ⏳ |

> Phase 1 se aage ki list plan hai — waqt ke saath badal sakti hai.

## Repo ka structure

```
lab-infra/
├── README.md               # ye file
├── .gitignore              # secrets ko commit hone se rokta hai
├── docs/
│   └── phase0.md           # Phase 0 ka har step: kya, kyun, production ahmiyat, verify, interview Q&A
└── phase0/
    ├── inventory.sh        # nodes, IPs, gateway, DNS — aik jagah
    ├── 00-sudo-nopasswd.sh # gohar ko passwordless sudo (aik dafa, interactive)
    ├── common.sh           # har node: hostname, hosts, static IP, UTC/chrony, apt, disk report
    ├── netplan-safe-apply.sh # netplan apply + 30s mein gateway na mile to rollback
    ├── k8s-prereqs.sh      # s1/s2: swap off + modules + sysctl;  s3: --swap-only
    ├── disk-extend.sh      # s1/s3: VG ki khaali jagah root LV mein (lvextend -r, online)
    ├── sudoers-cleanup.sh  # sudoers.d: 0440 root:root + purani files retire (visudo -c ke saath)
    ├── ssh-hardening.sh    # password/root SSH login band (confirmation ke BAAD hi)
    ├── run-phase0.sh       # s1 se sab nodes pe chalata hai (s4 → s3 → s2 → s1)
    └── verify.sh           # report (kuch badalta nahi)
```

## Phase 0 kaise chalayein

```bash
cd ~/lab-infra/phase0
./run-phase0.sh            # sab nodes: s4, s3, s2, s1 (aik waqt mein aik)
./run-phase0.sh s2         # sirf aik node
ssh gohar@192.168.2.14 'sudo bash /tmp/lab-infra-phase0/common.sh s4 network'   # sirf aik step (scripts copy hone ke baad)
for ip in 192.168.2.1{1..4}; do ssh gohar@$ip 'bash -s' < verify.sh; done   # report
```

Tafseel: [docs/phase0.md](docs/phase0.md)
