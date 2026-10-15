# lab-infra

Mere ghar ke lab ka **Infrastructure as Code** repo. Is mein har node ko tayyar karne wali scripts
aur un ki documentation hai (Roman Urdu mein, taake revision asaan ho).

> 🔐 **`pki/lab-root-ca.crt` public hai** (har node ko trust ke liye dena hota hai). Iski **private key**
> sirf s4 pe `/root/lab-ca/ca.key` (700/600) mein hai, aur kabhi repo ya kisi aur machine pe nahi jayegi.
>
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
| **0** | Node preparation: hostname, `/etc/hosts`, static IP, UTC + chrony, OS update, swap/kernel prereqs, disk extend, sudoers, netplan MAC match | ✅ (SSH hardening baaqi: [backlog](docs/backlog.md)) |
| **1** | kubeadm workload cluster (s1 control-plane + s2 worker): containerd 2.4.2, Kubernetes v1.37.1, Calico v3.33.0, etcd backup | ✅ [docs/phase1.md](docs/phase1.md) |
| **2** | s4 pe secure container registry: Lab Root CA, TLS, htpasswd auth, Docker CE; s1/s2/s4 pe CA trust + containerd `hosts.toml` | ✅ [docs/phase2.md](docs/phase2.md) |
| **3** | s3 pe k3s management cluster (v1.36.5+k3s1) + Argo CD v3.5.5 (Helm, Traefik TLS, Lab CA cert); s1 = admin workstation (contexts `lab-workload`, `lab-mgmt`) | ✅ [docs/phase3.md](docs/phase3.md) |
| **4a** | Workload cluster Argo CD (hub) mein registered (`lab-workload`), k3s CoreDNS mein `lab.local`, private repo `platform-gitops` (read-only deploy key) | ✅ [docs/phase4.md](docs/phase4.md) |
| 4b | AppProject + Applications (GitOps se pehli apps), CI runner (s4) | ⏳ |
| 5 | Sealed Secrets (imagePullSecret waghera git se, encrypted) | ⏳ |
| 6 | Hardening: etcd encryption at rest, off-node backups ([backlog](docs/backlog.md)) | ⏳ |
| 7 | Observability (metrics-server, monitoring, logging) aur ingress/gateway | ⏳ |

> Phase 4b se aage ki list plan hai, waqt ke saath badal sakti hai. Baaqi kaam: [docs/backlog.md](docs/backlog.md).

## Repo ka structure

```
lab-infra/
├── README.md               # ye file
├── .gitignore              # secrets ko commit hone se rokta hai
├── docs/
│   ├── phase0.md           # Phase 0 ka har step: kya, kyun, production ahmiyat, verify, interview Q&A
│   ├── phase1.md           # Phase 1 (kubeadm cluster): har step + kubeadm config ke har field ka matlab
│   ├── phase2.md           # Phase 2 (registry): TLS/CA chain of trust, SAN, htpasswd vs Harbor vs ECR, imagePullSecret
│   ├── phase3.md           # Phase 3 (k3s + Argo CD): hub-and-spoke, k3s vs kubeadm, TLS at ingress, contexts
│   ├── phase4.md           # Phase 4a: pods ka DNS (CoreDNS), argocd cluster add, deploy key, lab-infra vs platform-gitops
│   └── backlog.md          # baad mein karne wale kaam (checkboxes)
├── pki/
│   └── lab-root-ca.crt     # Lab Root CA ka PUBLIC certificate (secret nahi). Private key SIRF s4:/root/lab-ca/ca.key
├── phase4/
│   ├── coredns-custom.yaml # k3s CoreDNS: lab.local zone (alag server block)
│   ├── coredns-lab-local.sh # coredns-custom apply + pod se DNS/API test                 (s1 → lab-mgmt)
│   ├── register-cluster.sh # argocd cluster add lab-workload (login prompt pe)           (s1)
│   ├── use-sa-token.sh     # Argo CD cluster Secret: admin cert → argocd-manager token  (s1 → dono)
│   ├── repo-credentials.sh # read-only deploy key + declarative repository Secret       (s1 → lab-mgmt)
│   └── verify.sh           # 9 checks (TokenReview, read-only push test samet)
├── phase3/
│   ├── versions.sh         # k3s, helm, argo-cd chart/app versions + settings
│   ├── k3s.sh              # config.yaml → k3s install (pinned) → verify                (s3)
│   ├── kubeconfig-s1.sh    # ~/.kube/config: contexts lab-workload + lab-mgmt (600)      (s1)
│   ├── argocd-cert.sh      # key+CSR s3 pe, Lab CA sign s4 pe, cert wapas s3            (s1 → s3, s4)
│   ├── argocd/values.yaml  # Argo CD Helm values (bina secrets; resources ki wajah docs mein)
│   ├── argocd-install.sh   # helm (pinned) + TLS Secret + helm upgrade --install         (s3)
│   ├── argocd-cli.sh       # argocd CLI (= server version), login, admin password        (s1)
│   └── verify.sh           # 8 tests
├── phase2/
│   ├── versions.sh         # registry image (tag+digest), Docker CE versions, CA settings
│   ├── lab-ca.sh           # Lab Root CA + registry.lab.local server cert            (s4)
│   ├── docker.sh           # Docker CE pinned + hold, gohar → docker group (= root!)  (s4)
│   ├── registry/           # compose.yaml + config.yml (BINA secrets)
│   ├── registry.sh         # passwords, htpasswd, certs, docker compose up            (s4)
│   ├── trust-ca.sh         # CA trust + Docker certs.d / containerd hosts.toml       (s4, s1, s2)
│   └── verify.sh           # 5 tests (curl 401, chain, push, k8s pull ±secret, logout)
├── phase1/
│   ├── versions.sh         # saare pinned versions + cluster settings aik jagah
│   ├── k8s-packages.sh     # kubelet/kubeadm/kubectl/cri-tools pinned + hold        (s1, s2)
│   ├── containerd.sh       # containerd.io + config.toml + crictl                    (s1, s2)
│   ├── kubeadm-config.yaml # Init/Cluster/KubeletConfiguration (koi secret nahi)
│   ├── init-control-plane.sh # validate → dry-run → kubeadm init → kubeconfig        (s1)
│   ├── calico/             # v3.33.0 manifests (pinned + SHA256SUMS) + installation.yaml
│   ├── install-calico.sh   # Tigera operator + Installation
│   ├── kubeadm-join.yaml.tmpl # JoinConfiguration TEMPLATE (token runtime pe; kabhi commit nahi)
│   ├── join-worker.sh      # s2 join (runtime token, dry-run, cleanup)
│   ├── approve-kubelet-csrs.sh # kubelet-serving CSRs (requester + SAN checks)
│   ├── etcd-backup.sh      # etcdctl/etcdutl + roz snapshot timer (7 din retention)
│   └── verify.sh           # 7 tests (phase1-test namespace, aakhir mein delete)
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

## Phase 1 kaise chalayein

Tarteeb aur commands: [docs/phase1.md → "Kaise chalayein"](docs/phase1.md#kaise-chalayein-naye-machines-pe-tarteeb-se).

```bash
kubectl get nodes -o wide          # s1 (control-plane), s2 (worker)
bash ~/lab-infra/phase1/verify.sh  # 7 tests
```
