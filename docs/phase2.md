# Phase 2: s4 pe secure container registry (`registry.lab.local`)

Is phase mein s4 pe apni **private container registry** banayi gayi, jo TLS (apne Lab CA se) aur
password auth ke saath chalti hai. s1 aur s2 (Kubernetes) ko sirf CA pe trust aur containerd ki registry
config di gayi. **CI runner abhi NAHI** (baad ka phase). s3 ko nahi chheda gaya.

| Cheez | Value |
|---|---|
| Registry | `registry.lab.local` → 192.168.2.14 (s4), port **443** (HTTPS) |
| Image | distribution `registry:3.1.2` (tag + digest pinned) |
| TLS | Server cert **Lab Root CA** se signed (ECDSA P-256), SAN `DNS:registry.lab.local, IP:192.168.2.14`, 1 saal |
| Auth | htpasswd (bcrypt, cost 12): `ci-push`, `k8s-pull` |
| Docker CE (s4) | docker-ce 29.9.1, containerd.io 2.4.2, buildx 0.38.0, compose 5.6.0 (sab held) |
| Public CA cert (repo) | [`pki/lab-root-ca.crt`](../pki/lab-root-ca.crt) |

**Scripts** (`phase2/`, sab idempotent):

| # | Script | Kahan | Kaam |
|---|---|---|---|
| 1 | `lab-ca.sh` | s4 (root) | Lab Root CA + registry ka server cert |
| 2 | `docker.sh` | s4 (root) | Docker CE pinned + hold, gohar → docker group |
| 3 | `registry.sh` | s4 (root) | passwords, htpasswd, http secret, certs, `docker compose up` |
| 4 | `trust-ca.sh <ca.crt>` | s4, s1, s2 (root) | OS trust + Docker certs.d / containerd hosts.toml |
| 5 | `verify.sh` | s1 (gohar) | 5 tests |

Repo mein [`phase2/registry/compose.yaml`](../phase2/registry/compose.yaml) aur
[`config.yml`](../phase2/registry/config.yml) hain, **bina kisi secret ke**.

### ⚠️ Secrets kahan hain (aur kahan KABHI nahi)
| Secret | Jagah (sirf s4) | Repo mein? |
|---|---|---|
| CA private key | `/root/lab-ca/ca.key` (folder 700, file 600) | ❌ kabhi nahi, kisi aur node pe bhi nahi |
| Server private key | `/root/lab-ca/registry.lab.local.key`, `/srv/registry/certs/registry.key` (600) | ❌ |
| Users ke passwords | `/root/registry-credentials/{ci-push,k8s-pull}.password` (600) | ❌ (docs/report mein bhi nahi) |
| http secret | `/root/registry-credentials/http-secret` → `/srv/registry/registry.env` (600) | ❌ |
| htpasswd file | `/srv/registry/auth/htpasswd` (600) | ❌ |
| docker login | `~/.docker/config.json` (test ke baad logout) | ❌ |
| **CA certificate (public)** | `pki/lab-root-ca.crt` | ✅ public hai; ye secret nahi |

`.gitignore` in sab patterns (`*.key`, `*.csr`, `*.srl`, `htpasswd`, `*.password`, `registry.env`,
`.docker/`) ko rokta hai. Commit se pehle `git diff --cached` khud check kiya jata hai.

---

## 1. TLS aur CA kaise kaam karte hain (bunyaad)

### TLS kya deta hai
1. **Encryption**: beech mein koi traffic parh na sake (image layers, aur passwords bhi, kyunke
   Basic auth sirf base64 hai).
2. **Server ki pehchan (authentication)**: client ko pakka pata ho ke wo *asli*
   `registry.lab.local` se baat kar raha hai, kisi nakli server se nahi.

Doosra point **certificate** se hota hai. Certificate ka matlab hai: *"Is public key ka maalik
`registry.lab.local` hai"*, aur is baat pe kisi bharose wale (**CA**) ke dastakhat (signature) hote hain.

### Chain of trust
```
Lab Root CA  (self-signed; har node ke trust store mein daala gaya)
   │  signs (CA ki private key se)
   ▼
registry.lab.local  (server certificate; registry TLS handshake mein bhejti hai)
```
Client (curl, docker, containerd) ye check karta hai:
1. Server ka certificate kis ne sign kiya? → "Lab Root CA".
2. Kya "Lab Root CA" mere **trust store** mein hai? → haan (`trust-ca.sh` ne daala).
3. Signature sahi hai? (CA ki **public** key se check) → haan.
4. Certificate expire to nahi hua, aur **jis naam se main connect hua wo certificate ke SAN mein hai?**
5. Server ke paas certificate ki **private key** hai? (handshake mein sabit hota hai)

Sab sahi → `Verify return code: 0 (ok)`. Agar CA trust store mein na ho → *"x509: certificate signed
by unknown authority"*.

**CA ki private key hi sab kuch hai:** jis ke paas ye ho wo **koi bhi** naam (misal `github.com`) ka
certificate bana sakta hai, aur hamare nodes us pe bharosa kar lenge. Isi liye `ca.key` sirf s4 ke
`/root/lab-ca/` (700/600) mein hai, kabhi repo ya kisi aur machine pe nahi. CA ki public certificate
(`ca.crt`) **bilkul public** hai; usay har node ko dena hi hota hai.

### SAN (Subject Alternative Name) kya hai
- Certificate mein wo **naam/IPs** jin ke liye ye valid hai: `DNS:registry.lab.local, IP:192.168.2.14`.
- Client **wohi naam** match karta hai jo usne URL mein likha. `https://registry.lab.local` → SAN mein
  `registry.lab.local` hona chahiye. `https://192.168.2.14` → SAN mein `IP:192.168.2.14` hona chahiye.
- Purana tareeqa naam ko `CN` (Common Name) mein rakhta tha. Aaj kal clients (Go, Chrome) **sirf SAN**
  dekhte hain, CN nahi. Is liye SAN zaroori hai.

### Hamare certificates ki extensions (kyun)
| Certificate | Extension | Matlab |
|---|---|---|
| Root CA | `basicConstraints=critical,CA:TRUE,pathlen:0` | Ye CA hai, lekin iske neeche koi aur CA nahi ban sakta (sirf end certificates) |
| Root CA | `keyUsage=critical,keyCertSign,cRLSign` | Sirf certificates aur CRL sign kar sakta hai, server ke tor pe use nahi ho sakta |
| Server | `basicConstraints=critical,CA:FALSE` | Ye CA nahi; isse aage certificates sign nahi ho sakte |
| Server | `keyUsage=critical,digitalSignature` | ECDSA key se handshake sign karna |
| Server | `extendedKeyUsage=serverAuth` | Sirf **server** ke tor pe valid (client cert ya code signing ke liye nahi) |
| Server | `subjectAltName` | Upar dekho |

- **ECDSA P-256:** RSA 4096 jitni ya us se zyada mazboot, lekin chhoti keys aur tez handshake.
- **Root 10 saal, server 1 saal:** Root ko badalna mehnga hai (har node pe dobara trust dena padta hai).
  Server cert chhota rakhte hain taake key leak ho to nuqsaan mehdood rahe. `lab-ca.sh` server cert
  **30 din pehle** khud dobara bana deti hai (dobara chalane pe), lekin root ko kabhi khud nahi badalti.

### `skip_verify` / `insecure-registries` kyun bura hai
- Ye TLS ka **doosra** faida (server ki pehchan) band kar deta hai. Encryption to rehti hai, lekin
  client **kisi bhi** server se baat kar leta hai. Beech mein baitha attacker (ARP/DNS spoofing) apna
  certificate dikha kar:
  - `k8s-pull` / `ci-push` ka **password** le sakta hai (Basic auth har request mein jata hai),
  - aur hamare nodes ko **apni malicious image** de sakta hai, jo cluster mein root jaisa nuqsaan kar sakti hai.
- Isi liye kisi node pe `skip_verify` ya Docker `insecure-registries` nahi hai. `trust-ca.sh` mile to **fail** karti hai.

**Verify:**
```bash
openssl x509 -in pki/lab-root-ca.crt -noout -subject -dates -fingerprint -sha256
echo | openssl s_client -connect registry.lab.local:443 -servername registry.lab.local \
  -verify_hostname registry.lab.local -CApath /etc/ssl/certs 2>&1 | grep -E "depth|Verify return"
sudo openssl verify -CAfile /root/lab-ca/ca.crt /root/lab-ca/registry.lab.local.crt   # s4
```

**Interview sawal 1:** *"x509: certificate signed by unknown authority" ka matlab kya hai aur theek kaise karoge?*
**Jawab:** Server ka certificate jis CA ne sign kiya wo client ke trust store mein nahi hai. Sahi fix:
CA ka **public** certificate client pe trust karwao (Ubuntu: `/usr/local/share/ca-certificates/` +
`update-ca-certificates`; containerd: `hosts.toml` mein `ca`; Docker: `/etc/docker/certs.d/<host>/ca.crt`).
Ghalat fix: `skip_verify`/`--insecure`, kyunke us se server ki pehchan ka check hi khatam ho jata hai.

**Interview sawal 2:** *Certificate mein CN aur SAN mein kya fark hai?*
**Jawab:** CN purana field hai jis mein aik naam hota tha. SAN extension mein kai DNS naam aur IPs ho
sakte hain, aur modern clients hostname sirf SAN se match karte hain. SAN na ho to certificate
reject ho jata hai, chahe CN sahi ho.

---

## 2. `lab-ca.sh`: Lab Root CA + server certificate (s4)

**Kya kiya:**
1. `/root/lab-ca/` (700) banaya. Script `umask 077` mein chalti hai, is liye har nayi file sirf root parh sakta hai.
2. **Root CA** (sirf agar pehle se na ho): ECDSA P-256 key → self-signed cert, 3650 din,
   `CN=Lab Root CA, O=lab-infra`, upar wali extensions ke saath.
3. **Server cert:** nayi key → CSR → CA se sign (365 din, SAN, serverAuth). Ye dobara tab hi banta hai
   jab: file na ho, CA se verify na ho, SAN mukhtalif ho, ya 30 din se kam bache hon.
4. Verify: `openssl verify -CAfile ca.crt server.crt`, EKU, aur permissions.
5. Public `ca.crt` repo mein `pki/lab-root-ca.crt` ke naam se copy kiya (check kiya ke us mein `PRIVATE KEY` nahi).

**Production ahmiyat:** Production mein root CA aam tor pe **offline** hoti hai (HSM ya band machine),
aur roz ka kaam aik **intermediate CA** karti hai. Lab mein aik hi root CA kaafi hai, lekin key ki
hifazat ka usool wohi hai. Server certs ki renewal automate hoti hai (cert-manager, ACME), aur expiry pe
alert lagta hai.

**Interview sawal:** *Apni CA ki private key leak ho jaye to kya karoge?*
**Jawab:** Wo CA ab bharose ke qabil nahi. Attacker kisi bhi naam ka valid certificate bana sakta hai.
Nayi CA banao, saare server certs dobara issue karo, har client ke trust store se purani CA **hatao**
aur nayi daalo, aur leak ki wajah dhoondo. Isi liye root key offline aur kam jagah pe rakhte hain.

---

## 3. `docker.sh`: Docker CE (sirf s4)

**Kya kiya:** Docker ki official apt repo (GPG fingerprint verify, `signed-by`) se `docker-ce`,
`docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` exact versions
install kiye, sab pe `apt-mark hold` lagaya, aur `gohar` ko `docker` group mein daala.

**Kyun:** Registry ko `docker compose` se chalana hai, aur aage CI runner (image build/push) bhi s4 pe
hoga. Kubernetes nodes (s1/s2) pe Docker **nahi** hai, wahan sirf containerd hai.

### ⚠️ `docker` group = root ke barabar
- `docker` group ka member Docker daemon (`/var/run/docker.sock`) se baat kar sakta hai, aur daemon
  **root** ke tor pe chalta hai. Is liye:
  ```bash
  docker run --rm -it -v /:/host alpine chroot /host   # ← s4 ka root shell, bina sudo password ke
  ```
  Yani `docker` group mein daalna = **bina password ke root** dena. Koi bhi process jo `gohar` ke tor pe
  chale (misal compromised script) wo poori machine le sakta hai.
- **Isay kam kaise karte hain:** sirf zaroori logon/service accounts ko group mein rakho. Rootless Docker
  ya Podman (daemon user ke tor pe) use karo. CI ke liye kaniko/buildah jaise daemon-less builders.
  Docker socket ko kabhi container mein mount mat karo (`-v /var/run/docker.sock:...`), kyunke wo bhi root hai.
- Hamare lab mein `gohar` ke paas pehle se `NOPASSWD` sudo hai, is liye risk naya nahi, lekin
  production mein ye faisla soch kar hota hai.

**Verify:** `docker version`, `docker compose version`, `apt-mark showhold`, `id gohar`.

**Interview sawal:** *Kisi user ko `docker` group mein daalna security ke liye khatarnak kyun hai?*
**Jawab:** Docker daemon root se chalta hai aur group member usay kuch bhi chalane ko keh sakta hai,
misal host ka `/` mount kar ke `chroot`. Ye amalan bina password root access hai. Is liye ye group
sudo jitni ehtiyaat maangta hai, ya rootless runtime use karte hain.

---

## 4. `registry.sh` + `compose.yaml` + `config.yml`: registry (s4)

**Kya kiya:**
1. `apache2-utils` (sirf `htpasswd` tool ke liye; registry v3 image mein ye nahi hai).
2. `/srv/registry/{certs,auth}` (700), `data/` (755), `/root/registry-credentials/` (700).
3. **Passwords** `openssl rand` se (~44 random characters), sirf **pehli dafa**, 600 permission. Script
   inhein kabhi print nahi karti.
4. **htpasswd** (bcrypt, cost 12): password `-i` se **stdin** pe diya jata hai (command line pe nahi,
   warna `ps` mein dikhta). Dobara chalane pe har user ka password `htpasswd -v` se verify hota hai.
   Sab theek ho to file nahi badalti. (bcrypt har dafa naya salt leta hai, is liye file ka text compare
   nahi ho sakta.)
5. **http secret** (`REGISTRY_HTTP_SECRET`) `registry.env` (600) mein. Ye registry upload ki state
   sign karne ke liye use karti hai. Config file mein nahi rakha, taake config repo mein ja sake.
6. Cert/key, config, compose `/srv/registry/` mein. Koi file badli ho tab hi `docker compose restart`.
7. `docker compose up -d`, phir verify: `https://registry.lab.local/v2/` (Lab CA se, `-k` ke baghair) → **401**.

**compose.yaml ki hardening (kyun):**
| Setting | Kyun |
|---|---|
| `image: registry:3.1.2@sha256:...` | Tag badla ja sakta hai, digest nahi. Isse pakka hai ke bilkul wohi image chalegi. |
| `restart: always` | Container crash ya s4 reboot ke baad khud wapas aaye. |
| `ports: "443:5000"` | Bahar standard HTTPS port, andar registry ka default port. Image names mein port nahi likhna padta. |
| `read_only: true` + `tmpfs: /tmp` | Container ka filesystem badla nahi ja sakta. Sirf `data/` volume aur `/tmp` likhe ja sakte hain. |
| `cap_drop: [ALL]`, `no-new-privileges` | Container root ke paas bhi kernel capabilities nahi hain; exploit ho to nuqsaan kam. |
| Log rotation (10 MB × 3) | Logs se disk na bhare (DiskPressure, Phase 0 Step 10). |

**config.yml (kyun):**
| Field | Kyun |
|---|---|
| `log.level: info` | Image ka default `debug` hai, jo bohat zyada likhta hai. |
| `storage.delete.enabled: true` | Manifests/blobs digest se delete ho sakein (GC ke liye zaroori). |
| `storage.maintenance.uploadpurging` | 7 din purane adhoore uploads saaf. |
| `http.tls` + `minimumtls: tls1.2` | TLS registry khud karti hai, TLS 1.0/1.1 band. |
| `http.debug` nahi | Image ke default mein debug server `:5001` khula hai; hum ne band rakha. |
| `auth.htpasswd` | Basic auth, sirf bcrypt hashes maane jate hain. |

**⚠️ htpasswd ki 2 baatein (docs se):**
1. File **sirf startup pe** load hoti hai. User/password badla to registry restart chahiye (`registry.sh` khud karti hai).
2. Agar htpasswd file **na mile** to registry khud aik default user aur random password bana deti hai.
   Isi liye script file pehle banati hai, uske baad container chalata hai.

### htpasswd vs Harbor vs ECR (auth / authorization)
| | **distribution + htpasswd** (hamara) | **Harbor** | **AWS ECR + IAM** 🔴 |
|---|---|---|---|
| Authentication | Username/password (bcrypt file) | Local users, LDAP/AD, **OIDC** (SSO) | IAM (roles, kam-umr tokens) |
| Authorization | ❌ **Koi RBAC nahi**: har valid user **push, pull aur delete** sab kar sakta hai | ✅ Projects, roles (guest/developer/maintainer/admin), **robot accounts** per-project | ✅ IAM policies: repo/action level (`ecr:BatchGetImage`, `ecr:PutImage`) |
| Extra | Sirf storage + API | Vulnerability scanning (Trivy), image signing, replication, quotas, retention, audit log | Scanning, lifecycle policies, cross-region replication, managed |
| Kab | Lab / chhota internal use | On-prem production | AWS pe production |

🔴 **Aham:** hamare naam `k8s-pull` aur `ci-push` sirf **naam** hain. Registry ke liye dono barabar hain,
yani `k8s-pull` bhi image **push ya overwrite** kar sakta hai. Agar kisi node se `k8s-pull` ka password leak
ho jaye to attacker hamari images badal sakta hai. Asal "sirf pull" chahiye ho to Harbor (robot account
with pull-only) ya ECR (IAM pull-only policy) chahiye. Ye limitation jaan-boojh kar qubool ki gayi hai (lab).

### Image delete aur garbage collection (GC)
Delete **do qadam** ka kaam hai:
1. **Manifest delete** (API se, digest se. Tag se delete nahi hota):
   ```bash
   # s4 pe. Password netrc (process substitution) se jata hai: command line / history mein nahi aata.
   reg() { curl -s --netrc-file <(printf 'machine registry.lab.local login ci-push password %s\n' \
                 "$(sudo cat /root/registry-credentials/ci-push.password)") "$@"; }
   D=$(reg -I -H 'Accept: application/vnd.oci.image.index.v1+json' \
              -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
              https://registry.lab.local/v2/test/busybox/manifests/1.37.0 \
       | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | tr -d '\r')
   reg -o /dev/null -w '%{http_code}\n' -X DELETE "https://registry.lab.local/v2/test/busybox/manifests/${D}"   # → 202
   ```
   Isse sirf manifest (aur uske tags) hat-te hain. **Layers (blobs) abhi bhi disk pe hain.**
2. **Garbage collect** (disk wapas lena). Ye **registry band ya read-only** mein karo, warna chalte push
   ka koi naya blob "unreferenced" samajh kar delete ho sakta hai (data corruption):
   ```bash
   cd /srv/registry
   sudo docker compose exec -T registry registry garbage-collect --dry-run /etc/distribution/config.yml   # pehle dekho
   sudo docker compose stop registry
   sudo docker compose run --rm registry garbage-collect --delete-untagged /etc/distribution/config.yml
   sudo docker compose up -d
   ```
   (`--dry-run` hum ne chala kar dekha: *"3 blobs marked, 0 blobs and 0 manifests eligible for deletion"*.)

**Interview sawal 1:** *Registry se image delete ki lekin disk space wapas nahi aayi. Kyun?*
**Jawab:** API delete sirf manifest hataata hai. Layers (blobs) disk pe rehte hain kyunke doosri images
bhi unhein share kar sakti hain. Space ke liye `registry garbage-collect` chalana hota hai, aur wo bhi
registry band/read-only karke, taake chalte uploads ke blobs ghalti se delete na hon.

**Interview sawal 2:** *Distribution registry mein "sirf pull" wala user kaise banaoge?*
**Jawab:** htpasswd auth mein ye mumkin nahi; har authenticated user ko poori access milti hai. Is ke liye
token auth server, ya Harbor jaisa registry (robot account, pull-only role) ya cloud registry (ECR/ACR/GAR +
IAM) chahiye.

---

## 5. `trust-ca.sh`: CA trust aur registry client config (s4, s1, s2)

**Kya kiya (har node):**
1. Pehle check kiya ke di gayi file mein **sirf aik CA certificate** hai (`CA:TRUE`) aur koi `PRIVATE KEY` nahi.
2. **OS trust store:** `/usr/local/share/ca-certificates/lab-root-ca.crt` + `update-ca-certificates`.
   Ab `curl`, `openssl`, Go programs waghera bina `-k` ke registry pe bharosa karte hain.
   (`rehash: warning: skipping ca-certificates.crt` Ubuntu ki aam, be-zarar warning hai.)
3. **s4 (Docker):** `/etc/docker/certs.d/registry.lab.local/ca.crt`. Docker har registry ke liye isi folder
   se CA leta hai. `daemon.json` mein `insecure-registries` na ho, ye check bhi hota hai.
4. **s1, s2 (containerd):** pehle confirm kiya ke `config_path = '/etc/containerd/certs.d'` (Phase 1) laga
   hai, phir:
   ```toml
   # /etc/containerd/certs.d/registry.lab.local/hosts.toml
   server = "https://registry.lab.local"

   [host."https://registry.lab.local"]
     capabilities = ["pull", "resolve"]
     ca = "/etc/containerd/certs.d/registry.lab.local/ca.crt"
   ```
5. `skip_verify = true` kahin mile to script fail karti hai.
6. **containerd restart NAHI hua:** script `ActiveEnterTimestamp` pehle aur baad compare karti hai.
   (s1: `07:12:29`, s2: `07:12:51`, yani boot ke baad se wohi process.)

### Image pull mein containerd ka role (Kubernetes mein)
```
kubelet ──(CRI: PullImage + credentials)──► containerd ──► hosts.toml parhta hai (har pull pe)
                                               │            ├─ server/host URL
                                               │            ├─ capabilities (pull/resolve/push)
                                               │            └─ ca → TLS verify
                                               ▼
                         HTTPS → registry.lab.local:443  (401 → creds ke saath dobara → 200)
                                               │
                                               ▼
                         manifest → layers (blobs) → content store → unpack (overlayfs) → container
```
- **kubelet** image khud pull nahi karta. Wo CRI ke zariye containerd ko kehta hai, aur zaroorat ho to
  **credentials** bhi saath bhejta hai (imagePullSecret se).
- **containerd** `config_path` ke neeche `<registry-host>/hosts.toml` **har pull pe** parhta hai. Is liye
  naye registry ke liye containerd restart ki zaroorat nahi. (Purana `registry.mirrors` tareeqa config.toml
  mein tha aur restart maangta tha.)
- **`capabilities = ["pull", "resolve"]`**: `resolve` = tag → digest, `pull` = content download. `push`
  jaan-boojh kar nahi: Kubernetes nodes ko kabhi push nahi karna.
- Content **digest se** store hota hai. Isi liye s2 pe `registry.lab.local/test/busybox:1.37.0` aur
  `docker.io/busybox:1.37.0` aik hi digest (`sha256:bdf57e…`) ki wajah se aik hi content share karte hain.
  Verify mein layers dobara download nahi hui, sirf manifest check hua.

**Verify:**
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://registry.lab.local/v2/      # 401 (bina -k)
cat /etc/containerd/certs.d/registry.lab.local/hosts.toml
systemctl show containerd -p ActiveEnterTimestamp
grep -r skip_verify /etc/containerd/certs.d/ || echo "skip_verify nahi"
```

**Interview sawal:** *containerd ko private registry ka CA kaise batate hain, aur kya containerd restart chahiye?*
**Jawab:** containerd 2.x mein `config_path = "/etc/containerd/certs.d"` set karo (aik dafa, restart ke
saath), phir har registry ke liye `certs.d/<host>/hosts.toml` mein `ca = "<path>"`. Ye file har pull pe parhi
jati hai, is liye naye registry ke liye restart nahi chahiye. `skip_verify` kabhi nahi.

---

## 6. imagePullSecret kaise kaam karta hai

1. Secret type `kubernetes.io/dockerconfigjson`, key `.dockerconfigjson`:
   `{"auths":{"registry.lab.local":{"auth":"<base64(user:password)>"}}}`. Bilkul `~/.docker/config.json` jaisa format.
2. Pod spec mein `imagePullSecrets: [{name: regcred}]` (ya namespace ke ServiceAccount pe, taake har pod mein na likhna pade).
3. Pod jis node pe schedule hota hai, us ka **kubelet** Secret parhta hai, registry ke naam se matching
   credential chunta hai, aur CRI `PullImage` call mein containerd ko deta hai.
4. containerd pehli request bina auth bhejta hai → registry **401** + `WWW-Authenticate: Basic realm="Lab Registry"`
   → containerd credential ke saath dobara bhejta hai → **200**.

**Hamare test mein dono raste dekhe gaye:**
- `with-secret` → **Running**. Registry log: `auth.user.name=k8s-pull`, `HEAD /v2/test/busybox/manifests/1.37.0 → 200`.
- `no-secret` → **ImagePullBackOff**. Registry log: s2 (192.168.2.12) se wohi request → **401**. containerd ka
  message: *"authorization failed: no basic auth credentials"*.

**⚠️ Cache ka nuqta:** dono pods `imagePullPolicy: Always` ke saath chale. Agar `IfNotPresent` hota to
pehle pod ne jo image s2 pe download ki, doosra pod (bina secret) **wohi cached image** bina auth ke chala
leta. Kubernetes default mein node pe pehle se mojood image ke liye credential dobara check nahi karta.
Production mein iska ilaaj `AlwaysPullImages` admission plugin ya kubelet ka "ensure secret pulled
images" feature hai (naye Kubernetes versions), jo multi-tenant clusters mein zaroori hai.

**⚠️ Ye Secret sirf TEST tha:** test mein `regcred` haath se banaya gaya (password memory se stdin pe, kahin
print nahi), aur namespace ke saath delete ho gaya. Asal deployments mein ye Secret **Sealed Secrets
(Phase 5)** se aayega: git mein sirf **encrypted** SealedSecret, aur cluster ka controller usay asal Secret
banata hai. Plain Secret YAML kabhi git mein nahi jata (base64 encryption nahi hai).

**Interview sawal:** *imagePullSecret mein password base64 hota hai. Kya ye mehfooz hai?*
**Jawab:** Nahi, base64 sirf encoding hai, encryption nahi. Jo bhi Secret parh sake (RBAC `get secrets`)
wo password nikal sakta hai. Hifazat ke liye: Secrets pe RBAC sakht rakho, etcd encryption at rest, git
mein sirf Sealed/External Secrets, aur registry pe pull-only, kam-umr credentials (Harbor robot/ECR tokens).

---

## 7. `verify.sh`: 5 tests (nateeja)

| # | Test | Nateeja |
|---|---|---|
| 1 | s1: `curl https://registry.lab.local/v2/` (bina `-k`) | ✅ HTTP/2 **401**, `www-authenticate: Basic realm="Lab Registry"` |
| 2 | `openssl s_client` chain | ✅ depth=1 Lab Root CA → depth=0 registry.lab.local, **Verify return code: 0 (ok)**, TLSv1.3 |
| 3 | s4: `docker login` (ci-push, `--password-stdin`) + push `registry.lab.local/test/busybox:1.37.0` | ✅ Login Succeeded, push OK |
| 4a | Pod **with** imagePullSecret | ✅ Running (s2), registry log `k8s-pull` → 200 |
| 4b | Pod **without** imagePullSecret | ✅ ImagePullBackOff, registry log 401 (192.168.2.12) |
| 5 | `docker logout`, `~/.docker/config.json` | ✅ koi `auths`/`credsStore` nahi |

`phase2-test` namespace test ke baad delete hota hai (`trap`, fail ho tab bhi). Test image
`registry.lab.local/test/busybox:1.37.0` registry mein rehti hai (GC ki misaal ke liye).

---

## 8. Raaste mein seekha

1. **Test ka saboot sahi cheez pe ho:** pehle `no-secret` test "401|unauthorized" dhoond raha tha, lekin
   containerd 401 ko *"authorization failed: no basic auth credentials"* likhta hai, is liye test ghalti se
   FAIL hua. Ab test **do saboot** dekhta hai: pod ka message aur registry ke access log mein usi node se 401.
2. **`docker login | grep ... || true`** login ki nakami chhupa deta. Ab login ka nateeja alag check hota hai.
3. **Registry ka default user:** htpasswd file na ho to registry khud user bana leti hai. Is liye
   container hamesha file banne ke baad chalta hai.
4. **containerd `imageID`** pehle se mojood digest ka purana naam (`docker.io/...`) dikha sakta hai.
   Content digest se pehchana jata hai, naam se nahi.

---

## Kaise chalayein (tarteeb)

```bash
cd ~/lab-infra/phase2
ssh gohar@192.168.2.14 'rm -rf /tmp/lab-infra-phase2 && mkdir -p /tmp/lab-infra-phase2'
scp -r *.sh registry gohar@192.168.2.14:/tmp/lab-infra-phase2/
ssh gohar@192.168.2.14 'cd /tmp/lab-infra-phase2 && sudo bash lab-ca.sh && sudo bash docker.sh && sudo bash registry.sh'
ssh gohar@192.168.2.14 'sudo cat /root/lab-ca/ca.crt' > ../pki/lab-root-ca.crt        # sirf PUBLIC cert
for ip in 192.168.2.14 192.168.2.12 192.168.2.11; do
  ssh gohar@$ip 'mkdir -p /tmp/lab-infra-phase2'
  scp trust-ca.sh versions.sh ../pki/lab-root-ca.crt gohar@$ip:/tmp/lab-infra-phase2/
  ssh gohar@$ip 'sudo bash /tmp/lab-infra-phase2/trust-ca.sh /tmp/lab-infra-phase2/lab-root-ca.crt'
done
bash verify.sh
```
