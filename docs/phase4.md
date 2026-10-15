# Phase 4: GitOps (hub → spoke)

## Phase 4a: workload cluster ko Argo CD mein register karna + private GitOps repo

Is hisse mein s3 wale Argo CD (hub) ko do cheezein di gayin:
1. **Kahan deploy karna hai:** workload cluster `lab-workload` (s1+s2) register hua.
2. **Kya deploy karna hai:** private repo `goharch555/platform-gitops` (read-only deploy key se) jora gaya.

**Koi Application, AppProject ya ApplicationSet nahi banaya** (wo Phase 4b mein haath se hoga). Workload
cluster pe sirf `argocd cluster add` ka kaam hua.

| Script (`phase4/`) | Kahan | Kaam |
|---|---|---|
| `coredns-custom.yaml` + `coredns-lab-local.sh` | s1 → lab-mgmt | k3s CoreDNS mein `*.lab.local` naam |
| `register-cluster.sh` | s1 → dono clusters | login (prompt pe), `argocd cluster add lab-workload` |
| `repo-credentials.sh` | s1 → lab-mgmt | read-only deploy key + declarative repository Secret |
| `verify.sh` | s1 | 7 tests |

### ⚠️ Secrets (KABHI repo mein nahi)
| Secret | Jagah |
|---|---|
| Deploy key (private) | s1: `/root/argocd-repo-key/platform-gitops` (700/600, backup) + s3: Secret `argocd/repo-platform-gitops` (k3s encrypted at rest) |
| Workload cluster ki credential jo Argo CD **asal mein** use karta hai | s3: cluster Secret `argocd/cluster-k8s-api.lab.local-*` ka `config`: **`kubernetes-admin` client cert + key** (neeche ⚠️ dekho) |
| argocd-manager token (bana, lekin istemal nahi) | workload: Secret `kube-system/argocd-manager-long-lived-token` |
| Argo CD admin password | s1: `/root/argocd-admin-password` (600 root) |

---

## 1. Pods node ki `/etc/hosts` kyun nahi parhte, aur CoreDNS ka kaam

**Masla:** Phase 0 mein har node ki `/etc/hosts` mein `k8s-api.lab.local` waghera daale gaye the. Lekin
Argo CD (s3 pe pod) ko `https://k8s-api.lab.local:6443` tak pohanchna hai, aur **pod node ki `/etc/hosts`
nahi parhta**:
- Har pod ka **apna** network namespace aur **apni** `/etc/hosts` hoti hai. kubelet usay banata hai, aur us
  mein sirf `localhost` aur pod ka apna naam/IP hota hai.
- Pod ki `/etc/resolv.conf` mein `nameserver 10.43.0.10` (k3s) hota hai, yani har DNS sawal **CoreDNS** ke
  paas jata hai, node ke `systemd-resolved` ya `/etc/hosts` ke paas nahi.

**CoreDNS ka kaam:** cluster ka DNS server, jo Deployment ke tor pe chalta hai aur `Corefile` mein likhe
"plugins" ki chain chalata hai:
- `kubernetes` plugin: `svc.cluster.local` → Service IPs.
- `hosts` plugin: static naam → IP.
- `forward`: baaqi sab upstream (node ki `/etc/resolv.conf` → 192.168.2.2).

`lab.local` hamara banaya hua naam hai, jo upstream (VMware DNS) ko maloom nahi. Is liye CoreDNS ko batana pada.

**k3s ka supported tareeqa:** k3s ki apni `coredns` ConfigMap ke upar likha hai *"File managed by k3s.
DO NOT EDIT"*, kyunke k3s restart pe usay overwrite kar deta hai. Iske bajaye k3s ka Corefile
`coredns-custom` ConfigMap ki files import karta hai:
- `*.override` → **main** server block (`.:53`) ke andar
- `*.server` → **alag** server block

Main block mein pehle se aik `hosts` plugin hai (NodeHosts), aur aik block mein aik plugin **do dafa nahi**
aa sakta. Is liye `*.override` mein `hosts` likhne se Corefile toot jata. Hum ne **`lab-local.server`**
banaya: `lab.local` zone ka alag block. CoreDNS har sawal ko sab se specific zone wale block pe bhejta
hai, is liye `*.lab.local` ke sawal isi block mein aate hain aur baaqi sab pehle jaise:
```
lab.local:53 {
    errors
    cache 30
    hosts {
        192.168.2.11 k8s-api.lab.local
        192.168.2.13 argocd.lab.local
        192.168.2.14 registry.lab.local
        ttl 60
    }
}
```
ConfigMap badalne pe script `kubectl rollout restart deploy/coredns` karti hai, taake naya import pakka
load ho. CoreDNS log mein `lab.local.:53` server block dikhta hai. (`No files matching ... *.override`
WARNING normal hai, kyunke koi override file nahi.)

**Verify (script khud karti hai):**
- `argocd` namespace mein temporary busybox pod: `nslookup k8s-api.lab.local` → 192.168.2.11 (aur argocd → .13, registry → .14).
- Temporary curl pod: `curl -sk https://k8s-api.lab.local:6443/version` → `v1.37.1`. Ye sirf
  *reachability* test hai, is liye `-k`. Argo CD khud workload cluster ka CA (kubeconfig se) use karke
  poora TLS verify karta hai (`insecure: false`).
- Test pods "banao → khatam hone ka intezar → logs → delete" ke tareeqe se chalte hain. `kubectl run
  --rm -i` mein race hai: container attach se pehle khatam ho jaye to output gum ho jata hai, jo pehli
  dafa hua bhi.

**Production:** `/etc/hosts` aur CoreDNS `hosts` dono "haath ke DNS" hain: har naya naam do-teen jagah likhna
padta hai. Asal mein internal DNS server (BIND, PowerDNS, AD DNS, Route53 private zone) hota hai, aur
CoreDNS us zone ko `forward lab.local <dns-server>` se wahan bhejta hai. ([backlog](backlog.md))

**Interview sawal:** *Node pe `ping k8s-api.lab.local` chalta hai lekin pod mein nahi. Kyun?*
**Jawab:** Node `/etc/hosts` se resolve karta hai, lekin pod ki apni `/etc/hosts` aur `/etc/resolv.conf`
hoti hai jo cluster DNS (CoreDNS) pe point karti hai. CoreDNS ko ye naam nahi pata aur upstream ko bhi
nahi. Hal: CoreDNS mein `hosts`/`forward` (stub domain) add karo, ya asli DNS mein record banao. Ya pod
mein `hostAliases`, lekin wo har pod spec mein likhna padta hai.

---

## 2. `argocd cluster add` andar kya banata hai

```bash
argocd cluster add lab-workload --name lab-workload --grpc-web --yes
```
CLI s1 ke `~/.kube/config` ka context `lab-workload` (cluster-admin) use karke **workload cluster mein** ye banata hai:

| Resource (workload cluster) | Kaam |
|---|---|
| `ServiceAccount kube-system/argocd-manager` | Argo CD ki "pehchan" workload cluster mein |
| `ClusterRole argocd-manager-role` | rules: `apiGroups:* resources:* verbs:*` + `nonResourceURLs:* verbs:*`, yani **cluster-admin ke barabar** |
| `ClusterRoleBinding argocd-manager-role-binding` | role → SA |
| `Secret kube-system/argocd-manager-long-lived-token` (type `kubernetes.io/service-account-token`) | SA ka **long-lived token** (keys: `ca.crt, namespace, token`) |

Phir **s3 pe** (Argo CD ke API ke zariye) `argocd` namespace mein aik **cluster Secret** banata hai:
- naam `cluster-k8s-api.lab.local-3410317208`, label `argocd.argoproj.io/secret-type: cluster`
- keys: `name` (`lab-workload`), `server` (`https://k8s-api.lab.local:6443`), `config` (JSON)

Server URL wahi hai jo kubeconfig mein tha (`k8s-api.lab.local`), isi liye pehle CoreDNS wala kaam zaroori tha.

### ⚠️ Asal mein Argo CD kaunsi credential use kar raha hai (hamari jaanch)
Aam tor pe `config` mein argocd-manager SA ka **`bearerToken`** hota hai. Hamare cluster Secret mein (Argo CD v3.5.5)
**`bearerToken` hai hi nahi**. `config` = `tlsClientConfig: {caData, certData, keyData, insecure: false}`, aur:
- `certData` ka subject: **`O = kubeadm:cluster-admins, CN = kubernetes-admin`**, expiry **Oct 14, 2027**
- `keyData` = s1 ki kubeconfig wali `kubernetes-admin` client key (sirf sha256 hash compare kiya, key print nahi)

Yani `cluster add` ne argocd-manager SA, ClusterRole, Binding aur token **banaye**, lekin Argo CD ko kubeconfig wali
**admin ki certificate pehchan** de di. argocd-manager abhi **istemal nahi** ho raha.

**Faisla (2026-10-15): jaisa hai rehne do** (lab). Khatra wazeh rahe:
| | argocd-manager SA token (aam) | kubernetes-admin client cert (hamara) |
|---|---|---|
| Taqat | cluster-admin (ClusterRole `*/*/*`) | cluster-admin (`kubeadm:cluster-admins` group) |
| Wapas lena (revoke) | SA/Secret delete → **foran** band | Kubernetes client certs **revoke nahi kar sakta**: **Oct 14, 2027 tak** valid |
| Audit logs mein | `system:serviceaccount:kube-system:argocd-manager` (Argo CD alag pehchana jata) | `kubernetes-admin` (insaan admin aur Argo CD mein farq nahi) |
| Key kahan | workload `kube-system` | s3 k3s datastore (encrypted at rest) + s1 kubeconfig |

Agar ye cert leak ho jaye to usay band karne ke tareeqe: `kubeadm:cluster-admins` group ki ClusterRoleBinding hatana
(sab admin certs band) ya cluster CA rotate karna, dono mehnge hain. Isi liye production mein Argo CD ko hamesha
**alag, revoke ho sakne wali** pehchan (SA token, ya behtar: kam-umr exec/IAM credentials) di jati hai.
Badalne ka tareeqa [backlog](backlog.md) mein hai. `verify.sh` (test 4) har dafa credential ki **qism** (token/cert
aur cert ka subject) report karta hai, value nahi.

**Status "Unknown":** `cluster add` ke foran baad connection test hua aur status **Successful** aaya.
Kuch der baad `argocd cluster list` ne **Unknown** dikhaya: *"Cluster has no applications and is not
being monitored."* Argo CD sirf un clusters ko continuously monitor karta hai jin pe koi Application
ho. Ye normal hai, aur Phase 4b mein Application aane pe Successful ho jayega.

### argocd-manager ko cluster-admin dena (aur production option)
- **Kyun cluster-admin:** Argo CD ko pehle se maloom nahi ke git mein kaun se resources honge (CRDs,
  Namespaces, ClusterRoles...), is liye default sab kuch deta hai.
- **Khatra:** Argo CD ki workload credential (hamare case mein `kubernetes-admin` cert, upar ⚠️) = poore workload
  cluster ka **root**, aur ye s3 pe (k3s Secret, encrypted at rest) rakhi hai. Hub compromise ho to har spoke compromise ho jata hai. Ye
  hub-and-spoke ka "blast radius" ka doosra rukh hai.
- **Production mein scoped permissions:**
  1. `argocd cluster add ... --namespace <ns1> --namespace <ns2>`: Argo CD sirf in namespaces mein Role/RoleBinding
     ke saath kaam karta hai (cluster-scoped resources nahi).
  2. Ya `--service-account <apna-SA>`: khud likha ClusterRole (misal sirf `apps`, `""` core resources, apne CRDs;
     `secrets`, `rbac`, `nodes` pe sakhti).
  3. AppProject mein `clusterResourceWhitelist` / `namespaceResourceWhitelist` se bhi rok-tok (Argo CD ki taraf).
  4. Long-lived token ki jagah kam-umr credentials (cloud IAM / exec plugin) aur rotation.
- Lab mein abhi default rakha. Scoped karna [backlog](backlog.md) mein hai.

**Verify:**
```bash
argocd cluster list --grpc-web
argocd cluster get lab-workload --grpc-web -o json | jq '{server,name,insecure:.config.tlsClientConfig.insecure,connection:.connectionState.status}'
kubectl --context lab-workload -n kube-system get sa argocd-manager
kubectl --context lab-workload get clusterrole argocd-manager-role -o yaml
kubectl --context lab-mgmt -n argocd get secret -l argocd.argoproj.io/secret-type=cluster   # values mat dekho
```

**Interview sawal 2:** *Kubernetes client certificate ko "revoke" kyun nahi kar sakte?*
**Jawab:** Kubernetes API server client certs ke liye CRL/OCSP check nahi karta. Jo bhi cert cluster CA se
signed ho aur expire na hua ho, wo valid hai. Band karne ke liye ya to us cert ke user/group ki RBAC bindings
hatao, ya CA rotate karo (saare certs dobara). Isi liye automation ko revoke ho sakne wale SA tokens ya
kam-umr credentials dete hain, aur admin certs ko kam-umr rakhte hain.

**Interview sawal:** *`argocd cluster add` kya karta hai, aur iske security nataij kya hain?*
**Jawab:** Target cluster mein `argocd-manager` ServiceAccount, cluster-wide admin ClusterRole/Binding aur
long-lived token Secret banata hai, phir woh token aur CA Argo CD ke namespace mein cluster Secret ke
tor pe rakhta hai. Nateeja: Argo CD (hub) ke paas spoke ka cluster-admin hai, aur hub compromise ka matlab
har spoke compromise. Production mein `--namespace` ya custom ServiceAccount se permissions scoped
karte hain, AppProject whitelists lagate hain, aur tokens rotate karte hain.

---

## 3. Private repo aur read-only deploy key

**Kya kiya:**
1. s1 pe nayi **ED25519** key `/root/argocd-repo-key/platform-gitops` (folder 700, file 600). Sirf iski
   **public** half GitHub pe `platform-gitops` ki **Deploy key** ke tor pe lagayi gayi, "Allow write access" **OFF**.
2. **Fingerprint match:** deploy key se `ssh -T git@github.com` karne pe GitHub ne
   *"Hi goharch555/platform-gitops!"* kaha. Yani GitHub ne key ko isi repo ki deploy key pehchana
   (`SHA256:4lprFymA9r95YalPGDiSAAlz7w0rnUsCQgzCOnrC2bU`).
3. **Read-only ka asal test:** deploy key se nayi branch `readonly-test` push ki koshish →
   *"ERROR: The key you are authenticating with has been marked as read only."* Push mana, aur koi branch nahi bani.
   - **Sabaq:** pehli dafa key **Read/write** lagi thi. Be-zarar test (mojood na hone wali branch delete
     karne ki koshish) GitHub ne *qubool* kar liya tha, aur usi se pata chala. Key delete karke read-only
     dobara lagane ke baad wohi test bhi "read only" pe ruk gaya. Yani "UI mein checkbox dekh liya" kaafi
     nahi; **asal push test** hi saboot hai. Ye test `verify.sh` (test 6) mein hamesha chalta hai; push kabhi
     kamyab ho to branch foran account key se delete hoti hai aur test FAIL hota hai.
4. **Known hosts:** Argo CD ke `argocd-ssh-known-hosts-cm` mein `github.com` ki 3 host keys (ecdsa,
   ed25519, rsa) hain, aur script unhein GitHub ki **published** keys (`api.github.com/meta`) se milati hai.
   Isse "beech mein nakli GitHub" (MITM) ka rasta band hota hai. Na mile to script ruk jati hai.
5. **Declarative repository Secret** (s3, `argocd` namespace):
   ```yaml
   metadata:
     name: repo-platform-gitops
     labels:
       argocd.argoproj.io/secret-type: repository
   stringData:
     type: git
     name: platform-gitops
     url: git@github.com:goharch555/platform-gitops.git
     sshPrivateKey: <file se, stdin ke zariye — command line / output mein kabhi nahi>
   ```
   `sudo cat key | kubectl create secret generic ... --from-file=sshPrivateKey=/dev/stdin --dry-run=client -o yaml | kubectl label --local ... | kubectl apply -f -`
6. `argocd repo list` → **STATUS Successful**.

### Read-only deploy key aur least privilege
- **Deploy key** sirf **aik repo** ke liye hoti hai, kisi user account se juri nahi hoti. Leak ho to sirf wahi repo khatre mein.
- **Read-only:** Argo CD sirf git **parhta** hai (desired state). Use likhne ki kabhi zaroorat nahi. Agar s3 ya
  Secret leak ho aur key read/write ho, to attacker git mein **apni** manifests daal sakta hai, aur Argo CD
  khud unhein cluster pe laga dega. GitOps mein git = cluster ka control, is liye write access ka matlab
  cluster-admin tak pohanch hai.
- **Least privilege:** har cheez ko sirf utni ijazat jitni uske kaam ke liye zaroori ho. Yahan: aik repo,
  sirf read, aik key sirf Argo CD ke liye (insaan ki key alag).
- **Rotation:** nayi key banao → GitHub pe add (read-only) → Secret update → `repo list` Successful → purani
  key GitHub se delete. ([backlog](backlog.md))

### Cluster Secret aur repository Secret declarative kyun
- **Declarative** ka matlab hai ke Argo CD ki configuration (clusters, repos) **Kubernetes Secrets/ConfigMaps
  ki shakal** mein hai, jinhein labels se pehchana jata hai (`secret-type: cluster` / `repository`).
  UI ya CLI mein "click" karke nahi.
- **Faide:** (1) Argo CD dobara install karo to wahi Secrets lagao, aur sab wapas. (2) Ye manifests khud GitOps
  se manage ho sakte hain ("app of apps" / Argo CD khud ko manage kare). (3) Review, audit aur backup asaan.
- **Lekin** Secret mein private key/token hota hai, is liye plain YAML **git mein nahi** jata. Is ke liye
  Sealed Secrets / External Secrets (Phase 5).
- `argocd cluster add` CLI se hua, lekin nateeja bhi aik **declarative cluster Secret** hi hai.

**Verify:**
```bash
argocd repo list --grpc-web                         # STATUS Successful
kubectl --context lab-mgmt -n argocd get secret repo-platform-gitops -o json | jq '.metadata.labels, (.data|keys)'
bash ~/lab-infra/phase4/verify.sh                   # test 6: asal read-only push test
```

**Interview sawal 1:** *Argo CD ko private git repo ki access kaise doge, aur kis cheez ka khayal rakhoge?*
**Jawab:** Read-only deploy key (ya kam-ikhtiyar token/GitHub App) banao, Argo CD mein declarative repository
Secret (label `argocd.argoproj.io/secret-type: repository`) ke tor pe do, aur SSH host key `known_hosts` mein
verify karo. Write access kabhi nahi, kyunke GitOps mein git likhne ka matlab cluster pe kuch bhi lagana hai.
Key rotate karo aur Secret git mein plain mat rakho.

**Interview sawal 2:** *Deploy key aur personal SSH key mein kya fark hai?*
**Jawab:** Personal key user ke **saare** repos (aur uske haq) tak pohanchti hai. Deploy key sirf **aik** repo
ke liye hoti hai aur read-only ho sakti hai. Machines/automation ke liye deploy key (ya GitHub App) behtar
hai; least privilege.

---

## 4. `lab-infra` vs `platform-gitops`

| | **lab-infra** (public) | **platform-gitops** (private) |
|---|---|---|
| Kya hai | Machines aur clusters **banane** ki scripts (IaC): Phase 0–4 | Cluster ke **andar** kya chalna chahiye: Argo CD ki desired state |
| Kaun chalata hai | Insaan (s1 se scripts) | **Argo CD** (khud, continuously sync) |
| Kaun likhta hai | gohar (account key) | gohar (account key); Argo CD sirf **parhta** hai (read-only deploy key) |
| Tabdeeli kaise | Script chalao | Git commit/PR → Argo CD sync |
| Secrets | Kabhi nahi (public) | Plain kabhi nahi; Phase 5 se sirf **sealed** (encrypted) |
| Misal | `phase1/init-control-plane.sh`, `phase3/argocd/values.yaml` | Phase 4b se: AppProject, Applications, app manifests |

Alag repos kyun: (1) **Access alag:** infra repo public hai (seekhne/dikhane ke liye), aur desired state
private. (2) **Kaam alag:** bootstrap aik dafa ka hai, desired state roz badalti hai. (3) **Argo CD ko sirf
woh repo dikhe jo usay chahiye** (least privilege).

---

## 5. `verify.sh`: 7 tests (nateeja)

| # | Test | Nateeja |
|---|---|---|
| 1 | CoreDNS lab.local (pod se DNS + workload API) | ✅ k8s-api → 192.168.2.11, argocd → .13, registry → .14; `/version` → v1.37.1 |
| 2 | argocd login (stored password, prompt pe) | ✅ |
| 3 | `argocd cluster get lab-workload` | ✅ `https://k8s-api.lab.local:6443`, `insecure: false`, status **Unknown** (koi Application nahi, normal) |
| 4 | Workload: argocd-manager SA/ClusterRole/Binding/token | ✅ (lekin Argo CD ki asal credential: `kubernetes-admin` client cert. Test isay report karta hai) |
| 5 | `argocd repo list` | ✅ platform-gitops **Successful** |
| 6 | Deploy key se push `readonly-test` | ✅ mana: *"marked as read only"* |
| 7 | Application/AppProject/ApplicationSet | ✅ 0 / sirf `default` / 0 |

---

## 6. Raaste mein seekha
1. **`*.override` vs `*.server`:** aik server block mein aik plugin aik hi dafa aa sakta hai. k3s ke block mein
   `hosts` pehle se hai, is liye alag zone block.
2. **Log filter:** `[INFO] plugin/reload` ko error samajhna ghalat tha. Sirf `[ERROR]/[FATAL]` aur parsing errors pakdo.
3. **`kubectl run --rm -i` race:** container jaldi khatam ho to output gum ho jata hai. Pod → wait → logs → delete.
4. **`sudo` + `<(...)`:** process substitution ka fd root ke process tak nahi pohanchta. sudo ke saath temp file use karo.
5. **Read-only ko asal push se sabit karo:** pehli dafa key read/write thi. Be-zarar test ne pakda, aur asal
   push test ne tasdeeq ki.
6. **`cmd | grep -q` + `pipefail`** ne verify mein phir ghalat FAIL diya (Phase 1 wala hi masla). Pehle output
   variable mein, phir grep.

## Kaise chalayein
```bash
cd ~/lab-infra/phase4
bash coredns-lab-local.sh
bash register-cluster.sh
bash repo-credentials.sh                    # key + public key dikhati hai → GitHub pe read-only deploy key
bash repo-credentials.sh --deploy-key-added # repository Secret + verify
bash verify.sh
```
