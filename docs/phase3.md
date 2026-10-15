# Phase 3: s3 pe management cluster (k3s) + Argo CD

Is phase mein **s3** pe aik chhota Kubernetes cluster (**k3s**) banaya gaya, jis ka kaam apps chalana
nahi balki **doosre clusters ko manage karna** hai. Us pe **Argo CD** lagaya gaya. s1 ab dono clusters
ke liye admin workstation hai. Workload cluster (s1/s2) mein **koi tabdeeli nahi** hui, aur Argo CD mein
use **abhi register nahi** kiya (Phase 4). s4 pe sirf certificate sign hua.

| Cheez | Version / value |
|---|---|
| k3s | **v1.36.5+k3s1** (k3s ka *stable* channel; latest v1.37.1+k3s1 abhi stable channel mein nahi tha) |
| Helm (s3) | v4.3.0 (sha256 pinned; v4.3.1 sirf 1 din purana tha) |
| Argo CD chart | **argo/argo-cd 10.10.5** |
| Argo CD | **v3.5.5** (server = CLI) |
| URL | `https://argocd.lab.local` → 192.168.2.13:443 (Traefik) |
| Cluster CIDRs (k3s default) | pods `10.42.0.0/16`, services `10.43.0.0/16` |

**Scripts** (`phase3/`, sab idempotent, versions `phase3/versions.sh` mein):

| # | Script | Kahan | Kaam |
|---|---|---|---|
| 1 | `k3s.sh` | s3 (root) | config.yaml → k3s install (pinned) → verify |
| 2 | `kubeconfig-s1.sh` | s1 (gohar) | contexts `lab-workload` + `lab-mgmt` merge (600) |
| 3 | `argocd-cert.sh` | s1 (gohar) → s3, s4 | key+CSR s3 pe, sign s4 pe, cert wapas s3 |
| 4 | `argocd-install.sh <ca.crt>` | s3 (root) | helm, TLS Secret, `helm upgrade --install` |
| 5 | `argocd-cli.sh` | s1 (gohar) | CLI (same version), login, admin password badalna |
| 6 | `verify.sh` | s1 (gohar) | 8 tests |

### ⚠️ Secrets (KABHI repo mein nahi)
| Secret | Jagah |
|---|---|
| k3s join token | s3: `/var/lib/rancher/k3s/server/token` (600) |
| k3s admin kubeconfig | s3: `/etc/rancher/k3s/k3s.yaml` (600); s1: `~/.kube/config` (600) mein `lab-mgmt` |
| argocd.lab.local TLS key | s3: `/root/argocd-tls/` (700/600) + k3s Secret `argocd/argocd-server-tls` (encrypted at rest) |
| Argo CD admin password | s1: `/root/argocd-admin-password` (600 root). Docs/report mein nahi |
| argocd CLI session token | s1: `~/.config/argocd/config` |

---

## 0. Management cluster aur hub-and-spoke

```
                        ┌──────────────── s1 (admin workstation) ───────────────┐
                        │ kubectl contexts: lab-workload, lab-mgmt │ argocd CLI │
                        └────────────────────────┬──────────────────────────────┘
                                                 │
            ┌────────────────────────────────────┴───────────────────┐
            ▼                                                        ▼
  HUB: lab-mgmt (k3s, s3)                                 SPOKE: lab-workload (kubeadm, s1+s2)
  ┌───────────────────────┐   Phase 4: deploy karega      ┌──────────────────────────┐
  │ Argo CD               │ ─────────────────────────────►│ apps                     │
  │ (git → desired state) │                               │                          │
  └───────────────────────┘                               └──────────────────────────┘
        ▲ git (lab-infra / app repos)
```

- **Workload cluster:** jahan asal apps chalti hain.
- **Management cluster (hub):** jahan "platform tools" chalte hain: Argo CD (GitOps), aage chal ke
  monitoring/policy waghera. Ye apps nahi chalata, doosre clusters (**spokes**) ko manage karta hai.
- **Kyun alag cluster?**
  1. **Blast radius:** workload cluster kharab ho jaye (upgrade, ghalat deploy, resources khatam) to bhi
     Argo CD chal raha hota hai, aur usi se wapas theek kiya ja sakta hai. Jo tool cluster ko theek karta
     hai, wo usi cluster pe nahi hona chahiye jise woh theek kar raha hai.
  2. **Aik hub, kai spokes:** kal ko `staging` ya `prod-2` cluster aaye to sirf usay hub mein register
     karna hoga. Har cluster pe alag Argo CD nahi lagana padega.
  3. **Credentials aik jagah:** spokes ki access hub pe hoti hai, developers ke laptops pe nahi.
- **Nuqsaan:** hub khud aik "single point of control" hai. Is liye usay chhota, mehfooz aur backed-up
  rakhna zaroori hai. Is ka HA aur backup hamare backlog mein hai.

**Interview sawal:** *Hub-and-spoke GitOps model kya hai, aur Argo CD ko workload cluster se alag kyun rakhte hain?*
**Jawab:** Aik central (hub) Argo CD kai target (spoke) clusters ko git se sync karta hai. Alag rakhne se
blast radius kam hota hai: workload cluster gire to deployment tool zinda rehta hai aur recovery ho
sakti hai. Saare clusters aik jagah se manage hote hain aur credentials bhi aik jagah rehte hain.

---

## 1. `k3s.sh`: k3s (s3)

### k3s vs kubeadm
| | **kubeadm** (workload, Phase 1) | **k3s** (management) |
|---|---|---|
| Kya hai | Kubernetes ke components ko jorne ka *tool* | Kubernetes ki aik mukammal *distribution*, **aik binary** |
| Setup | runtime, CNI, etcd backup, CSR... sab khud | Sab andar: containerd, Flannel (CNI), CoreDNS, Traefik, ServiceLB, local-path storage, metrics-server |
| Datastore | etcd (static pod) | Single node: **SQLite** (kine). HA mein embedded etcd |
| Resource | Zyada (alag processes) | Kam (~500 MB control-plane) |
| Control | Har cheez configure ho sakti hai | Opinionated defaults (bohat kuch flags/config se band ho sakta hai) |
| Kahan | Production, jahan har hissa control karna ho | Edge, lab, chhote/management clusters |

Hum ne dono rakhe: kubeadm seekhne ke liye (har hissa haath se), aur k3s jahan "bas chalna chahiye".

**Kya kiya:**
1. Install se **pehle** `/etc/rancher/k3s/config.yaml` (600). k3s pehli start pe hi in settings se chalta hai:
   ```yaml
   node-ip: 192.168.2.13           # node ka IP (Flannel bhi isi interface pe)
   tls-san: [s3, 192.168.2.13]     # API server cert mein ye naam/IP bhi (s1 se https://192.168.2.13:6443)
   write-kubeconfig-mode: "0600"   # /etc/rancher/k3s/k3s.yaml (cluster-admin!) sirf root parh sake — wazeh likha
   secrets-encryption: true        # Secrets etcd/sqlite mein AES-CBC encrypted
   ```
2. Install script k3s ke **usi version ke git tag** se download ki
   (`raw.githubusercontent.com/k3s-io/k3s/v1.36.5+k3s1/install.sh`), sirf temp file mein (repo mein nahi),
   aur `INSTALL_K3S_VERSION=v1.36.5+k3s1` ke saath chalayi. Installer k3s binary ka sha256 khud verify karta hai.
3. Idempotent: version same ho to install nahi hota. Config badli ho to sirf `systemctl restart k3s`.
4. Verify: node Ready, kube-system deployments available (15 min tak intezar, kyunke Traefik ka
   deployment helm-install job ke baad banta hai aur images pehli dafa download hoti hain), aur
   secrets encryption Enabled.

**CIDRs:** k3s defaults (`10.42.0.0/16` pods, `10.43.0.0/16` services) workload cluster
(`10.244/16`, `10.96/12`) aur LAN (`192.168.2.0/24`) se overlap nahi karte. Phase 4 mein jab Argo CD
(s3) workload cluster ke API (`192.168.2.11:6443`) se baat karega to routing saaf rahegi.

### Traefik aur ServiceLB (klipper) kaise kaam karte hain
- **Ingress controller (Traefik):** cluster mein aik reverse proxy, jo `Ingress` objects parh kar
  `Host: argocd.lab.local` jaisi requests sahi Service tak bhejta hai. TLS bhi yahin khatam ho sakta hai.
- Traefik khud aik `Service type: LoadBalancer` hai. Cloud mein LoadBalancer ke liye cloud ka LB aata hai,
  lekin bare-metal/lab mein koi nahi hota. Aam tor pe service hamesha `<pending>` reh jati hai.
- **ServiceLB (klipper-lb)** k3s ka chhota hal hai: har LoadBalancer Service ke liye har node pe aik
  DaemonSet pod (`svclb-traefik-*`) chalata hai, jo **hostPort** (iptables DNAT) se node ke port 80/443
  ko Service tak forward karta hai. Service ko EXTERNAL-IP = node ka IP (`192.168.2.13`) mil jata hai.
  - Isi liye `ss -ltn` mein 80/443 pe koi process "listen" nahi karta. Kaam iptables rules karte hain.
  - Production bare-metal mein iski jagah **MetalLB** (alag IP pool, L2/BGP) ya hardware LB hota hai.
- Request ka raasta:
  `s1 → 192.168.2.13:443 → (iptables, svclb) → Traefik pod (TLS khatam) → Service argocd-server:80 → argocd-server pod`

**Verify:**
```bash
kubectl --context lab-mgmt get nodes -o wide
kubectl --context lab-mgmt -n kube-system get svc traefik      # EXTERNAL-IP 192.168.2.13
ssh gohar@192.168.2.13 'sudo k3s secrets-encrypt status'
```

### k3s secrets-encryption
- Default mein Kubernetes Secrets datastore (etcd/sqlite) mein sirf **base64**, yani plain hote hain. Jis
  ke paas datastore ya uska backup ho, wo saare passwords/keys parh sakta hai.
- `secrets-encryption: true` se k3s aik **EncryptionConfiguration** (AES-CBC key) banata hai. API server
  Secrets ko datastore mein likhne se pehle encrypt karta hai aur parhte waqt decrypt. `kubectl get secret`
  pe farq nazar nahi aata (RBAC wale ko plain milta hai), lekin **disk/backup pe encrypted** hota hai.
- Hamara status: `Encryption Status: Enabled`, key `aescbckey`, "All hashes match".
- **Hadd:** encryption key bhi isi node pe hai (`/var/lib/rancher/k3s/server/cred/encryption-config.json`).
  Disk churane wale ke paas key bhi hogi. Asal hifazat ke liye **KMS** (key bahar) chahiye. Rotation:
  `k3s secrets-encrypt rotate-keys`.
- Workload cluster (kubeadm) mein ye abhi **nahi** hai, aur [backlog](backlog.md) mein Phase 6 ka hissa hai.

**Interview sawal 1:** *k3s aur kubeadm mein kya fark hai? Kab kaunsa?*
**Jawab:** kubeadm sirf cluster bootstrap karta hai; runtime, CNI, ingress, storage sab khud chunne
padte hain. Ye production mein poore control ke liye hai. k3s aik binary mein poori distribution hai
(containerd, flannel, traefik, servicelb, local-path, sqlite/etcd), kam resources leti hai, aur edge,
lab ya management clusters ke liye achhi hai jahan opinionated defaults theek hon.

**Interview sawal 2:** *Kubernetes Secrets "encrypted" hote hain?*
**Jawab:** By default nahi. etcd mein sirf base64 hote hain. Encryption at rest ke liye API server ko
`EncryptionConfiguration` dena padta hai (aescbc/aesgcm/secretbox, ya behtar KMS provider). Phir bhi
RBAC se `get secrets` wala user plain value dekh sakta hai. Encryption at rest sirf datastore aur
backups ki hifazat karta hai.

---

## 2. `kubeconfig-s1.sh`: kubectl contexts (s1 = admin workstation)

**Kya kiya:**
1. Purana context `kubernetes-admin@lab-workload` → **`lab-workload`** (rename).
2. s3 ki `/etc/rancher/k3s/k3s.yaml` ssh pipe se seedha 600 temp file mein aayi (kahin print nahi).
   Python (yaml parse) se naam `default` → `lab-mgmt` (cluster), `lab-mgmt-admin` (user), `lab-mgmt`
   (context), aur server `https://127.0.0.1:6443` → **`https://192.168.2.13:6443`**.
3. `KUBECONFIG=new:old kubectl config view --flatten` se merge. Current context **`lab-workload`**.
   File 600, aur purani file ka backup `~/.kube/config.bak-*` (600) mein.
4. **Phase 1 script ki hifazat:** `phase1/init-control-plane.sh` pehle `admin.conf` ko `~/.kube/config`
   pe overwrite kar deti thi, jis se `lab-mgmt` mit jata. Ab wo file mojood ho to nahi chhedti.

### kubectl contexts kya hain
- Kubeconfig mein teen list hoti hain:
  - **clusters**: API server ka URL + us cluster ka CA (TLS verify ke liye)
  - **users**: credentials (client cert/key, token...)
  - **contexts**: (cluster + user + default namespace) ka naam wala jora
- `current-context` wo hai jo `kubectl` default mein use karta hai. `--context lab-mgmt` aik command ke
  liye badal deta hai, aur `kubectl config use-context` hamesha ke liye.
- **Khatra:** ghalat context pe `kubectl delete` ka matlab ghalat cluster ka nuqsaan. Is liye naam
  saaf rakhe (`lab-workload` / `lab-mgmt`), scripts mein hamesha `--context` wazeh likhte hain, aur
  prompt mein current context dikhana (kube-ps1) achhi aadat hai.
- **TLS:** `lab-mgmt` k3s ke apne CA (kubeconfig ke andar) se verify hota hai. Is ke liye API cert mein
  `192.168.2.13` hona zaroori tha, jo `tls-san` ne daala.

**Verify:**
```bash
kubectl config get-contexts
kubectl --context lab-workload get nodes
kubectl --context lab-mgmt get nodes
stat -c '%a' ~/.kube/config      # 600
```

**Interview sawal:** *Do clusters ke kubeconfig kaise merge karoge, aur ghalat cluster pe command chalne se kaise bachoge?*
**Jawab:** `KUBECONFIG=a:b kubectl config view --flatten > merged` se merge karo, naam takrayen to pehle
rename karo. Bachao ke liye wazeh context naam rakho, automation mein hamesha `--context` do, prompt mein
current context dikhao, aur production ke liye alag (kam-ikhtiyar) credentials rakho.

---

## 3. `argocd-cert.sh`: CSR sign karna, key machine se bahar na jana

```
        s3                              s1 (orchestrator)                    s4
  ┌──────────────┐                                                   ┌───────────────┐
  │ private key  │  CSR (public) ──────────► check ──────────────────►│ Lab Root CA   │
  │ (sirf yahan) │                                                    │ ca.key (yahan)│
  │              │◄────────── certificate (public) ◄── check ◄────────│ sign + SAN    │
  └──────────────┘                                                    └───────────────┘
```

**Kya kiya:**
1. **s3:** nayi ECDSA P-256 key `/root/argocd-tls/argocd.lab.local.key.new` (700 folder, 600 file) aur
   CSR (`CN=argocd.lab.local`). Network pe sirf **CSR** aaya.
2. **s1:** CSR ka self-signature aur subject check kiya.
3. **s4:** Lab Root CA se sign kiya. **Extensions s4 tay karta hai** (CSR mein jo maanga ho us pe bharosa
   nahi): `CA:FALSE`, `digitalSignature`, `serverAuth`, SAN `DNS:argocd.lab.local, IP:192.168.2.13`,
   365 din. Sirf **certificate** wapas aaya.
4. **s1:** certificate ko repo wali `pki/lab-root-ca.crt` se `openssl verify` kiya, SAN/EKU/expiry check
   kiye, aur cert ki public key ko s3 ki key ki **public half** se milaya (private key nahi aati). Sab
   theek ho tabhi s3 pe `.new` → asal naam.
5. Idempotent: cert valid ho, key se match kare, aur 30+ din bache hon to kuch nahi hota.

**Key machine se bahar kyun na jaye:** private key ki har copy aik naya khatra hai (scp ke beech, s1 ki
disk, backup, shell history). CSR aur certificate **public** hain; inke leak se kuch nahi bigarta. Isi
usool pe asal PKI chalti hai: Let's Encrypt/ACME, cert-manager, aur HSM (jahan key kabhi chip se bahar
nahi aati). CA key bhi isi tarah sirf s4 pe hai.

**Interview sawal:** *CSR kya hota hai aur us mein kya hota hai?*
**Jawab:** Certificate Signing Request: requester ki **public key** + maanga hua subject (aur
extensions), requester ki private key se sign kiya hua (taake pata chale key us ke paas hai). CA isay
verify karke apne dastakhat se certificate banata hai. Private key kabhi CA ke paas nahi jati. Achhi
CA requested extensions pe andha bharosa nahi karti; SAN/usage policy ke mutabiq khud tay karti hai.

---

## 4. `argocd-install.sh` + `argocd/values.yaml`: Argo CD (Helm)

**Kya kiya (s3 pe, root):**
1. `helm` v4.3.0: tarball ka sha256 pinned value se verify, phir `/usr/local/bin/helm`.
2. Namespace `argocd`, aur Secret **`argocd-server-tls`** (type `kubernetes.io/tls`) s3 ki key/cert se
   `kubectl create secret tls --dry-run=client -o yaml | kubectl apply`. Is tarah cert renew hone pe bhi
   update ho jata hai. Key s3 se bahar nahi gayi.
3. `helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm --version 10.10.5 -f values.yaml --wait`.
   Release sirf tab upgrade hoti hai jab chart version ya values badlen; dobara chalane pe nayi revision nahi banti.
4. Saare deployments/statefulsets ka rollout, phir `https://argocd.lab.local` (Lab CA se) → 200, aur
   `http://` (port 80) pe Argo CD **nahi** (404).

**⚠️ TLS Secret abhi BOOTSTRAP hai:** ye haath se (script se) bana hai, aur cert ki renewal ke liye
`argocd-cert.sh` + `argocd-install.sh` dobara chalani hongi. Baad mein **cert-manager** (Lab CA ko
`ClusterIssuer` bana kar) ye kaam khud karega: Certificate object → Secret → automatic renewal.

### TLS termination at ingress aur `server.insecure`
- **TLS kahan khatam ho?** Teen tareeqe:
  1. **Edge termination (hamara):** Traefik TLS khatam karta hai (cert Traefik ke paas), aur andar
     Traefik → argocd-server **HTTP** pe jata hai. Is liye `server.insecure: true`: argocd-server khud TLS
     nahi karta, warna Traefik ko "HTTP bhejo to HTTPS jawab" milta (redirect loop / 400).
  2. **Re-encrypt:** Traefik TLS khatam kare, phir argocd-server tak naya TLS. Andar bhi encryption,
     lekin do certificates manage karne padte hain.
  3. **Passthrough:** Traefik TLS kholta hi nahi (SNI dekh kar TCP aage bhej deta hai), aur argocd-server
     khud TLS karta hai.
- **Edge termination ka matlab** hai ke cluster ke andar (Traefik pod → argocd-server pod) traffic plain
  HTTP hai. Single-node lab mein ye traffic node se bahar nahi jata. Multi-node/zero-trust production mein
  service mesh (mTLS) ya re-encrypt use hota hai.
- **Sirf HTTPS entrypoint:** Ingress pe annotation
  `traefik.ingress.kubernetes.io/router.entrypoints: websecure` hai. Iske baghair Traefik isi Ingress ko
  **port 80** pe bhi serve karta, aur admin password plain HTTP pe ja sakta tha. Test: `http://argocd.lab.local` → 404.

### `--grpc-web` kyun
- argocd CLI server se **gRPC** pe baat karta hai, jo HTTP/2 pe chalta hai aur kuch khaas cheezein
  (trailers, end-to-end HTTP/2) maangta hai. Beech mein proxy/ingress (Traefik) ho to aksar ye toot jata
  hai, kyunke proxy HTTP/1.1 pe downgrade kar deta hai, trailers gira deta hai, ya backend ke saath
  HTTP/2 (h2c) nahi bolta.
- **gRPC-Web** gRPC messages ko aam HTTP/1.1 ya HTTP/2 requests mein lapet deta hai, jo har proxy se guzar
  jati hain. Isi liye har argocd CLI command `--grpc-web` ke saath hai. (Ye `--insecure` nahi hai: TLS
  verify poori tarah on hai.)

### Resources (kyun ye values) — Phase 1 ka sabaq
Phase 1 mein dekha tha ke **scheduler sirf requests dekhta hai, asal usage nahi**. Calico ke pods ki
requests nahi thin, is liye 2 vCPU node bhar gaya aur kisi ko pata nahi chala. Is liye Argo CD ke **har**
component ki requests aur memory limit di gayi:

| Component | CPU req | Mem req | Mem limit | Wajah |
|---|---|---|---|---|
| application-controller | 250m | 512Mi | 1Gi | Sab se bhari: har cluster ki state ka cache aur har app ka diff; apps barhne se barhta hai |
| repo-server | 100m | 256Mi | 512Mi | git clone + helm/kustomize render; bursty, memory zyada (bari charts) |
| server (API/UI) | 50m | 128Mi | 256Mi | Halka; UI/CLI requests |
| applicationset-controller | 50m | 64Mi | 128Mi | Abhi koi ApplicationSet nahi |
| redis | 50m | 64Mi | 128Mi | Sirf cache (data persistent nahi) |
| notifications-controller | 25m | 64Mi | 128Mi | Abhi koi trigger nahi |
| **Argo CD kul** | **525m** | **1088Mi** | **~2.1Gi** | |

- **CPU limit jaan-boojh kar nahi:** CPU "compressible" hai. Limit lagane se container **throttle** hota
  hai (latency spikes), chahe node pe CPU khaali ho. Requests se hi har pod ko bhari load mein uska hissa
  mil jata hai.
- **Memory limit zaroori:** memory "incompressible" hai. Agar kisi component mein leak ho to sirf wahi pod
  OOM-kill ho, poora node (aur k3s) nahi.
- **Nateeja (s3, 2 vCPU / 3.8 GiB):** allocated requests **CPU 725m (36%)**, **memory 1228Mi (31%)**
  (Argo CD + CoreDNS + metrics-server). Asal usage (`kubectl top`): node 74m CPU, ~1.5 GiB memory (k3s
  + OS samet); Argo CD ke pods abhi 1–3m CPU, 4–42 MiB. Apps register hone pe controller aur repo-server
  barhenge, aur requests wahan ki haqeeqat ke mutabiq badli jayengi.

**Verify:**
```bash
kubectl --context lab-mgmt -n argocd get pods,ingress
helm --kubeconfig /etc/rancher/k3s/k3s.yaml -n argocd list      # s3 (root)
curl -s -o /dev/null -w '%{http_code}\n' https://argocd.lab.local/   # 200, bina -k
kubectl --context lab-mgmt describe node s3 | sed -n '/Allocated resources/,/Events/p'
```

**Interview sawal 1:** *Ingress pe TLS terminate karne aur `server.insecure` ka kya matlab hai? Security pe kya asar?*
**Jawab:** Client ka TLS ingress controller pe khatam hota hai, aur andar ingress → backend plain HTTP.
Is liye backend ko insecure (HTTP) mode mein chalate hain. Faida: aik jagah certs manage hote hain.
Nuqsaan: cluster ke andar traffic encrypted nahi hota. Zero-trust ke liye re-encrypt, passthrough, ya
mesh mTLS chahiye.

**Interview sawal 2:** *Argo CD CLI mein `--grpc-web` kab chahiye?*
**Jawab:** Jab CLI aur argocd-server ke beech koi proxy/ingress ho jo end-to-end gRPC (HTTP/2 + trailers)
support na kare. gRPC-Web calls ko aam HTTP requests mein lapet deta hai jo kisi bhi proxy se guzar
jati hain.

**Interview sawal 3:** *CPU limit na lagana kab theek hai?*
**Jawab:** Jab requests sahi set hon. Requests node pe CPU ka hissa guarantee karti hain, aur limit
sirf throttling laati hai, chahe CPU khaali ho. Memory ke liye limit zaroori hai kyunke memory wapas nahi
li ja sakti; zyada use pe OOM hota hai, aur limit usay sirf us pod tak mehdood rakhti hai.

---

## 5. `argocd-cli.sh`: CLI, login, admin password

**Kya kiya:**
1. argocd CLI **v3.5.5** (server ka version): GitHub release se, `cli_checksums.txt` se sha256 verify,
   `/usr/local/bin/argocd`.
2. Initial password `argocd-initial-admin-secret` se (sirf memory mein) liya, phir
   `argocd login argocd.lab.local --grpc-web --username admin`. `--insecure` nahi, kyunke Lab CA s1 pe
   trusted hai aur certificate poora verify hota hai.
3. Naya password: **32** random characters (`openssl rand`). Argo CD ka default `passwordPattern`
   `^.{8,32}$` hai. Pehle file mein (`/root/argocd-admin-password.new`, 600 root), phir
   `argocd account update-password`, phir `.new` → `/root/argocd-admin-password`, phir naye password se
   dobara login.
4. `argocd-initial-admin-secret` **delete**.
5. **Passwords kabhi command line pe nahi:** `argocd login --password X` likhne se password `ps` aur
   `/proc/<pid>/cmdline` mein (har local user ko) dikhta hai. Script password CLI ke **prompt** pe deti
   hai: Python ka chhota pty helper, jis ko password environment variable se milta hai (env sirf usi user
   ko dikhta hai). Output mein password ho to `***` se mita diya jata hai.

**Pehli koshish fail kyun hui (sabaq):** pehla password ~44 characters ka tha, aur server ne *"new
password does not match the following expression: ^.{8,32}$"* keh kar reject kar diya. Password badla
nahi tha, aur initial secret mojood tha. Asal error server logs (`argocd-server`) se mila, kyunke mere pty
helper ne "password" lafz wali **har** line chhupa di thi, error samet. Ab helper sirf prompt lines
chhupata hai, aur password 32 characters ka banta hai.

**Verify:**
```bash
argocd version --grpc-web               # argocd: v3.5.5 / argocd-server: v3.5.5
argocd account get-user-info --grpc-web # Logged In: true, Username: admin
kubectl --context lab-mgmt -n argocd get secret argocd-initial-admin-secret   # NotFound
sudo stat -c '%a %U' /root/argocd-admin-password                                # 600 root
```

**Interview sawal:** *`argocd-initial-admin-secret` ko delete kyun karte hain?*
**Jawab:** Us mein pehla admin password plain (base64) hota hai. Password badalne ke baad wo kisi kaam
ka nahi, lekin jis ke paas `get secrets` ho wo usay parh kar galat-fehmi ya purane password ke istemal ka
khatra paida kar sakta hai. Argo CD docs bhi password badalne ke baad isay delete karne ko kehti hain.
Production mein local admin hi band karke SSO (OIDC) + RBAC use hota hai.

---

## 6. `verify.sh`: 8 tests (nateeja)

| # | Test | Nateeja |
|---|---|---|
| 1 | k3s node + pods | ✅ s3 Ready (v1.36.5+k3s1), saare pods Running, chalte pods ke restarts 0. ⚠️ `helm-install-traefik` **job** ke 2 retries (Completed) |
| 2 | argocd pods | ✅ 6 pods Running, 0 restarts |
| 3 | `curl https://argocd.lab.local` (bina -k) | ✅ 200, `<title>Argo CD</title>`; `http://` → 404 |
| 4 | `openssl s_client` | ✅ Lab Root CA → argocd.lab.local, **Verify return code: 0 (ok)**, TLS 1.3 |
| 5 | `argocd version`, `get-user-info` | ✅ client = server = v3.5.5; Logged In: true (admin) |
| 6 | `argocd cluster list` | ✅ sirf `https://kubernetes.default.svc` (in-cluster). Workload cluster nahi |
| 7 | s3 resources | ✅ requests CPU 725m (36%), memory 1228Mi (31%); usage 74m CPU, ~1.5 GiB |
| 8 | `k3s secrets-encrypt status` | ✅ Enabled (AES-CBC), all hashes match |

**`helm-install-traefik` ke 2 retries:** k3s Traefik ko HelmChart job se lagata hai. Pehli koshishon mein
CRDs abhi register nahi hue hote, is liye job fail ho kar dobara chalti hai, aur teesri mein kamyab hoti
hai. Job ab `Completed` hai, aur ye k3s ka jaana-pehchana rawaiyya hai. Chalne wale pods ke restarts 0 hain.

---

## 7. Raaste mein seekha
1. **Timeout aur pehli dafa ki downloads:** k3s.sh ka 5 min ka intezar Traefik ke liye kam tha, kyunke
   Traefik deployment helm-install job ke baad banta hai. Ab 15 min hai (Phase 1 ke Calico jaisa sabaq).
2. **Password policy:** Argo CD `^.{8,32}$`. Lamba password zyada "mehfooz" lagta hai, lekin system ki
   policy pehle check karo.
3. **Error chhupana khatarnak hai:** output filter ne asal error chhupa diya tha. Filter sirf wohi chhupaye
   jo zaroori ho (prompts).
4. **Doosre phases ki scripts pe asar:** Phase 1 ki script kubeconfig overwrite karti thi. Naye phase mein
   purani scripts ka rawaiyya bhi dekhna padta hai.

---

## Kaise chalayein (tarteeb)
```bash
cd ~/lab-infra/phase3
ssh gohar@192.168.2.13 'rm -rf /tmp/lab-infra-phase3 && mkdir -p /tmp/lab-infra-phase3'
scp -r *.sh argocd ../pki/lab-root-ca.crt gohar@192.168.2.13:/tmp/lab-infra-phase3/
ssh gohar@192.168.2.13 'sudo bash /tmp/lab-infra-phase3/k3s.sh'
bash kubeconfig-s1.sh
bash argocd-cert.sh
ssh gohar@192.168.2.13 'sudo bash /tmp/lab-infra-phase3/argocd-install.sh /tmp/lab-infra-phase3/lab-root-ca.crt'
bash argocd-cli.sh
bash verify.sh
```
