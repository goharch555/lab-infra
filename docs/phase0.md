# Phase 0: Node Preparation

Is phase mein 4 fresh Ubuntu 24.04 VMs ko is qabil banaya gaya ke agle phases (Kubernetes, k3s,
registry, CI) un pe bina masle ke lag sakein. **Is phase mein koi container runtime, Docker,
Kubernetes ya k3s install NAHI kiya gaya.** Firewall (ufw) bhi on nahi kiya gaya, wo faisla baad mein hoga.

Har step ke liye yahan likha hai:
- **Kya kiya**: asal kaam
- **Kyun**: wajah
- **Production mein ahmiyat**: real duniya mein ye kyun zaroori hai
- **Verify**: kaise check karein ke kaam ho gaya
- **Interview sawal**: aik sawal aur us ka jawab

---

## 0. Bunyadi usool (scripts kaise likhi gayi hain)

### Infrastructure as Code (IaC)
Har kaam haath se command chala kar nahi, **script** ke zariye kiya gaya, aur script git mein hai.
Agar kal koi VM kharab ho jaye to nayi VM pe wohi script chala kar bilkul wohi haalat dobara ban
jayegi. Git history se ye bhi pata chalta hai ke kab kya badla aur kyun.

### Idempotent
Idempotent script ko 1 dafa chalao ya 10 dafa, nateeja aik hi hoga. Har step pehle **check** karta
hai ke cheez pehle se theek hai ya nahi, aur sirf zaroorat ho to badalta hai. Misal:
- `/etc/hosts` mein lines `# BEGIN lab-infra phase0` / `# END` markers ke darmiyan likhi jati hain.
  Dobara chalane pe purana block hata kar naya likha jata hai, is liye duplicate lines nahi bantein.
- Static IP pehle se laga ho to `netplan apply` dobara nahi chalta.

### `set -euo pipefail`
- `-e`: koi command fail ho to script **wahin ruk jaye**, aage ghalat haalat pe kaam na kare.
- `-u`: koi undefined variable use ho to error aaye. Is se typo pakra jata hai, warna wo khamoshi
  se khaali string ban jata.
- `-o pipefail`: `a | b` mein agar `a` fail ho to poori pipe fail mani jaye.

### Orchestration: `run-phase0.sh`
s1 se har node pe `scp` se scripts bheji jati hain aur `ssh` se `sudo bash` chalaya jata hai.
Tarteeb **s4 → s3 → s2 → s1** hai, yaani sab se kam-ahem node pehle aur s1 aakhir mein. Wajah:
1. Agar script mein koi bug ho to wo s4 pe pakra jaye. s1 hamari "control machine" hai, wo
   kharab ho gayi to baaqi nodes tak pohanchna mushkil ho jayega.
2. s1 se hi orchestrator chal raha hai. Is liye s1 ko script khud reboot nahi karti, sirf batati
   hai ke reboot chahiye.

Har node ka output `phase0/logs/` mein save hota hai. Ye folder `.gitignore` mein hai.

**Interview sawal:** *Idempotency ka kya matlab hai aur configuration scripts mein ye kyun zaroori hai?*
**Jawab:** Operation ko kitni dafa bhi chalao, nateeja pehli dafa jaisa hi rahe. Is se script ko
safely dobara chala sakte hain: aadhe mein fail hone ke baad, drift theek karne ke liye, ya naye node
pe. Ansible, Terraform aur Kubernetes controllers sab isi "desired state" usool pe chalte hain.

---

## 00. Passwordless sudo: `00-sudo-nopasswd.sh`

**Kya kiya:** s2, s3, s4 pe `/etc/sudoers.d/90-gohar-nopasswd` file banayi:
`gohar ALL=(ALL) NOPASSWD:ALL`, permission `0440`. s1 pe ye pehle se tha.

**Kyun:** Scripts s1 se `ssh` ke zariye chalti hain, aur wahan koi password type karne wala nahi
hota. Password script mein likhna galat hota (repo public hai).

**Kaise safely:**
- File pehle temp jagah likhi, `visudo -cf` se syntax check kiya, aur sirf phir `/etc/sudoers.d/` mein rakhi.
  Ghalat sudoers file **sudo ko hi tod deti hai**, phir root access wapas lene ke liye recovery mode chahiye hota hai.
- `/etc/sudoers` ko edit nahi kiya, alag drop-in file banayi. Package upgrade pe conflict nahi hota
  aur hatana asaan hai (bas file delete karo).

**Production mein ahmiyat:** Production mein aam tor pe `NOPASSWD:ALL` kisi insaan ko nahi diya
jata. Automation ke liye alag service account hota hai, aur access sirf zaroori commands tak
mehdood hota hai. Lab mein ye theek hai, lekin ye fark yaad rakho.

**Verify:**
```bash
ssh gohar@192.168.2.12 'sudo -k; sudo -n true && echo OK'
```

**Interview sawal:** *`/etc/sudoers` ko seedha `vim` se kyun edit nahi karna chahiye?*
**Jawab:** Agar syntax ghalat ho gaya to sudo kaam karna chhor deta hai aur aap admin access kho dete
ho. `visudo` save se pehle syntax check karta hai. Behtar ye hai ke `/etc/sudoers.d/` mein alag file
banao aur `visudo -cf <file>` se check karo.

---

## common.sh: har node pe

Chalana: `sudo bash common.sh s4` (node ka naam argument mein).

Shuru mein script **interface ka naam confirm** karti hai. Wo interface dhoondti hai jis pe is node
ka IP laga hai (yahan `ens33`), aur check karti hai ke default route bhi usi interface pe hai. Agar
dono mukhtalif hon to script ruk jati hai, andaze se kaam nahi karti.

### Step 1: Hostname aur `/etc/hosts`

**Kya kiya:**
- `hostnamectl set-hostname sN`, sirf agar hostname pehle se mukhtalif ho.
- `/etc/hosts` mein ye block likha:
  ```
  192.168.2.11 s1 k8s-api.lab.local
  192.168.2.12 s2
  192.168.2.13 s3 argocd.lab.local
  192.168.2.14 s4 registry.lab.local
  ```
- Ubuntu ki default line `127.0.1.1 sN` **hata di**. Pehli dafa ka backup `/root/hosts.bak-phase0` mein hai.

**Kyun:**
- Lab mein koi DNS server nahi hai, is liye naam se IP tak pohanchne ke liye `/etc/hosts` use kiya.
- `k8s-api.lab.local`: kubeadm mein `--control-plane-endpoint` ke liye **IP ke bajaye naam** dena
  behtar hai. Kal ko control-plane ke aage load balancer lagao ya HA banao, to sirf DNS/hosts entry
  badalni padegi, saare certificates aur kubeconfig dobara nahi banane padenge.
- `127.0.1.1 s1` line kyun hatayi: is ki wajah se `s1` naam loopback pe resolve hota. Kubernetes aur
  bohat se distributed systems node ka naam resolve karke apna IP nikalte hain, aur unhein asal LAN IP
  chahiye, 127.x nahi.

**Production mein ahmiyat:** Production mein `/etc/hosts` ki jagah asli DNS hota hai (Route53, CoreDNS,
AD DNS waghera). Usool phir bhi wohi hai: services ko **stable naam** se refer karo, IP se nahi.
Hostnames unique aur samajh aane wale hon, kyunke Kubernetes node ka naam hostname se hi leta hai.

**Verify:**
```bash
hostnamectl | grep "Static hostname"
getent hosts k8s-api.lab.local registry.lab.local argocd.lab.local
getent hosts $(hostname)        # 192.168.2.x aana chahiye, 127.0.1.1 nahi
```

**Interview sawal:** *`getent hosts` aur `nslookup`/`dig` mein kya fark hai?*
**Jawab:** `dig`/`nslookup` seedha DNS server se poochte hain. `getent hosts` wohi raasta use karta hai
jo applications use karti hain (`/etc/nsswitch.conf`: pehle `/etc/hosts`, phir DNS). Is liye
"application ko kya nazar aayega" ye check karne ke liye `getent` sahi tool hai.

### Step 2: Static IP (netplan)

**Kya kiya:**
1. Purani netplan files (`50-cloud-init.yaml`, `dhcp4: true`) ka backup
   `/root/netplan-backup/<timestamp>/` mein liya, phir unhein `/etc/netplan/` se hata diya.
2. cloud-init ka network management band kiya:
   `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` → `network: {config: disabled}`.
3. Nayi file `/etc/netplan/01-static.yaml` (permission **600**, owner root):
   ```yaml
   network:
     version: 2
     renderer: networkd
     ethernets:
       ens33:
         dhcp4: false
         dhcp6: false
         ignore-carrier: true
         addresses: [192.168.2.1X/24]
         routes:
           - to: default
             via: 192.168.2.2
         nameservers:
           addresses: [192.168.2.2, 8.8.8.8]
   ```
4. Pehle `netplan generate` chalaya. Ye sirf config check karke backend files banata hai, network
   ko nahi chherta. Agar ye fail ho to purani files wapas rakh kar script ruk jati hai.
5. Phir `netplan-safe-apply.sh` ke zariye apply kiya. Ye `netplan apply` karti hai aur **30 second
   tak gateway (192.168.2.2) ko ping** karti hai. Gateway na mile to backup wali config wapas laga
   kar dobara apply karti hai (rollback).
6. Ye apply `systemd-run` se **alag systemd unit** mein chalta hai. Network badalte waqt SSH
   connection toot bhi jaye to apply/rollback ka kaam beech mein nahi rukta.

**Kyun:**
- **Wohi IP static kyun:** VMware ki DHCP range nahi badli, aur saare IPs pehle se isi range se aa
  rahe the. Wohi IP static kiya taake koi IP conflict ya tabdeeli na ho. Kubernetes node IP certificates
  (API server cert ke SAN) aur etcd mein likha jata hai. Agar IP badal jaye to cluster toot jata hai.
- **`ignore-carrier: true`:** VMware mein interface kabhi kabhi "UNKNOWN"/no-carrier dikhata hai
  (hamare s1/s3/s4 pe yahi tha). Is option se carrier ki haalat jo bhi ho, IP aur route lage rehte
  hain. Warna boot pe network "down" samjha ja sakta tha.
- **cloud-init disable kyun:** cloud-init har boot pe network config dobara likh sakta hai. Phir
  `50-cloud-init.yaml` (DHCP) wapas aa jati aur hamari static config ke saath takra jati.
- **600 permission kyun:** netplan files mein WiFi passwords waghera bhi ho sakte hain, is liye
  netplan world-readable files pe warning deta hai.
- **Rollback kyun:** Remote machine pe ghalat network config lagane ka matlab hai machine se rabta
  khatam. Phir console pe jana padta hai, jo cloud/data-center mein mushkil ya mehnga hota hai.

**Production mein ahmiyat:** Servers ke IP hamesha predictable hone chahiye: ya to static, ya DHCP
reservation. Remote network change hamesha **"apply + auto-rollback"** pattern se karo. Cisco ka
`commit confirmed` aur `netplan try` isi idea pe bane hain. Changes se pehle backup hamesha lo.

**Verify:**
```bash
ip -4 addr show ens33          # "dynamic" lafz NAHI hona chahiye, "valid_lft forever" hona chahiye
ip route                       # default via 192.168.2.2 dev ens33 proto static
resolvectl query github.com    # DNS chal raha hai
sudo netplan get               # effective config
```

**Interview sawal:** *`netplan generate`, `netplan apply` aur `netplan try` mein kya fark hai?*
**Jawab:** `generate` sirf YAML ko backend (systemd-networkd/NetworkManager) config mein convert
karta hai, network ko nahi chherta. Ye syntax check ke liye achha hai. `apply` config generate karke
foran laga deta hai. `try` config lagata hai aur confirmation ka intezar karta hai. Waqt (default
120s) mein confirm na karo to khud purani config wapas le aata hai. Hum ne `try` ki jagah apni script
istemal ki, kyunke `try` ko interactive terminal chahiye hota hai aur hamara confirmation automatic
tha (gateway ping).

### Step 3: Timezone UTC + chrony

**Kya kiya:**
- `timedatectl set-timezone UTC`.
- `chrony` install kiya. Ye Ubuntu ke default `systemd-timesyncd` ki jagah le leta hai, aur
  `apt` us package ko khud hata deta hai.
- 120 second tak intezar kiya ke `timedatectl` mein `System clock synchronized: yes` aa jaye. Na aaye
  to script fail ho jati hai.

**Kyun:**
- **UTC:** Saare servers aik hi timezone mein hon to logs milana asaan hota hai. UTC mein daylight
  saving ka masla bhi nahi hota. Display ke liye local time sirf user-side pe badla jata hai.
- **Time sync:** TLS certificates mein "valid from/to" waqt hota hai. Clock aage-peechhe ho to
  certificate "not yet valid" ya "expired" lagta hai. etcd/Kubernetes leases, Raft consensus, JWT
  tokens aur log correlation, sab sahi waqt pe chalte hain.
- **chrony kyun (timesyncd kyun nahi):** timesyncd sirf simple SNTP client hai. chrony poora NTP
  implementation hai: multiple sources, behtar accuracy, VM pause/resume ke baad clock ko jaldi
  theek karta hai, aur `chronyc` se monitoring hoti hai. VMs ke liye ye khaas tor pe behtar hai.

**Production mein ahmiyat:** Time drift aisa masla hai jo dikhta nahi lekin ajeeb errors deta hai:
"x509: certificate has expired or is not yet valid", etcd leader election ke masle, auth tokens ka
reject hona. Production mein NTP monitoring (offset alerts) bhi lagate hain.

**Verify:**
```bash
timedatectl | grep -E "Time zone|synchronized"
chronyc tracking     # "System time" offset, "Leap status: Normal"
chronyc sources -v   # kin servers se sync ho raha hai (* = selected)
```

**Interview sawal:** *Kubernetes cluster mein nodes ki clock out of sync ho to kya masle ho sakte hain?*
**Jawab:** TLS handshakes fail ho sakte hain (certificate not yet valid/expired). Service account
tokens aur OIDC tokens reject ho sakte hain. etcd mein leader election aur leases ghalat chal sakti
hain. Logs aur metrics ke timestamps mismatch hote hain, jis se debugging mushkil hoti hai.

### Step 4: OS update + base packages

**Kya kiya:**
- `apt-get update` aur `apt-get full-upgrade -y`, non-interactive.
  (`--force-confold`: agar kisi config file pe conflict ho to hamari maujooda file rakhi jaye.)
- Packages: `curl ca-certificates gnupg git jq vim bash-completion`.
- `apt-get autoremove`.
- Agar `/var/run/reboot-required` mojood ho (aam tor pe naya kernel aane pe) to `run-phase0.sh` node
  ko reboot karti hai aur `boot_id` badalne ka intezar karti hai. Ye **aik waqt mein aik node** pe hota hai.

**Kyun:**
- Fresh install ke baad security patches lagana pehla kaam hai.
- `full-upgrade` (simple `upgrade` ke bajaye) zaroorat pade to packages hata/install bhi kar sakta
  hai, jaise naya kernel. Is liye ye mukammal upgrade hai.
- `curl`, `ca-certificates`, `gnupg` agle phases mein repos ki GPG keys aur HTTPS downloads ke liye
  chahiye honge (Kubernetes/Docker repo). `jq` JSON parse karne ke liye hai (kubectl output), aur
  `git`/`vim`/`bash-completion` rozmarra ke kaam ke liye.
- **Aik waqt mein aik reboot:** agar sab nodes saath reboot hon aur koi wapas na aaye to sab kuch
  aik saath band ho jata hai. Production mein isay **rolling reboot** kehte hain.

**Production mein ahmiyat:** Patch management (unattended-upgrades, ya maintenance window mein
controlled upgrade). Kubernetes nodes pe reboot se pehle `kubectl drain` kiya jata hai aur aik node
ke baad doosra reboot hota hai, taake apps chalti rahein. Tools: kured (Kubernetes Reboot Daemon).

**Verify:**
```bash
apt list --upgradable 2>/dev/null | tail -n +2 | wc -l   # 0 hona chahiye
ls /var/run/reboot-required 2>/dev/null || echo "reboot ki zaroorat nahi"
uname -r                                                 # naya kernel
```

**Interview sawal:** *`apt upgrade` aur `apt full-upgrade` mein kya fark hai?*
**Jawab:** `upgrade` sirf mojood packages ko naye version pe le jata hai aur koi package hataata ya
naya install nahi karta. Agar upgrade ke liye naya dependency chahiye ho to wo package "held back"
reh jata hai. `full-upgrade` (purana naam `dist-upgrade`) zaroorat pade to packages install/remove
bhi karta hai, is liye poora system upgrade ho jata hai.

### Step 5: Disk report (sirf report)

**Kya kiya:** `lsblk`, `df -h /`, `vgs` chalaye. Agar LVM volume group mein khaali jagah (`VFree`)
ho, ya disk pe koi unpartitioned jagah ho (`sfdisk -F`), to `REPORT:` line print hoti hai.
**Kuch extend NAHI kiya.**

**Kyun:** Ubuntu installer by default LVM mein root LV ko VG ka sirf aadha (ya max ~100G) deta hai.
Baaqi jagah `VFree` mein khaali parhi rehti hai. Ye pata hona chahiye, lekin kab aur kitna extend
karna hai, ye planning ka faisla hai (baad mein naya LV bhi ban sakta hai, jaise registry data ke liye).

**Hamare lab mein (Phase 0 ke waqt):**
| Node | Disk | Root LV | VG khaali (VFree) |
|------|------|---------|-------------------|
| s1 | 20G  | 10G | ~8.2G |
| s2 | 70G  | 34G | ~34G |
| s3 | 20G  | 10G | ~8.2G |
| s4 | 60G  | 29G | ~29G |

**Production mein ahmiyat:** Disk full hone pe Kubernetes node pe "DiskPressure" aata hai aur pods
evict hone lagte hain. Container images aur logs bohat jagah lete hain. `/var/lib/containerd` aur
registry storage ki planning pehle se karo.

**Verify / baad mein extend karna ho to (abhi NAHI kiya):**
```bash
sudo vgs; sudo lvs; df -h /
# misal: sudo lvextend -r -L +5G /dev/ubuntu-vg/ubuntu-lv   (-r = filesystem bhi resize)
```

**Interview sawal:** *LVM ka kya faida hai?*
**Jawab:** Physical disks (PV) ko aik pool (VG) mein jor kar us se logical volumes (LV) bante hain.
LV ko online extend kar sakte hain (`lvextend -r`), nayi disk VG mein add kar sakte hain, aur
snapshots le sakte hain. Fixed partitions ke muqable mein ye zyada flexible hai.

---

## k8s-prereqs.sh: Kubernetes ki OS zarooriyat

Chalana:
- s1, s2: `sudo bash k8s-prereqs.sh` (swap + modules + sysctl)
- s3: `sudo bash k8s-prereqs.sh --swap-only` (k3s ke liye sirf swap off)
- s4 pe nahi chalti.

### Step 6: Swap band

**Kya kiya:**
- `swapoff -a` se swap foran band kiya.
- `/etc/fstab` mein swap wali line (`/swap.img none swap sw 0 0`) ko comment kiya:
  `# disabled by lab-infra phase0: ...`. Is se reboot ke baad bhi swap wapas nahi aata.
  fstab ka backup `/root/fstab.bak-phase0` mein hai.
- `/swap.img` file disk pe abhi mojood hai (1.9G–3.8G) lekin istemal nahi ho rahi. Is ko delete nahi kiya.

**Kyun:** kubelet by default swap on hone pe **start hi nahi hota** (`failSwapOn: true`).
Kubernetes scheduler pods ko memory `requests`/`limits` ke hisaab se rakhta hai. Agar node swap
kare to performance ghair-mutawaqqa ho jati hai, memory limits ka hisaab bigar jata hai aur
OOM/eviction ka rawaiyya ghalat ho jata hai. (Naye versions mein limited swap support hai, lekin wo
alag configuration hai aur default nahi.)

**Production mein ahmiyat:** Swap off rakhne se memory pressure ka nateeja wazeh hota hai: pod
evict ya OOM-kill hota hai aur scheduler doosri jagah rakhta hai. Agar swap on ho to node
dheere dheere aahista ho jata hai aur masla pakarna mushkil hota hai.

**Verify:**
```bash
swapon --show          # khaali output
free -h | grep Swap    # 0B
grep swap /etc/fstab   # line '#' se shuru
```

**Interview sawal:** *kubeadm ke liye swap kyun band karte hain?*
**Jawab:** kubelet by default swap on hone pe start nahi hota. Kubernetes ka resource model (requests,
limits, eviction) is baat pe chalta hai ke memory asli RAM hai. Swap se latency ghair-mutawaqqa ho
jati hai aur memory accounting ghalat ho jati hai. 1.28+ mein `NodeSwap` feature hai, lekin wo
explicit configure karna padta hai.

### Step 7: Kernel modules: overlay, br_netfilter

**Kya kiya:** `/etc/modules-load.d/k8s.conf` mein `overlay` aur `br_netfilter` likhe (boot pe khud load
honge) aur `modprobe` se abhi load bhi kar diye.

**Kyun:**
- **overlay:** containerd ka default snapshotter **OverlayFS** hai. Container image ki layers
  (read-only) ke upar aik writable layer lagti hai. Is module ke baghair containers nahi chalte.
- **br_netfilter:** Pods aik Linux **bridge** (CNI bridge) se jure hote hain. By default bridge pe
  jaane wala traffic iptables se nahi guzarta. Ye module bridge traffic ko iptables/netfilter tak
  bhejta hai. Is ke baghair kube-proxy ke Service (ClusterIP/NodePort) rules pod-to-pod traffic pe
  lagte hi nahi.

**Production mein ahmiyat:** Ye na hon to cluster ban to jata hai, lekin Services ka "kabhi chalna
kabhi nahi" wala masla aata hai. Is ko debug karna bohat mushkil hota hai. kubeadm preflight bhi in
cheezon ko check karta hai.

**Verify:**
```bash
lsmod | grep -E "overlay|br_netfilter"
cat /etc/modules-load.d/k8s.conf
```

**Interview sawal:** *`br_netfilter` module kya karta hai aur Kubernetes ko is ki kyun zaroorat hai?*
**Jawab:** Ye Linux bridge se guzarne wale packets ko netfilter (iptables) hooks se guzarta hai.
kube-proxy Services ko iptables/IPVS rules se implement karta hai. Agar bridge traffic iptables se
na guzre to aik hi node ke pods ke darmiyan Service traffic DNAT nahi hota.

### Step 8: sysctl

**Kya kiya:** `/etc/sysctl.d/k8s.conf`:
```
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
```
Phir `sysctl --system` se foran lagaya. File `/etc/sysctl.d/` mein hai, is liye reboot ke baad bhi lagi rehti hai.

**Kyun:**
- `bridge-nf-call-iptables/ip6tables = 1`: Step 7 wala module sirf ye option *dastiyab* karta hai.
  Ye sysctl usay **on** karti hai, taake bridged IPv4/IPv6 traffic iptables se guzre.
- `ip_forward = 1`: node ko **router** ki tarah packets forward karne do. Pod ka traffic aik
  interface (pod network) se aa kar doosre (ens33 ya doosre node) pe jata hai. Forwarding band ho to
  pod-to-pod (cross-node) aur pod-to-internet traffic nahi chalta.

**Production mein ahmiyat:** Kernel tuning hamesha `/etc/sysctl.d/*.conf` files mein karo, taake
reboot ke baad bhi lagi rahe aur config management (git) mein track ho. Sirf `sysctl -w` reboot pe
khatam ho jata hai.

**Verify:**
```bash
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables
```

**Interview sawal:** *`sysctl -w` aur `/etc/sysctl.d/` file mein kya fark hai?*
**Jawab:** `sysctl -w` sirf chalte kernel mein value badalta hai, aur reboot pe wo value khatam ho
jati hai. `/etc/sysctl.d/*.conf` boot pe `systemd-sysctl` parhta hai, is liye change permanent hota
hai. `sysctl --system` saari files abhi dobara load kar deta hai.

---

## ssh-hardening.sh: Step 9 (⚠️ ABHI NAHI CHALAYA)

**Shart:** Ye script sirf tab chalegi jab confirm ho jaye ke **Windows se har node pe key se login**
chal raha hai. Is ke liye script ko `--i-confirmed-key-login` flag dena zaroori hai. Flag ke baghair
script khud ruk jati hai, taake ghalti se na chal jaye.

**Kya karegi:**
1. Check karegi ke `~gohar/.ssh/authorized_keys` khaali nahi hai (warna lock-out ka khatra).
2. `/etc/ssh/sshd_config.d/00-lab-hardening.conf`:
   ```
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   PermitRootLogin no
   ```
3. `sshd -t`: config test. Fail ho to change wapas aur reload nahi hoga.
4. `sshd -T` se effective values verify karegi.
5. Sirf phir `systemctl reload ssh`. Restart nahi, is liye maujooda sessions nahi tootte.

**Kyun:**
- Password login pe brute-force attack ho sakta hai. Keys ko guess karna amalan na-mumkin hai.
- Root login band: attacker ko username (`root`) pehle se maloom hota hai. Insaan apne user se
  login karke `sudo` use kare, jis ka audit log bhi banta hai.
- `KbdInteractiveAuthentication no`: ye password ka "doosra darwaza" hai, is ko bhi band kiya.
- **`00-` naam kyun:** sshd har setting ki **pehli** value maanta hai, aur `sshd_config.d/*.conf`
  alphabetical order mein parhi jati hain. Ubuntu/cloud-init ki `50-cloud-init.conf` mein
  `PasswordAuthentication yes` ho sakta hai. Hamari `00-` file us se pehle parhi jati hai, is liye
  hamari value jeetti hai.

**Production mein ahmiyat:** SSH hardening har internet-facing ya production server ka bunyadi kaam
hai (CIS benchmark). Hamesha **aik session khula rakh kar** change karo aur nayi terminal se test karo,
taake ghalti ho to wapas theek kar sako.

**Chalana (confirmation ke baad):**
```bash
cd ~/lab-infra/phase0
for ip in 192.168.2.14 192.168.2.13 192.168.2.12 192.168.2.11; do
  scp ssh-hardening.sh gohar@$ip:/tmp/ && ssh gohar@$ip 'sudo bash /tmp/ssh-hardening.sh --i-confirmed-key-login'
done
```

**Verify:**
```bash
sudo sshd -T | grep -E "passwordauthentication|permitrootlogin"
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password gohar@192.168.2.14   # "Permission denied (publickey)" aana chahiye
```

**Interview sawal:** *`sshd` ka config badalne ke baad `reload` aur `restart` mein kya fark hai, aur kya ehtiyaat karni chahiye?*
**Jawab:** `reload` (SIGHUP) se sshd naya config parh leta hai aur maujooda connections chalte rehte
hain. `restart` process ko band karke dobara chalata hai. Pehle hamesha `sshd -t` se syntax check
karo, kyunke ghalat config pe sshd start na hua to remote access khatam ho jata hai. Aik session
khula rakho aur nayi session se login test karo.

---

## Report kaise lein

```bash
cd ~/lab-infra/phase0
for ip in 192.168.2.11 192.168.2.12 192.168.2.13 192.168.2.14; do ssh gohar@$ip 'bash -s' < verify.sh; done
```

## Rollback / backups ki jagah (har node pe)

| Kya | Kahan |
|-----|-------|
| Purani netplan files | `/root/netplan-backup/<timestamp>/` |
| Original `/etc/hosts` | `/root/hosts.bak-phase0` |
| Original `/etc/fstab` | `/root/fstab.bak-phase0` (s1, s2, s3) |
| Run logs | s1: `~/lab-infra/phase0/logs/` (git mein nahi) |

---

## Phase 0 chalate waqt kya seekha (asal masle)

### 1. Gateway ping "jhoot" bol sakta hai (race condition)
s3 pe pehli dafa `common.sh` ruk gayi: *"default route 192.168.2.2 pe nahi"*. Wajah: gateway
`192.168.2.2` **same subnet** mein hai, is liye `netplan apply` ke foran baad ping chal gaya, jab ke
networkd ne default route abhi lagaya hi nahi tha. Safe-apply ne "OK" de diya aur verify ne route
na paa kar script rok di. Network theek tha, sirf check jaldi ho gaya tha.
**Fix:** `netplan-safe-apply.sh` ab **default route via gateway + ping**, dono ka intezar karti hai,
aur `common.sh` verify se pehle 15s tak route ka intezar karti hai.
**Sabaq:** health check wohi cheez check kare jo asal mein chahiye (yahan internet tak raasta,
yaani default route), sirf "kuch to chal raha hai" nahi.

### 2. `UTC` aur `Etc/UTC`
Kuch nodes pe timezone `Etc/UTC` tha aur kuch pe `UTC`. Dono aik hi zone hain, lekin script string
compare kar rahi thi, is liye har run pe dobara set karti thi (idempotent nahi thi). Ab dono ko
theek maana jata hai. **Sabaq:** idempotency check ko "barabar maani" values pehchanni chahiye.

### 3. Mirror ka waqti masla
Aik run mein `pk.archive.ubuntu.com` se downloads "connection refused/timeout" de rahe the. Script
`set -e` ki wajah se wahin ruk gayi, aur mirror theek hone pe dobara chala di. Idempotent hone ki
wajah se jo kaam ho chuka tha wo dobara nahi hua.

### 4. Upgrade ke dauran SSH "Connection refused"
`openssh-server` upgrade hote waqt kuch second ke liye naye SSH connections refuse hue. Purani
session chalti rahi. Ye normal hai, ghabrana nahi.

### 5. Phased updates
Upgrade ke baad bhi `apt list --upgradable` mein 2-3 packages dikh sakte hain (misal `apparmor`,
`open-vm-tools`). Ye Ubuntu ke **phased updates** hain: naya version pehle sirf kuch % machines ko
diya jata hai, taake koi bug ho to sab machines aik saath kharab na hon. Ye jaan-boojh kar hai.
`apt-cache policy <pkg>` mein `(phased 10%)` likha dikhta hai.

### 6. VMware NIC: pcnet32 (purana adapter)
Charon VMs ka network adapter `pcnet32` (AMD PCnet/"vlance") hai, jo bohat purana emulated adapter
hai (10 Mbps report karta hai, CPU zyada khata hai). Production/lab ke liye `vmxnet3` behtar hai.
**Abhi kuch nahi badla.** Agar baad mein badlo to interface ka naam (`ens33`) badal sakta hai. Phir
`/etc/netplan/01-static.yaml` mein naya naam dalna hoga, warna node ka network nahi aayega
(console se theek karna padega).
