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
| `use-sa-token.sh` | s1 → dono clusters | cluster Secret: admin cert → argocd-manager SA token (server-side apply) |
| `repo-credentials.sh` | s1 → lab-mgmt | read-only deploy key + declarative repository Secret |
| `verify.sh` | s1 | 7 tests |

### ⚠️ Secrets (KABHI repo mein nahi)
| Secret | Jagah |
|---|---|
| Deploy key (private) | s1: `/root/argocd-repo-key/platform-gitops` (700/600, backup) + s3: Secret `argocd/repo-platform-gitops` (k3s encrypted at rest) |
| Workload cluster ki credential jo Argo CD use karta hai | s3: cluster Secret `argocd/cluster-k8s-api.lab.local-*` ka `config`: **argocd-manager SA token** (`bearerToken`) + CA (§2a) |
| argocd-manager token (asal) | workload: Secret `kube-system/argocd-manager-long-lived-token` |
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

## 2a. Argo CD ki credential: admin cert → argocd-manager token (fix)

### Kya hua tha
`cluster add` ke baad cluster Secret ke `config` mein **`bearerToken` tha hi nahi**. `config` =
`tlsClientConfig: {caData, certData, keyData}`, aur `certData` = **`O=kubeadm:cluster-admins, CN=kubernetes-admin`**
(s1 ki kubeconfig wali admin key, sha256 se match). Yani argocd-manager SA ban gaya, lekin Argo CD **admin ki
pehchan** se ja raha tha.

### Kyun (Argo CD v3.5.5 ka source code)
`cmd/argocd/commands/cluster.go`: `cluster add` pehle `clusterauth.InstallClusterManagerRBAC()` se argocd-manager
SA + ClusterRole/Binding + token **banata** hai aur token wapas leta hai. Phir `cmd/util/cluster.go` ka `NewCluster()`
kubeconfig context ki TLS config copy karta hai (CA, **cert, key**) aur:
```go
// Bearer token will preferentially be used for auth if present,
// Even in presence of key/cert credentials
// So set bearer token only if the key/cert data is absent
if len(tlsClientConfig.CertData) == 0 || len(tlsClientConfig.KeyData) == 0 {
    clst.Config.BearerToken = managerBearerToken
}
```
kubeadm ki `admin.conf` **client-certificate** se login karti hai, is liye cert/key mojood the aur token **phenk diya gaya**.
Ye koi flag ya bhool nahi, v3.5.5 ka design hai. Token wali kubeconfig (ya `--exec-command`) hoti to token rakha jata.
**Sabaq:** `argocd cluster add` ke baad hamesha check karo ke Secret mein asal mein kaunsi credential hai.

### Fix (`phase4/use-sa-token.sh`)
1. Workload cluster se `kube-system/argocd-manager-long-lived-token` ke `token` aur `ca.crt` liye, **sirf pipe se**:
   `kubectl get secret (dono) -o json | jq -s '…' | kubectl apply --server-side -f -`. Token/CA kabhi print
   ya file mein nahi gaye.
2. Cluster Secret ki **sirf `config`** key badli, aur `server`/`name`/labels wahi rahe:
   `{"bearerToken": "<token>", "tlsClientConfig": {"insecure": false, "caData": "<base64 CA>"}}`
3. **Server-side apply** (`--field-manager=lab-infra-phase4 --force-conflicts`), client-side nahi. Client-side
   `kubectl apply` poori object (token samet) `kubectl.kubernetes.io/last-applied-configuration` annotation mein bhi
   likh deta hai. Argo CD cluster Secret ki annotations `argocd cluster get` mein dikhata hai, aur `kubectl describe`
   bhi annotations dikhata hai.
4. Idempotent: token aur CA SA Secret se match karein (sirf compare) aur cert/key na hon, to kuch nahi badalta.

### Verify (asal nateeja)
- Cluster Secret `config` ki keys: **`["bearerToken","tlsClientConfig"]`**, `tlsClientConfig`: **`["caData","insecure"]`**.
  **`certData`/`keyData` nahi.** Token = SA token, CA = SA ka `ca.crt` (sirf compare kiya).
- **Pehchan ka saboot (TokenReview):** Secret wala token pipe se workload cluster ki TokenReview API ko diya:
  `authenticated: true`, `username: system:serviceaccount:kube-system:argocd-manager`. (Sirf `.status` dikhaya,
  kyunke TokenReview ka jawab `spec.token` wapas bhejta hai.)
- `argocd cluster set lab-workload --name lab-workload`: Argo CD server **Secret wali credential** se workload API
  call karta hai (`GetServerVersion`, source: *"Test the token we just created before persisting it"*) → **Successful**,
  `insecure: false`, v1.37.1. ⚠️ Ye check `/version` pe hai, jo kubeadm cluster pe bina login ke bhi khulta hai.
  Isi liye pehchan ka asal saboot TokenReview hai. Kuch der baad status phir **Unknown** ho gaya, kyunke koi
  Application nahi aur Argo CD cluster ko monitor nahi karta.
- `kubectl --context lab-workload auth can-i --list --as=system:serviceaccount:kube-system:argocd-manager`:
  `*.* [*]` aur non-resource `[*]`, yani cluster-admin. Ye permissions abhi nahi badlin ([backlog](backlog.md)).
- `argocd cluster get` ka text "oAuth authentication: false" dikhata hai, kyunke Argo CD API apne jawab mein token
  chhupa deti hai. Ye display ki baat hai.
- `verify.sh` test 4: credential client cert ho to **FAIL**. Bearer token ho to TokenReview se user
  `argocd-manager` hona chahiye.

### ⚠️ Purana admin certificate abhi bhi VALID hai
Cert ki copy s3 ke Secret se **hat gayi**, lekin certificate khud **Oct 14, 2027 tak valid** hai, aur Kubernetes
client certificates ko **revoke nahi kar sakta**. Jab tak wo Secret mein tha, s3 compromise ka matlab workload
cluster ka admin cert leak ho sakta tha. k3s datastore ke purane snapshots/backups mein bhi (agar banaye gaye hon)
wo ho sakta hai. Asli hal **cluster CA rotation** hai (saare certs dobara). Ye abhi nahi kiya, [backlog](backlog.md) mein hai.

### SA token vs client certificate (aur audit identity)
| | **SA token** (ab) | **Client certificate** (pehle) |
|---|---|---|
| Pehchan | `system:serviceaccount:kube-system:argocd-manager`: **sirf Argo CD** | `kubernetes-admin` (`kubeadm:cluster-admins`): **insaan admin jaisi** |
| Audit log | Har request pe saaf ke Argo CD ne kiya | Argo CD aur insaan admin **aik jaise** |
| Band karna | SA ya token Secret delete → **foran** | **Revoke nahi** hota: RBAC binding hatao ya CA rotate karo |
| Taqat | ClusterRole se tay; scoped ho sakti hai | Group (`kubeadm:cluster-admins`) = cluster-admin |
| Umr | Long-lived token (rotation khud karni padti hai) | Cert ki expiry tak (1 saal) |

Behtar: **kam-umr** credentials (exec plugin/IAM, ya `TokenRequest` se time-bound tokens) aur scoped permissions.

**Interview sawal 1:** *Kubernetes client certificate revoke kyun nahi hota?*
**Jawab:** API server client certs ke liye CRL ya OCSP check nahi karta. Jo cert cluster CA se signed ho aur
expire na hua ho, wo valid hai. Band karne ke liye us user/group ki RBAC bindings hatao (agar wo kisi system group,
jaise `system:masters`, mein na ho), ya CA rotate karo. Isi liye admin certs kam-umr rakhte hain aur automation ko
SA tokens ya kam-umr credentials dete hain.

**Interview sawal 2:** *Automation (Argo CD) ko cluster access ke liye SA token kyun dein, admin ka kubeconfig kyun nahi?*
**Jawab:** (1) **Audit:** logs mein `system:serviceaccount:...:argocd-manager` dikhta hai, aur insaan aur machine
alag pehchane jate hain. (2) **Revocation:** SA ya token delete karke foran band. (3) **Least privilege:** SA ko
ClusterRole se scoped permissions di ja sakti hain. (4) Insaan ka admin cert machines mein phailana blast radius barhata hai.

**Interview sawal 3:** *Audit log mein "kisne kiya" kaise pata chalta hai?*
**Jawab:** Har API request ka authenticated **user** (aur groups) audit event mein likha jata hai: SA ke liye
`system:serviceaccount:<ns>:<name>`, cert ke liye uska CN. Agar sab tools aur log aik hi identity (misal
`kubernetes-admin`) use karein to audit bekaar ho jata hai. Har actor ki alag pehchan zaroori hai.

### argocd-manager ko cluster-admin dena (aur production option)
- **Kyun cluster-admin:** Argo CD ko pehle se maloom nahi ke git mein kaun se resources honge (CRDs,
  Namespaces, ClusterRoles...), is liye default sab kuch deta hai.
- **Khatra:** Argo CD ki workload credential (ab argocd-manager token, §2a) = poore workload cluster ka **root**, aur ye
  s3 pe (k3s Secret, encrypted at rest) rakhi hai. Hub compromise ho to har spoke compromise ho jata hai. Ye
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

## 5. `verify.sh`: tests (nateeja: 9 checks, sab PASS)

| # | Test | Nateeja |
|---|---|---|
| 1 | CoreDNS lab.local (pod se DNS + workload API) | ✅ k8s-api → 192.168.2.11, argocd → .13, registry → .14; `/version` → v1.37.1 |
| 2 | argocd login (stored password, prompt pe) | ✅ |
| 3 | `argocd cluster get lab-workload` | ✅ `https://k8s-api.lab.local:6443`, `insecure: false`, status **Unknown** (koi Application nahi, normal) |
| 4 | Workload: argocd-manager SA/ClusterRole/Binding/token | ✅ |
| 4b | Argo CD credential = bearer token, TokenReview → `argocd-manager` (cert mile to FAIL) | ✅ |
| 4c | `argocd` namespace ke kisi Secret pe `last-applied-configuration` annotation nahi | ✅ |
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
7. **`argocd cluster add` ka nateeja check karo:** kubeconfig cert-based ho to v3.5.5 SA token nahi rakhta (§2a).
8. **Secrets aur `kubectl apply` (client-side):** `last-applied-configuration` annotation mein poori object, keys
   samet, copy ho jati hai. Hamare `repo-platform-gitops` (sshPrivateKey) aur Phase 3 ke `argocd-server-tls`
   (tls.key) pe yahi tha. Dono scripts (`phase4/repo-credentials.sh`, `phase3/argocd-install.sh`) ab **server-side
   apply** use karti hain. Server-side apply pe jaate hi purani annotation khud hat gayi; scripts mein hatane ka
   fallback bhi hai. Secrets ke liye hamesha `--server-side` (ya `create`/`replace`).

## Kaise chalayein
```bash
cd ~/lab-infra/phase4
bash coredns-lab-local.sh
bash register-cluster.sh
bash use-sa-token.sh                        # admin cert → argocd-manager token (cluster add ke baad zaroori)
bash repo-credentials.sh                    # key + public key dikhati hai → GitHub pe read-only deploy key
bash repo-credentials.sh --deploy-key-added # repository Secret + verify
bash verify.sh
```
