# Phase 1: kubeadm se workload cluster (s1 + s2)

Is phase mein **s1** (control-plane) aur **s2** (worker) pe `kubeadm` se Kubernetes cluster
`lab-workload` banaya gaya. s3 aur s4 ko is phase mein bilkul nahi chheda gaya.

| Cheez | Version / value |
|---|---|
| Kubernetes (kubeadm, kubelet, kubectl) | **v1.37.1** (`1.37.1-1.1`, `pkgs.k8s.io/core:/stable:/v1.37`) |
| cri-tools (crictl) | 1.37.0 |
| containerd | **2.4.2** (`containerd.io 2.4.2-2`, Docker ki apt repo; Docker Engine NAHI) |
| Calico (CNI) | **v3.33.0** (Tigera operator v1.44.0) |
| etcd | 3.7.0 (kubeadm ka static pod) + etcdctl/etcdutl 3.7.0 |
| Pod CIDR / Service CIDR | `10.244.0.0/16` / `10.96.0.0/12` |
| API endpoint | `k8s-api.lab.local:6443` → 192.168.2.11 |

Saare versions aik jagah pinned hain: [`phase1/versions.sh`](../phase1/versions.sh).

**Scripts ki tarteeb** (sab idempotent, `set -euo pipefail`):

| # | Script | Kahan | Kaam |
|---|---|---|---|
| 1 | `k8s-packages.sh` | s1, s2 (root) | kubelet/kubeadm/kubectl/cri-tools pinned + hold |
| 2 | `containerd.sh` | s1, s2 (root) | containerd.io + config.toml + crictl |
| 3 | `init-control-plane.sh` | s1 (root) | validate → images pull → dry-run → `kubeadm init` → kubeconfig |
| 4 | `install-calico.sh` | s1 (gohar) | Calico operator + Installation |
| 5 | `join-worker.sh` | s1 (gohar) | s2 join (JoinConfiguration file, runtime token) |
| 6 | `approve-kubelet-csrs.sh` | s1 (gohar) | s1/s2 ke kubelet-serving CSRs (checks ke saath) |
| 7 | `etcd-backup.sh` | s1 (root) | etcdctl/etcdutl + roz ka snapshot timer |
| 8 | `verify.sh` | s1 (gohar) | 7 tests |

> `k8s-packages.sh` containerd se **pehle** chalti hai, kyunke `containerd.sh` sandbox (pause) image
> ka naam `kubeadm config images list` se leti hai, aur iske liye kubeadm pehle se install hona chahiye.

---

## 0. Bunyaad: Kubernetes ke hisse aur unka kaam

### Control-plane (s1 pe; kubeadm inhein **static pods** bana kar chalata hai)
Static pod ka matlab hai ke kubelet `/etc/kubernetes/manifests/*.yaml` khud parh kar pod chalata hai,
API server ke baghair. Isi tarah API server khud bhi chal pata hai.

| Component | Kaam (simple alfaaz mein) |
|---|---|
| **kube-apiserver** | Cluster ka "darwaza". Har cheez (kubectl, kubelet, controllers) isi se baat karti hai. Authentication, authorization (RBAC), admission aur validation karta hai, phir data etcd mein likhta hai. Ye wahid component hai jo etcd se seedha baat karta hai. |
| **etcd** | Cluster ka **database** (key-value, Raft consensus). Har object (pods, secrets, configmaps...) yahan hai. etcd gaya to cluster ki yaad-dasht gayi, is liye **backup** zaroori hai. |
| **kube-scheduler** | Naye pod ke liye node chunta hai: resources ki **requests**, taints/tolerations, affinity, nodeSelector dekh kar. Pod chalata nahi, sirf `nodeName` likhta hai. |
| **kube-controller-manager** | "Control loops" ka majmua: Deployment → ReplicaSet → Pods, node lifecycle, ServiceAccount tokens, **CSR signing** waghera. Har loop "desired state" ko "actual state" ke barabar karta rehta hai. |

### Har node pe
| Component | Kaam |
|---|---|
| **kubelet** | Node ka agent. API se pooch kar is node ke pods containerd (CRI) ke zariye chalata hai, health probes chalata hai, aur status report karta hai. systemd service hai, pod nahi. |
| **containerd** | Container runtime (CRI). Images pull karta hai aur `runc` ke zariye containers chalata hai. |
| **kube-proxy** | Services (ClusterIP/NodePort) ko iptables rules mein badalta hai, taake Service IP pe aaya traffic pods tak pohanche. (DaemonSet) |
| **CNI (Calico)** | Pods ko IP deta hai aur nodes ke darmiyan pod traffic pohanchata hai (VXLAN/BGP). Network policy bhi isi ka kaam hai. |
| **CoreDNS** | Cluster ke andar DNS: `web.ns.svc.cluster.local` → Service IP. Bahar ke naam upstream (192.168.2.2, 8.8.8.8) ko forward karta hai. |

**Interview sawal:** *Agar kube-scheduler band ho jaye to chalte pods pe kya asar hoga?*
**Jawab:** Chalte pods pe koi asar nahi hoga, kyunke wo kubelet aur containerd chala rahe hain. Sirf
**naye** pods Pending reh jayenge kyunke unhein koi node assign nahi karega. Isi tarah API server band
ho to bhi chalte containers chalte rehte hain, lekin koi badlaav, self-healing ya naya scheduling
nahi hota.

---

## 1. `k8s-packages.sh`: kubelet, kubeadm, kubectl, cri-tools

**Kya kiya:**
1. `pkgs.k8s.io/core:/stable:/v1.37` ki GPG key `/etc/apt/keyrings/kubernetes-apt-keyring.gpg` mein rakhi.
2. apt source mein `signed-by=` diya, taake ye key **sirf isi repo** ke liye mani jaye.
3. Exact version install kiya: `kubelet=1.37.1-1.1 kubeadm=1.37.1-1.1 kubectl=1.37.1-1.1 cri-tools=1.37.0-1.1`.
4. `apt-mark hold` charon pe lagaya, aur `systemctl enable kubelet` kiya.

**Kyun:**
- **Minor-version repo (`v1.37`)**: pkgs.k8s.io mein har minor version ki alag repo hai. Ghalti se
  `apt upgrade` 1.37 se 1.38 pe nahi ja sakta.
- **hold**: Kubernetes ka upgrade aik **process** hai: pehle `kubeadm upgrade plan/apply`, phir node
  drain, phir kubelet upgrade. Agar `apt upgrade` khamoshi se kubelet badal de to control-plane aur
  kubelet ka version skew toot sakta hai.
- **cri-tools alag**: naye packages mein `cri-tools` kubeadm ki dependency nahi raha. Isliye `crictl`
  khud se install nahi hua, aur script ne isay alag se install kiya.
- `signed-by` ke baghair key **har** repo ke liye trusted ho jati, jo security ke liye kharab hai.

**Production ahmiyat:** Version pinning + hold se upgrade sirf tab hota hai jab aap chahein. Saare
nodes pe exact same version hota hai, aur "works on one node" wale masle nahi aate.

**Verify:**
```bash
kubeadm version -o short; kubelet --version; kubectl version --client; crictl --version
apt-mark showhold          # cri-tools kubeadm kubectl kubelet (+ containerd.io)
```

**Interview sawal:** *kubelet ko `apt-mark hold` kyun karte hain?*
**Jawab:** Taake routine `apt upgrade` Kubernetes ka version na badle. Kubernetes ki version skew
policy ke mutabiq kubelet API server se naya nahi ho sakta. Upgrade ki sahi tarteeb hai: pehle
control-plane (`kubeadm upgrade`), phir har node drain karke kubelet. Is ke liye hold hata kar exact
version install karte hain, phir dobara hold lagate hain.

---

## 2. `containerd.sh`: container runtime

**Kya kiya:**
1. Docker ki apt repo ki key download karke us ka **fingerprint verify** kiya
   (`9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`), phir `signed-by` source banaya.
2. **Sirf `containerd.io`** install kiya (exact version `2.4.2-2`) aur hold lagaya. Docker Engine (`docker-ce`)
   NAHI hai, aur script check karti hai ke wo install na ho.
3. `config.toml` = `containerd config default` + 3 badlaav (har badlaav apne **section ke andar**):
   | Setting | Section | Value |
   |---|---|---|
   | `SystemdCgroup` | `cri.v1.runtime ... runc.options` | `true` |
   | `config_path` | `cri.v1.images.registry` | `/etc/containerd/certs.d` |
   | `config_path` | `transfer.v1.local` | `/etc/containerd/certs.d` |
   | `sandbox` | `cri.v1.images.pinned_images` | `registry.k8s.io/pause:3.10.2` (kubeadm se) |
4. `/etc/crictl.yaml` mein runtime/image endpoint `unix:///run/containerd/containerd.sock` set kiya.
5. Config badli ho to hi `containerd` restart hota hai. Verify `containerd config dump` (effective
   config) se hota hai, file se nahi.

**Kyun:**
- **Package wali config bekaar thi**: `containerd.io` ki default `/etc/containerd/config.toml` mein
  `disabled_plugins = ["cri"]` hota hai, kyunke Docker Engine ko CRI nahi chahiye. Kubernetes ko CRI
  chahiye, is liye default config se nayi file banayi. Purani file `config.toml.orig-package` ke naam se rakhi.
- **`SystemdCgroup = true`**: Ubuntu 24.04 mein **systemd** cgroups (v2) manage karta hai. kubelet
  (`cgroupDriver: systemd`) aur containerd dono ko **same** driver use karna chahiye. Agar aik
  `cgroupfs` aur doosra `systemd` ho to aik hi resource ke do manager ban jate hain. Nateeja: node
  dabaav mein unstable, aur pods ajeeb tarah se restart hote hain.
- **`config_path = /etc/containerd/certs.d`**: Registry ki settings (mirror, private CA, insecure lab
  registry) `certs.d/<registry>/hosts.toml` files mein dalti hain. Ye **do jagah** isliye hai kyunke
  containerd 2.x mein images do raaston se pull hoti hain: CRI (kubelet) aur transfer service. Phase 4
  mein s4 pe registry (`registry.lab.local`) aayegi, aur uski settings yahin jayengi.
- **sandbox (pause) image**: Har pod ka aik chhota "pause" container hota hai jo pod ka network
  namespace pakad kar rakhta hai. Ye wohi version ho jo kubeadm expect karta hai, warna kubeadm
  preflight warning deta hai aur images do dafa pull hoti hain.
- **Section-aware badlaav**: `config_path` do sections mein hai. Simple `sed s/config_path = ''/.../`
  dono ya ghalat wali badal sakta tha. Script har section mein exactly **1** badlaav ginti hai. Agar
  containerd ka format badla to script ruk jati hai, andaze se kaam nahi karti.

**Production ahmiyat:** cgroup driver ka mismatch Kubernetes ke sab se aam aur sab se mushkil se
pakde jane wale masaail mein se hai. Registry config `certs.d` mein rakhna containerd ka mojooda
tareeqa hai; purana `registry.mirrors` tareeqa deprecated hai.

**Verify:**
```bash
sudo containerd config dump | grep -E "SystemdCgroup|config_path|sandbox ="
sudo crictl info | jq '.config.containerd.runtimes.runc.options.SystemdCgroup // empty'
sudo crictl ps            # containers
systemctl is-active containerd; apt-mark showhold | grep containerd
```

**Interview sawal:** *kubelet aur containerd ka cgroup driver alag ho to kya hota hai?*
**Jawab:** Do alag systems cgroups ko manage karte hain: systemd apni hierarchy rakhta hai, aur
cgroupfs driver alag hierarchy bana deta hai. Resource accounting ghalat ho jati hai, aur memory
pressure mein node unstable ho jata hai. Pods/kubelet ajeeb tarah restart hote hain. kubeadm
(v1.22+) default `systemd` rakhta hai, is liye containerd mein bhi `SystemdCgroup = true` chahiye.

---

## 3. `init-control-plane.sh` + `kubeadm-config.yaml`: control-plane

**Kya kiya (tarteeb):**
1. Pre-checks: `k8s-api.lab.local` → `192.168.2.11` resolve hota ho, config ka version
   `versions.sh` se match kare, aur `kubeadm config validate` pass ho.
2. `kubeadm config images pull`: saari images pehle download (network ka masla init se pehle pakda jaye).
3. `kubeadm init --config ... --dry-run`: kuch badalta nahi, sirf dikhata hai kya hoga. Fail ho to
   asal init nahi hota.
4. `kubeadm init --config kubeadm-config.yaml`. Output `/root/kubeadm-init-<time>.log` (sirf root
   parh sake) mein jata hai, kyunke us mein **bootstrap token** hota hai.
5. `/etc/kubernetes/admin.conf` → `~gohar/.kube/config` (600), aur kubectl bash completion.
6. Verify: API `/readyz`, aur control-plane **taint maujood** hai.
7. Idempotent: `admin.conf` pehle se ho to init dobara nahi hota. Fail ho to `kubeadm reset` NAHI.

### kubeadm config file: har field ka matlab

**InitConfiguration** (sirf is node ke `init` ke liye):
| Field | Value | Matlab |
|---|---|---|
| `localAPIEndpoint.advertiseAddress` | 192.168.2.11 | API server ye IP announce karta hai, aur doosre components isi pe pohanchte hain. Na diya jaye to kubeadm default route wala IP leta hai (andaza). |
| `localAPIEndpoint.bindPort` | 6443 | API server ka port. |
| `nodeRegistration.name` | s1 | Kubernetes mein node ka naam. Hostname pe chhorne ke bajaye wazeh likha. |
| `nodeRegistration.criSocket` | `unix:///run/containerd/containerd.sock` | kubelet kis runtime se baat kare. |
| `nodeRegistration.kubeletExtraArgs: node-ip` | 192.168.2.11 | kubelet node ka **yahi** IP report kare. Multi-NIC ya VPN wali machine pe ghalat IP chunne se bachata hai. |
| `nodeRegistration.taints` | (nahi likha) | Na likhne ka matlab default taint `node-role.kubernetes.io/control-plane:NoSchedule` lagta hai. (Agar `taints: []` likhte to taint hat jata.) |

**ClusterConfiguration** (poore cluster ki config, `kubeadm-config` ConfigMap mein save hoti hai):
| Field | Value | Matlab |
|---|---|---|
| `clusterName` | lab-workload | kubeconfig mein cluster ka naam (s3 wale management cluster se alag pehchan). |
| `kubernetesVersion` | v1.37.1 | Control-plane images ka exact version (`stable-1` jaisa andaza nahi). |
| `controlPlaneEndpoint` | `k8s-api.lab.local:6443` | Saare clients (kubelets, kubeconfig) API ko is **naam** se dhoondte hain. Neeche tafseel hai. |
| `networking.podSubnet` | 10.244.0.0/16 | Pods ke IPs. kube-controller-manager har node ko is mein se `podCIDR` deta hai. Calico ka IP pool bhi yahi hai. |
| `networking.serviceSubnet` | 10.96.0.0/12 | ClusterIP Services ke virtual IPs (`kubernetes` = 10.96.0.1, DNS = 10.96.0.10). |
| `networking.dnsDomain` | cluster.local | Service DNS ka suffix. |
| `apiServer.certSANs` | k8s-api.lab.local, 192.168.2.11, s1 | API server ke TLS certificate mein ye naam/IP bhi daale jate hain, taake in sab se `https://...:6443` pe certificate error na aaye. |

**KubeletConfiguration** (har node ke kubelet ki config, `kubelet-config` ConfigMap mein; s2 ne join pe yahi li):
| Field | Value | Matlab |
|---|---|---|
| `cgroupDriver` | systemd | containerd ke `SystemdCgroup = true` se match. |
| `serverTLSBootstrap` | true | kubelet ka **serving** certificate (port 10250) self-signed ke bajaye cluster CA se. Neeche tafseel hai. |

### `controlPlaneEndpoint` DNS naam kyun, IP kyun nahi?
- Ye endpoint **har jagah** likha jata hai: kubeconfig files, har kubelet ki `kubelet.conf`, API
  server certificate, aur `kube-public/cluster-info`.
- Kal ko aap HA banana chahein (3 control-planes + load balancer), to sirf `k8s-api.lab.local` ko LB ke
  IP pe point karna hoga. Saare nodes aur kubeconfigs chalte rahenge.
- Agar `192.168.2.11` likha hota to HA ya IP badalne pe har cert aur har node ki config dobara banani
  padti, aur aksar cluster dobara banana parta. **Baad mein `controlPlaneEndpoint` add karna bohat
  mushkil hai**, is liye ye pehle din hi kiya jata hai.
- Hamare lab mein naam `/etc/hosts` se resolve hota hai (Phase 0). Production mein ye asli DNS record
  hota hai.

### `podSubnet` aur LAN overlap ka khatra
- Pod IPs aur node/LAN IPs **kabhi overlap nahi hone chahiye**. Agar pod ka CIDR `192.168.0.0/16` hota
  to wo hamare LAN `192.168.2.0/24` (nodes, gateway `192.168.2.2`, DNS) ko bhi cover karta. Node pe
  route table mein `192.168.2.x` ke liye do raaste ban jate. Gateway/DNS ka traffic pods ki taraf chala
  jata, yani node apna internet/DNS kho deta, aur pods LAN machines tak nahi pohanch pate.
- **Calico ke upstream `custom-resources.yaml` mein default `192.168.0.0/16` hai**, bilkul overlap wala!
  Isi liye hamari `installation.yaml` mein `10.244.0.0/16` likha hai, jo kubeadm ke `podSubnet` se bhi
  match karta hai.
- Service CIDR (`10.96.0.0/12` = 10.96–10.111) aur pod CIDR (`10.244/16`) bhi aapas mein overlap nahi
  karte, aur VPN/office networks se bhi nahi takrane chahiye.

### Control-plane taint kyun?
- `node-role.kubernetes.io/control-plane:NoSchedule` ka matlab hai ke s1 pe **sirf wo pods** chalenge
  jin mein is taint ki toleration ho (control-plane khud, Calico, kube-proxy). Apps s2 pe jayengi.
- **Kyun:** API server/etcd ko CPU, memory aur disk ka sukoon chahiye. Agar koi app memory kha jaye ya
  disk bhar de to poora cluster (sab nodes ka control) gir jata hai. Security bhi: control-plane pe
  `/etc/kubernetes/pki` (cluster ki chabiyan) hain, aur wahan untrusted app ka chalna khatarnak hai.
- Hamara verify test s1 pe sirf aik test pod **toleration ke saath** chalata hai. Taint hataya nahi gaya.

### Workers ka CNI se pehle join karna normal kyun hai?
- `kubeadm join` sirf ye karta hai: kubelet ko certificate dilata hai aur node register karta hai.
  Isay pod network ki zaroorat nahi. Node `NotReady` aata hai jab tak us pe CNI tayyar na ho.
- CNI (Calico) **DaemonSet** hai: jaise hi naya node aata hai, Calico khud us pe `calico-node` chala
  deta hai. Ye pod `hostNetwork` pe chalta hai (pod network ki zaroorat nahi), aur images pull hone ke
  baad node `Ready` ho jata hai. s2 ko is mein ~10 minute lage, sirf image download ki wajah se.
- Isi wajah se CNI se pehle ya baad join karne mein fark nahi. Production automation (Cluster API,
  autoscalers) mein bhi nodes kabhi bhi aate hain aur CNI DaemonSet unhein khud sambhal leta hai.

**Production ahmiyat:** Config **file** (CLI flags nahi) git mein hoti hai, review hoti hai, aur
dobara banane pe bilkul wohi cluster banta hai. Dry-run pehle chalane se ghalti init se pehle pakdi
jati hai.

**Verify:**
```bash
kubectl get nodes -o wide
kubectl -n kube-system get cm kubeadm-config -o yaml        # cluster ki save hui config
kubectl describe node s1 | grep -A2 Taints
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName
```

**Interview sawal 1:** *`controlPlaneEndpoint` kya hai aur isay IP ke bajaye DNS kyun rakhte hain?*
**Jawab:** Ye wo address hai jis se saare clients aur nodes API server tak pohanchte hain. Ye
certificates aur har node ki kubeconfig mein likha jata hai. DNS naam rakhne se baad mein HA/load
balancer lagana ya IP badalna sirf DNS record badalne ka kaam reh jata hai. Warna certs aur saare
nodes ki config dobara banani padti hai.

**Interview sawal 2:** *Pod CIDR node network se overlap kare to kya hoga?*
**Jawab:** Routing toot jati hai. Node ko samajh nahi aata ke `192.168.2.x` LAN pe hai ya kisi pod
ka hai. Gateway/DNS/doosre nodes ka traffic pod network mein chala jata hai, aur node aur pods dono
ka bahar se rabta toot sakta hai. Is liye CIDR planning cluster banane se **pehle** hoti hai.

**Interview sawal 3:** *Control-plane node pe taint kyun hota hai?*
**Jawab:** Taake normal apps wahan schedule na hon. Control-plane components (etcd, API server) ko
resources ka sukoon mile, aur koi bhari ya untrusted app poore cluster ko na giraye. Sirf wo pods
wahan chalte hain jin mein toleration ho, jaise CNI aur kube-proxy.

---

## 4. `install-calico.sh`: CNI (Calico, Tigera operator)

**Kya kiya:**
1. Calico **v3.33.0** ke upstream manifests `phase1/calico/` mein save kiye (`operator-crds.yaml`,
   `tigera-operator.yaml`) aur unka `SHA256SUMS` banaya. Script pehle sha256 check karti hai.
2. CRDs aur operator `kubectl apply --server-side` se. (CRD file 3.5 MB ki hai, aur client-side apply
   ki annotation size limit se fail ho jati hai.)
3. Hamara [`calico/installation.yaml`](../phase1/calico/installation.yaml): sirf aik `Installation`
   resource:
   ```yaml
   calicoNetwork:
     ipPools:
       - cidr: 10.244.0.0/16
         encapsulation: VXLANCrossSubnet
         natOutgoing: Enabled
         blockSize: 26
     nodeAddressAutodetectionV4:
       interface: "ens33"
   ```
4. Upstream `custom-resources.yaml` ke `APIServer`, `Goldmane` (flow aggregator) aur `Whisker`
   (observability UI) **shamil nahi kiye**. Ye optional hain.
5. Verify: `tigerastatus calico` Available, nodes Ready, IP pool sahi.

**Kyun / fields ka matlab:**
- **Operator kyun:** Calico ke darjanon resources (DaemonSet, Deployments, certificates, RBAC)
  haath se manage karne ke bajaye aik `Installation` object likhte hain, aur operator baaqi sab
  banata aur upgrade karta hai. Ye Calico ka recommended tareeqa hai.
- **`nodeAddressAutodetectionV4: interface: ens33`:** Calico ko har node ka IP chahiye (VXLAN tunnel
  aur BGP ke liye). Auto-detect kabhi `vxlan.calico` ya kisi aur interface ka IP utha leta hai.
  Interface ka naam dene se andaza khatam ho jata hai. (Phase 0 mein netplan ne `ens33` ka naam MAC se
  pakka kar diya tha.)
- **`natOutgoing: Enabled`:** Pod se bahar (internet) jane wala traffic node ke IP se SNAT hota hai.
  Bahar ke routers `10.244.x.x` ko nahi jaante, is liye jawab wapas nahi aata. DNS test mein
  `github.com` tak pohanchna isi ki wajah se mumkin hai.
- **`blockSize: 26`:** Har node ko pod IPs 64 ke blocks mein milte hain (zaroorat pe aur blocks).
- **VXLANCrossSubnet:**
  - Same subnet mein (s1 aur s2 dono `192.168.2.0/24` mein): pod traffic **bina encapsulation**, seedha
    route hota hai (BGP se routes milte hain). Ye sab se tez hai, koi overhead nahi.
  - Mukhtalif subnet ke nodes: traffic **VXLAN** (UDP 4789) mein lapet kar bheja jata hai, kyunke
    beech ke routers pod IPs nahi jaante.
  - Yani "jahan zaroorat ho wahan overlay". Pure VXLAN har packet pe ~50 byte aur CPU kharch karta
    hai; pure BGP ko network se route support chahiye. CrossSubnet dono ka faida deta hai.
  - Hamare verify mein `bird: ... filtered out ... dev vxlan.calico` aur cross-node ping 0% loss
    dikhata hai ke routing kaam kar rahi hai.

**⚠️ `tigerastatus tiers` "Degraded":** `tiers` component *"Waiting for Tigera API server to be ready"*
dikhata hai, kyunke hum ne Calico `APIServer` install nahi kiya. Main `calico` component Available
hai, aur networking, IPAM aur policy (Kubernetes NetworkPolicy) chal rahe hain. Calico ke apne
`projectcalico.org/v3` resources (tiers, GlobalNetworkPolicy via kubectl) ke liye APIServer chahiye.
Faisla [backlog](backlog.md) mein hai.

**Production ahmiyat:** CNI version pin karna aur manifests git mein rakhna zaroori hai. "latest" URL
se apply karne se aaj aur kal ka cluster alag ban sakta hai. Overlap-free CIDR aur sahi interface
autodetection CNI ke masaail ki sab se badi wajahen hain.

**Verify:**
```bash
kubectl get tigerastatus
kubectl -n calico-system get pods -o wide
kubectl get ippools.crd.projectcalico.org -o yaml | grep -E "cidr|vxlanMode|natOutgoing"
ip route | grep -E "10.244|vxlan"         # node pe pod routes
```

**Interview sawal:** *Calico mein VXLAN, VXLANCrossSubnet aur no-encapsulation (BGP) mein kya fark hai?*
**Jawab:** VXLAN har pod packet ko UDP mein lapet kar bhejta hai, jo kisi bhi network pe chalta hai
lekin overhead hota hai. No-encap mein pod IPs seedha route hote hain (BGP se), jo tez hai lekin network
ko pod routes support karne chahiye. VXLANCrossSubnet same subnet ke nodes ke darmiyan seedha routing
karta hai aur subnet paar karte waqt VXLAN, is liye dono ka faida milta hai.

---

## 5. `join-worker.sh` + `kubeadm-join.yaml.tmpl`: s2 join

**Kya kiya:**
1. Idempotency: s2 pehle se cluster mein ho to skip. Agar s2 pe `kubelet.conf` ho lekin node cluster
   mein na ho to script **ruk jati hai** (reset nahi karti).
2. Pre-checks s2 pe: `k8s-api.lab.local` resolve, containerd/CRI theek, API port 6443 tak TCP.
3. **Runtime token:** s1 pe `kubeadm token create --ttl 30m --print-join-command`. Is mein se token
   aur CA hash sirf variables mein liye gaye, kabhi print ya file mein nahi.
4. Template (`__TOKEN__`, `__CA_HASH__`, `__NODE__`, `__NODE_IP__`) bhar kar **stdin ke zariye** s2 pe
   `/root/kubeadm-join.yaml` (600 root) likha. Token command line (argv / `ps`) mein nahi aata.
5. `kubeadm join --config ... --dry-run`, phir asal join.
6. Join ke baad (ya fail hone pe bhi, `trap` se) s2 pe file `shred` aur s1 pe **token delete**.

**Kyun:**
- **Bootstrap token** aik kam-umr password hai. Jiske paas ye ho wo cluster mein node jor sakta hai.
  Is liye: 30 min TTL, kaam ke foran baad delete, aur kabhi git mein nahi. Repo mein sirf placeholders
  wala template hai.
- **`caCertHashes`:** naya node pehli dafa API server se CA certificate leta hai. Hash se wo verify karta
  hai ke ye **hamara** CA hai, koi beech mein baitha attacker (MITM) nahi.
- **JoinConfiguration file:** init ki tarah join bhi file se, git mein review hone wala. `node-ip`
  wahan wazeh likha hai.

**Production ahmiyat:** Join credentials ki leak ka matlab hai koi bhi apna node cluster mein daal
kar secrets tak pohanch sakta hai. Production mein tokens automation (Cluster API, cloud bootstrap)
banati aur foran khatam karti hai.

**Verify:**
```bash
kubectl get nodes -o wide
sudo kubeadm token list                        # join ke baad koi purana token nahi
ssh gohar@192.168.2.12 'sudo ls /root/kubeadm-join.yaml'   # "No such file"
```

**Interview sawal:** *`--discovery-token-ca-cert-hash` kis cheez se bachata hai?*
**Jawab:** Join karte waqt node API server se cluster CA leta hai. Hash ke baghair node kisi bhi server
ke CA pe bharosa kar leta, aur attacker apna fake API server dikha sakta tha. Hash se node pakka karta
hai ke CA ki public key wohi hai jo admin ne di.

---

## 6. `approve-kubelet-csrs.sh`: serverTLSBootstrap aur CSR approval

### Masla kya hai?
kubelet do certificates use karta hai:
| Certificate | Kis kaam | Approve kaun karta hai |
|---|---|---|
| **Client** (`kube-apiserver-client-kubelet`) | kubelet → API server | Kubernetes **khud** (bootstrap ke dauran auto-approve) |
| **Serving** (`kubelet-serving`) | API server → kubelet (port 10250: `kubectl logs/exec/port-forward`, metrics) | **Koi nahi.** Kisi insaan ya controller ko approve karna padta hai |

- `serverTLSBootstrap: false` (default) hota to kubelet apna **self-signed** serving cert bana leta.
  API server ko us pe bharosa karna padta, ya check hi band karna padta (metrics-server ka
  `--kubelet-insecure-tls` isi wajah se mashhoor hai).
- `serverTLSBootstrap: true` pe kubelet cluster CA se signed cert maangta hai (CSR). Kubernetes
  serving CSRs ko **khud approve nahi karta**, kyunke usay pata nahi ke node jo naam/IP maang raha hai
  wo sach mein uske hain. Approval tak `kubectl logs` *"tls: internal error"* deta hai. Hamare saath
  bilkul yahi hua tha.

### Hum ne kaise approve kiya (aur kya check kiya)
Script har **Pending** `kubernetes.io/kubelet-serving` CSR ke liye:
1. **Requester** `system:node:s1` ya `system:node:s2` ho (koi aur naam ho to skip).
2. Requester `system:nodes` group mein ho.
3. CSR ke **andar** (`openssl req -text`):
   - Subject `CN = system:node:<node>` ho.
   - SANs mein **sirf** `DNS:<node>` aur `IP:<us node ka IP>` ho. Koi aur naam/IP ho (misal
     `DNS:k8s-api.lab.local` ya kisi doosre node ka IP) to **skip**.
4. Sab theek ho tabhi `kubectl certificate approve`. Shaky CSR ko deny nahi karti, sirf chhor deti hai
   taake insaan dekhe.

**Kyun content check bhi:** Agar koi compromised node (ya uska kubelet credential) apne CSR mein
`DNS:k8s-api.lab.local` maang le aur hum andha approve kar dein, to wo API server ka roop dhaar kar
traffic beech mein pakad sakta hai. Requester naam akela kaafi nahi.

**Nateeja:** s1 ke 3 CSRs (restarts ki wajah se 3 bane) aur s2 ka 1 CSR approve hue. Har aik mein
SANs sirf apne naam/IP thay.

**Kab dobara zaroorat hogi:** serving cert ki umr ~1 saal hai. Rotation pe naya CSR aata hai, aur
naya node join hone pe bhi. Is liye isay **automate** karna backlog mein hai (misal
`kubelet-csr-approver` controller, jo yahi checks khud karta hai).

**Verify:**
```bash
kubectl get csr                                   # kubelet-serving: Approved,Issued
kubectl -n kube-system logs kube-proxy-<id> | head   # "tls: internal error" nahi aana chahiye
echo | openssl s_client -connect 192.168.2.12:10250 2>/dev/null | openssl x509 -noout -issuer -ext subjectAltName
```

**Interview sawal:** *`kubectl logs` pe "remote error: tls: internal error" aa raha hai. Kya wajah ho sakti hai?*
**Jawab:** Aksar `serverTLSBootstrap: true` hai aur kubelet ka serving CSR approve nahi hua, is liye
kubelet ke paas port 10250 ke liye certificate hi nahi. `kubectl get csr` mein Pending
`kubelet-serving` CSRs dekho, requester (`system:node:<naam>`) aur SANs check karo, phir approve karo.

---

## 7. `etcd-backup.sh`: etcd backup aur restore

**Kya kiya:**
1. Chalte etcd ka version static pod manifest ki image se nikala (`etcd:3.7.0-0` → `3.7.0`), taake
   tools hamesha etcd se match karein, Kubernetes upgrade ke baad bhi.
2. GitHub release se `etcd-v3.7.0-linux-amd64.tar.gz` liya, `SHA256SUMS` se **verify** kiya, aur sirf
   `etcdctl` + `etcdutl` `/usr/local/bin` mein rakhe.
3. `/usr/local/sbin/etcd-snapshot.sh`:
   - `etcdctl snapshot save` (`healthcheck-client` cert se, `https://127.0.0.1:2379`) pehle
     `*.db.part` naam se.
   - `etcdutl snapshot status` pass ho to hi asal naam (`etcd-snapshot-<UTC>.db`, 600). Aadha ya
     kharab snapshot kabhi "backup" na lage.
   - 7 din se purane snapshots delete.
4. `etcd-snapshot.service` (oneshot, `Nice=10`, IO idle) + `etcd-snapshot.timer`: roz **02:00 UTC**
   (`RandomizedDelaySec=10m`). **`Persistent=true`** ka matlab hai ke agar 02:00 pe machine band thi
   (hamari VMs raat ko band hoti hain) to agle boot pe snapshot ban jata hai.
5. Abhi aik snapshot bana kar `etcdutl snapshot status` se verify kiya: revision ~9.7k, 665 keys, 10 MB.

**Kyun:**
- etcd mein **poore cluster ki state** hai: har Deployment, Service, Secret, ConfigMap, RBAC, CRDs.
  Disk kharab ho, ghalti se `kubectl delete ns` ho jaye, ya upgrade bigar jaye, to sirf etcd snapshot
  se cluster ki "yaad-dasht" wapas aati hai.
- Hamare paas **aik** control-plane hai, yani etcd ki aik hi copy. HA nahi hai, is liye backup hi
  bachao hai.
- **Snapshots mein Secrets plain hote hain** (encryption-at-rest band hai), is liye folder 700 aur
  files 600 root hain. Production mein backup ko **node se bahar** (S3/NFS) encrypted rakhte hain.
  Disk mar gayi to usi disk ka backup bhi gaya.

**Restore kaise hoga (single control-plane kubeadm, s1). ⚠️ Abhi sirf likha hai, drill backlog mein:**
```bash
# 0) Sahi snapshot chuno aur check karo
sudo etcdutl snapshot status /var/backups/etcd/etcd-snapshot-<UTC>.db -w table

# 1) API server aur etcd band karo (static pods: manifest hatao, kubelet khud band kar dega)
sudo mkdir -p /root/manifests-off
sudo mv /etc/kubernetes/manifests/{etcd,kube-apiserver}.yaml /root/manifests-off/
sudo crictl ps | grep -E "etcd|kube-apiserver"     # khaali hone ka intezar

# 2) Purana data side pe (delete nahi)
sudo mv /var/lib/etcd /var/lib/etcd.before-restore-$(date -u +%Y%m%dT%H%M%SZ)

# 3) Snapshot se naya data-dir (naam/URLs wohi jo etcd.yaml mein hain)
sudo etcdutl snapshot restore /var/backups/etcd/etcd-snapshot-<UTC>.db \
  --data-dir /var/lib/etcd \
  --name s1 \
  --initial-cluster s1=https://192.168.2.11:2380 \
  --initial-advertise-peer-urls https://192.168.2.11:2380

# 4) Manifests wapas → kubelet etcd + API server chalata hai
sudo mv /root/manifests-off/{etcd,kube-apiserver}.yaml /etc/kubernetes/manifests/

# 5) Verify
sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key endpoint health
kubectl get nodes; kubectl get pods -A
```
Restore ke baad cluster **snapshot ke waqt** ki haalat mein hota hai. Uske baad bane objects nahi
hote, lekin chalte containers chalte rehte hain aur controllers unhein "desired state" se match kar
dete hain. `/etc/kubernetes/pki` (certificates) etcd mein nahi hain; unka backup alag chahiye (backlog).

**Production ahmiyat:** "Backup jo kabhi restore nahi kiya, wo backup nahi, umeed hai." Production
mein snapshots off-node aur encrypted hote hain, retention policy hoti hai, aur restore ki **drill**
baqaida chalti hai.

**Verify:**
```bash
systemctl list-timers etcd-snapshot.timer
sudo ls -l /var/backups/etcd/
sudo etcdutl snapshot status "$(sudo ls -1t /var/backups/etcd/*.db | head -1)" -w table
journalctl -u etcd-snapshot.service -n 20
```

**Interview sawal 1:** *`etcdctl snapshot save` aur `etcdutl snapshot restore` mein kya fark hai?*
**Jawab:** `etcdctl` chalte etcd **server se network pe** baat karta hai (save, health, status).
`etcdutl` **offline** tool hai jo seedha files pe kaam karta hai (restore, snapshot status, defrag). etcd
v3.5 mein `etcdutl` aaya aur `etcdctl snapshot restore` deprecated hua; v3.6 se restore sirf `etcdutl` se hota hai.

**Interview sawal 2:** *Agar etcd ka data kho jaye aur backup na ho to kya hoga?*
**Jawab:** Cluster ki saari definitions (deployments, services, secrets, RBAC) chali jati hain. Chalte
containers kuch der chalte rahenge, lekin control-plane unhein pehchan nahi payega. Cluster ko dobara
banana aur saari apps dobara deploy karni padti hain. GitOps (Argo CD) hone se apps wapas aa sakti
hain, lekin Secrets aur runtime state phir bhi chali jati hai.

---

## 8. `verify.sh`: 7 tests (nateeja)

Test resources `phase1-test` namespace mein bante hain, aur aakhir mein (`trap` se, fail ho tab bhi)
namespace delete ho jata hai.

| # | Test | Nateeja |
|---|---|---|
| 1 | Nodes Ready, IPs, version | ✅ s1 192.168.2.11, s2 192.168.2.12, v1.37.1 |
| 2 | Saare pods Running + Ready | ✅ (⚠️ restarts > 0: neeche dekho) |
| 3 | DNS: `kubernetes.default` aur `github.com` | ✅ 10.96.0.1 / 20.207.73.82 |
| 4 | Cross-node pod ping (s1 ↔ s2) | ✅ 0% loss |
| 5 | nginx Deployment + ClusterIP Service, doosre pod se curl | ✅ |
| 6 | `kubeadm certs check-expiration` | ✅ certs 364 din, CAs 9 saal |
| 7 | etcd health + backup timer | ✅ |

**Restarts > 0 kyun:** Har pod ka aakhri restart ya to **07:12:29** pe hua (VMs on hone ka waqt) ya
**20:07:04** pe (poweroff). Boot ke baad se koi restart nahi hua. Ziyada counts (tigera-operator 9,
calico-kube-controllers 7) pehle din ki CPU ki kami (neeche) ke waqt ke hain. Counter saaf karne ke
liye pods delete nahi kiye, kyunke wo sirf dikhawa hota.

**DNS test mein retry:** Pehli run mein `github.com` aik dafa fail hua. Tehqeeq se pata chala ke
CoreDNS ki saari upstream `i/o timeout` errors boot ke waqt (07:13) ki thin, jab pod network abhi
tayyar nahi tha. Uske baad 20/20 lookups kamyab hue aur koi nayi error nahi aayi. DNS UDP pe chalta hai
aur aik packet gum ho sakta hai, is liye test ab 3 koshishen karta hai aur **har koshish output mein
dikhata hai**. Retry chahiye pade to WARN aata hai, chupta nahi.

---

## 9. Pehle din ka masla: "Calico 2 CPU pe nahi chal raha tha" (sabaq)

**Kya hua:** s1 pe 2 vCPU thay. Calico lagate waqt load average 46 tak gaya, CPU 0% idle tha (60%
kernel/system time), calico ke health probes timeout hote rahe, aur tigera-operator CrashLoopBackOff
mein chala gaya. s1 ko **4 vCPU** dene ke baad sab foran theek ho gaya (load ~1).

**Wajah "Insufficient cpu" NAHI thi.** Scheduler ke hisaab se jagah kaafi thi:

**s1 (control-plane) pe CPU requests (4 vCPU ke baad):**
| Pod | CPU request | Memory request |
|---|---|---|
| kube-apiserver | 250m | – |
| kube-controller-manager | 200m | – |
| kube-scheduler | 100m | – |
| etcd | 100m | 100Mi |
| coredns (x2) | 100m + 100m | 70Mi + 70Mi |
| calico-node, typha, kube-controllers, csi, tigera-operator, kube-proxy | **0** (koi request nahi) | – |
| **Kul** (`kubectl describe node s1` → Allocated resources) | **850m (21% of 4)** | **240Mi (6%)** |

2 vCPU pe bhi ye sirf ~43% hota. Is liye scheduler ne har pod ko jagah di, aur koi pod "Insufficient
cpu" se Pending nahi hua. Shuru mein pods ke `FailedScheduling` events *"untolerated taint"* wale thay,
jo CNI se pehle lagne wala `node.kubernetes.io/not-ready` taint tha aur normal hai.

**Scheduler "requests" dekhta hai, asal usage nahi:**
- Scheduler sirf ye ginta hai: node allocatable − (pods ki **requests** ka jor). Wo ye nahi dekhta ke
  CPU **asal mein** kitna busy hai.
- Calico ke pods ki **koi CPU request nahi** (BestEffort), is liye scheduler ke liye wo "muft" thay,
  lekin startup pe asal mein bohat CPU khate hain. Control-plane bhi apni requests (850m) se kahin
  zyada asal CPU use karta hai.
- Nateeja: scheduler ke hisaab se sab theek tha, lekin node asal mein CPU ke liye taras raha tha. Probes
  timeout hue, kubelet ne containers restart kiye, aur restarts ne aur CPU khaya. Ye aik bura chakkar tha.
- **Sabaq:** (1) Control-plane ka minimum (2 CPU) sirf "start hone" ka minimum hai; CNI aur baaqi load
  ke saath **4 CPU** behtar hai. (2) Production mein pods ki sahi requests set karna aur node ka asli
  usage (metrics/monitoring) dekhna dono zaroori hain. (3) kubelet `kubeReserved/systemReserved` se OS
  aur kubelet ke liye CPU alag rakha ja sakta hai (backlog).

**Interview sawal:** *Node pe CPU 100% busy hai lekin `kubectl describe node` 21% CPU allocated dikha raha hai. Ye kaise?*
**Jawab:** "Allocated" sirf pods ki **requests** ka jor hai, asal usage nahi. Jin pods ki requests
nahi (BestEffort) ya jo request se zyada use karte hain, unka asal kharch is mein nahi dikhta. Asal
usage `kubectl top` (metrics-server), `top` ya monitoring se dekhte hain. Scheduler bhi requests pe hi
faisla karta hai, is liye requests ka haqeeqat ke qareeb hona zaroori hai.

---

## 10. Choti baatein jo raaste mein seekhi

1. **kubeadm config file mein shuru ka `---`:** comments ke baad pehla `---` aik **khaali** YAML
   document bana deta hai, aur `kubeadm config validate` *"kind and apiVersion is mandatory"* deta hai.
   Pehla document `---` ke baghair shuru karo. Validate pehle chalane ka faida yahi hai.
2. **`ETCDCTL_API=3`:** etcdctl v3.4+ mein API v3 default hai. v3.7 is variable ko *"unrecognized"*
   kehta hai, is liye hata diya.
3. **`containerd.io` ki default config CRI band rakhti hai** (`disabled_plugins = ["cri"]`). Kubernetes
   ke liye nayi config zaroori hai.
4. **Image download sab se lamba kaam tha:** s2 pe Calico ki 2 images mein ~10 min lage. Images
   pehle se pull karna (ya local registry, Phase 4) setup ko tez karta hai.
5. **Server-side apply aur operator ka "ownership":** Calico `Installation` dobara apply karne pe
   conflict aaya, kyunke operator `ipPools` mein apne defaults (`allowedUses`, `assignmentMode`...)
   bhar kar us field ka **manager** ban jata hai. `--force-conflicts` se hum ownership cheen lete aur har
   run pe operator se kheench-taan hoti. Is liye script ab Installation mojood ho to dobara apply nahi
   karti, sirf zaroori fields (cidr, encapsulation, natOutgoing, blockSize, interface) **compare** karti
   hai, aur farq ho to ruk jati hai. (Live cluster pe IP pool ka CIDR badalna waise bhi mana hai.)
6. **`cmd | grep -q` + `set -o pipefail` = kabhi kabhi ghalat FAIL:** `grep -q` pehla match milte hi band
   ho jata hai. Agar `cmd` (misal `apt-mark showhold`, `lsmod`) abhi likh raha ho to usay SIGPIPE
   milta hai, aur `pipefail` poori pipe ko fail maan leta hai. s2 pe *"cri-tools hold nahi hai"* isi
   wajah se aaya, jab ke hold laga hua tha. Fix: pehle poora output pakdo, phir grep:
   `grep -q X <<<"$(cmd)"`. Phase 0 aur 1 ki saari scripts mein ye badla gaya.
7. **Boot ke baad `apt-daily`:** machines raat ko band thin, is liye `apt-daily.timer` (Persistent) ne
   boot ke baad chhoota hua run chalaya. Hamari script ka `apt-get update` lists lock nahi le saka.
   `DPkg::Lock::Timeout` sirf dpkg lock pe lagta hai, lists lock pe nahi. Fix: `wait_apt_locks` helper
   (`fuser` se saare apt locks check, max 5 min intezar), jo `k8s-packages.sh`, `containerd.sh` aur
   `phase0/common.sh` mein laga hai.
8. **Power off/on ke baad cluster khud wapas aaya:** kubelet/containerd enabled hain, static pods
   kubelet chalata hai, aur etcd ka data disk pe hai. Boot ke ~1 min baad sab Running tha.

---

## Kaise chalayein (naye machines pe, tarteeb se)

```bash
cd ~/lab-infra/phase1
for ip in 192.168.2.12 192.168.2.11; do               # s2, s1
  ssh gohar@$ip 'rm -rf /tmp/lab-infra-phase1 && mkdir -p /tmp/lab-infra-phase1'
  scp *.sh gohar@$ip:/tmp/lab-infra-phase1/
  ssh gohar@$ip 'sudo bash /tmp/lab-infra-phase1/k8s-packages.sh && sudo bash /tmp/lab-infra-phase1/containerd.sh'
done
sudo bash init-control-plane.sh          # s1
bash install-calico.sh
bash approve-kubelet-csrs.sh             # s1 ka serving CSR
bash join-worker.sh                      # s2
bash approve-kubelet-csrs.sh             # s2 ka serving CSR (node Ready hone ke baad)
sudo bash etcd-backup.sh
bash verify.sh
```
