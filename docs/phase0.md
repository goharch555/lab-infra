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
         match:
           macaddress: "00:0c:29:xx:xx:xx"   # us node ka MAC (Step 12 mein add hua)
         set-name: ens33
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

> Baad mein s1 aur s3 ka root LV saari khaali jagah se bara kiya gaya: **Step 10** dekho.

**Production mein ahmiyat:** Disk full hone pe Kubernetes node pe "DiskPressure" aata hai aur pods
evict hone lagte hain. Container images aur logs bohat jagah lete hain. `/var/lib/containerd` aur
registry storage ki planning pehle se karo.

**Verify / extend kaise hota hai (Step 10 mein s1, s3 pe kiya):**
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

## Phase 0 follow-up: 3 naye steps

Pehli report ke baad ye 3 faisle kiye gaye:

### Step 10: Root disk extend: `disk-extend.sh` (sirf s1, s3)

**Kya kiya:** s1 aur s3 pe root LV sirf 10G tha aur 73–76% bhar chuka tha, jab ke `ubuntu-vg` mein
8.22G khaali para tha. Script ne:
1. `findmnt -no SOURCE /` se pata kiya ke `/` kis device pe hai, phir `lvs` se LV ka **asal path**
   (`/dev/ubuntu-vg/ubuntu-lv`) aur VG nikala. Path hardcode nahi kiya.
2. `vgs -o vg_free_count` se check kiya ke VG mein khaali extents hain ya nahi. **0 hon to kuch nahi
   karti.** Isi wajah se script idempotent hai.
3. `lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv` chalaya, **online**, yaani system chalte chalte.
4. Verify kiya ke VG mein ab 0 khaali hai, aur `df -h /` pehle aur baad dono print kiye.

| Node | Pehle | Baad |
|------|-------|------|
| s1 | 9.8G, 76% used | 18G, 42% used |
| s3 | 9.8G, 73% used | 18G, 40% used |

`inventory.sh` mein `DISK_EXTEND_NODES=(s1 s3)` hai, aur `run-phase0.sh` isay khud chalati hai.

**`lvextend -r` kya karta hai?** Ye do kaam aik saath karta hai:
- **LV bara karna:** VG ke khaali extents (`+100%FREE` = saare) LV ko de diye. Ab block device bara hai.
- **Filesystem bara karna (`-r` = `--resizefs`):** sirf LV bara karne se filesystem ko pata nahi
  chalta. Wo purane size pe hi rehta hai aur `df` purana size dikhata hai. `-r` andar se `fsadm`
  chalata hai, jo ext4 ke liye `resize2fs` aur xfs ke liye `xfs_growfs` chalata hai.
- ext4 aur xfs dono **online grow** support karte hain, yani mounted `/` ko unmount kiye baghair. Is
  liye reboot ki zaroorat nahi padi. (Shrink karna alag aur khatarnak kaam hai: xfs shrink ho hi nahi
  sakta, aur ext4 sirf unmount karke shrink hota hai.)
- `-l +100%FREE` mein `-l` ka matlab hai **extents** mein size dena. `-L +5G` bytes mein deta hai.

**Kyun:** Agle phases mein s1 pe containerd images, etcd, kubelet aur logs aayenge, aur s3 pe k3s +
Argo CD. Ye sab `/var` mein jagah lete hain. 10G root jaldi bhar jata.

**DiskPressure aur eviction (production mein ahmiyat):**
- kubelet har node pe disk ko monitor karta hai: `nodefs` (root/kubelet ka filesystem) aur
  `imagefs` (container images ka filesystem).
- Default **hard eviction thresholds**: `nodefs.available < 10%`, `imagefs.available < 15%`,
  `nodefs.inodesFree < 5%`.
- Threshold cross ho to node pe **`DiskPressure=True`** condition lagti hai. Uske baad:
  1. Node pe `node.kubernetes.io/disk-pressure:NoSchedule` taint lagta hai, aur **naye pods schedule
     nahi hote**.
  2. kubelet pehle **garbage collection** karta hai: istemal na hone wali images aur mare hue
     containers hatata hai.
  3. Phir bhi jagah na bane to pods ko **evict** karta hai. Tarteeb: (a) pehle wo pods jo apni
     `ephemeral-storage` request se **zyada** use kar rahe hon, (b) phir kam **Pod Priority** wale, (c) phir
     jo request ke muqable sab se zyada disk kha rahe hon. Jin pods ki koi request hi nahi (aksar
     BestEffort), wo is wajah se pehle nishana bante hain.
- Nateeja ye hota hai ke apps achanak doosre nodes pe chali jati hain ya Pending reh jati hain. Agar
  control-plane node bhar jaye to etcd bhi masla karta hai (etcd ki apni space quota/alarm hoti hai).
- Production mein disk usage pe alert lagaye jate hain (misal 75%/85%), `/var/lib/containerd` aksar
  alag disk pe rakha jata hai, aur image GC thresholds tune kiye jate hain.

**Verify:**
```bash
df -h /
sudo lvs; sudo vgs       # VFree 0
kubectl describe node s1 | grep -A6 Conditions   # (Phase 1 ke baad) DiskPressure False
```

**Interview sawal:** *`lvextend` ke baad bhi `df -h` purana size dikha raha hai. Kyun, aur kya karoge?*
**Jawab:** LV (block device) bara ho gaya, lekin filesystem abhi purane size pe hai. ext4 ke liye
`resize2fs /dev/vg/lv` aur xfs ke liye `xfs_growfs /mountpoint` chalao (online). Ye masla shuru se
hi na ho, is ke liye `lvextend -r` use karo, jo dono kaam aik saath karta hai.

**Interview sawal 2:** *Kubernetes node pe DiskPressure aaye to kya hota hai?*
**Jawab:** Node pe `DiskPressure` condition aur `disk-pressure:NoSchedule` taint lag jata hai, aur
naye pods us node pe schedule nahi hote. kubelet pehle unused images aur dead containers saaf karta
hai. Phir bhi jagah na bane to pods evict karta hai: pehle wo jo apni ephemeral-storage request se
zyada use kar rahe hon, phir priority aur usage ke hisaab se.

### Step 11: sudoers cleanup: `sudoers-cleanup.sh` (s1)

**Kya mila:** s1 pe `/etc/sudoers.d/` mein do purani files thi, dono `0644`:
| File | Content | Matlab |
|------|---------|--------|
| `nopasswd-sudo` | `%sudo ALL=(ALL) NOPASSWD:ALL` | **`sudo` group** ke har member ko bina password sudo. Group mein sirf `gohar` hai, is liye asal mein wohi kaam jo `90-gohar-nopasswd` karta hai. **s1 pe gohar ka passwordless sudo ISI file se chal raha tha.** |
| `username` | `username ALL=(ALL) NOPASSWD:ALL` | `username` naam ke user ke liye rule, lekin aisa koi user mojood hi nahi. Installer/template ka bacha hua faltu rule. |

`visudo -c` dono pe *"bad permissions, should be mode 0440"* de raha tha.

**Kya kiya (is tarteeb mein):**
1. **Wapsi ka raasta pehle:** aik alag SSH session mein root shell khula rakha, taake sudo toot bhi
   jaye to us se theek ho sake. Phir poora `/etc/sudoers.d` copy kiya:
   `/root/sudoers-backup/full-<timestamp>/`.
2. **Pehle nayi file, phir purani hatao:** s1 pe `00-sudo-nopasswd.sh` chalaya, jis se
   `90-gohar-nopasswd` bani. Agar `nopasswd-sudo` pehle hata dete to gohar ka sudo password maangne
   lagta aur saari automation ruk jati.
3. `sudoers-cleanup.sh nopasswd-sudo username`:
   - **Step A:** har file `chown root:root` + `chmod 0440`. Har file ke baad `visudo -c` chalaya.
     Badli hui file "parsed OK" na ho to purani permission wapas.
   - **Step B:** dono purani files `/root/sudoers-backup/` mein **move** ki (delete nahi). Har move ke
     baad `visudo -c` **aur** `sudo -l -U gohar` mein `NOPASSWD: ALL` check kiya. Koi bhi fail ho to file
     foran wapas.
   - Aakhir mein poora `visudo -c` ka **exit 0** zaroori hai.
4. Nayi SSH session se `sudo -k; sudo -n true` se test kiya, phir rescue session band ki.

Ab s1 bilkul s2, s3, s4 jaisa hai: `/etc/sudoers.d/` mein sirf `90-gohar-nopasswd` aur `README`,
dono `440 root:root`.

**Aik bareek baat (script mein seekhi):** jab tak **doosri** files ki permission ghalat ho,
`visudo -c` exit 1 deta hai. Is liye "har badlao ke baad sirf exit code dekho" wala check pehli hi
file pe rollback kar deta. Script badli hui file ki line ("parsed OK") aur syntax errors ko dekhti hai,
aur poore `visudo -c` ka exit 0 sirf aakhir mein maangti hai.

**Kyun:**
- `sudo` khud world-writable files ko ignore kar deta hai. 0440 standard hai: sirf root parh sake,
  koi likh na sake, taake koi aur user apne aap ko sudo na de sake.
- Faltu rules security ka khatra hain. Agar kal koi `username` naam ka user ban jaye to usay foran
  bina password root mil jata. Group-wide `%sudo NOPASSWD` bhi khatarnak hai: jo bhi `sudo` group mein
  daala jaye, usay bina password root mil jata hai. Specific user ka rule zyada wazeh hai.
- Har node pe **aik jaisi** config ho (consistency). Snowflake servers debug karna mushkil hota hai.

**Production mein ahmiyat:** Privilege access ka audit compliance (CIS, SOC2) ka hissa hai. sudoers
hamesha config management se aur `visudo` check ke saath badla jata hai. Remote server pe sudo/SSH
badalte waqt hamesha **aik session khula rakho**, jaise SSH hardening mein.

**Verify:**
```bash
sudo visudo -c; echo $?                       # 0, aur koi "bad permissions" nahi
sudo stat -c '%a %U:%G %n' /etc/sudoers.d/*   # sab 440 root:root
sudo -k; sudo -n true && echo OK              # passwordless sudo abhi bhi chal raha hai
sudo -l -U gohar                              # gohar ke effective rules
```

**Interview sawal:** *Remote server pe sudoers badalte waqt lock-out se kaise bachoge?*
**Jawab:** (1) Badalne se pehle aik alag root session khuli rakho. (2) Backup lo. (3) Nayi file temp
jagah likh kar `visudo -cf` se check karo, phir `install -m 0440` se rakho. (4) Pehle naya rule lagao,
uske baad purana hatao. (5) Har badlao ke baad `visudo -c` aur asal test (`sudo -k; sudo -n true`)
karo, aur fail ho to foran wapas lao. (6) Nayi session se test karne ke baad hi purani session band karo.

### Step 12: Netplan MAC match + `set-name` (vmxnet3 ki tayyari, charon nodes)

**Kya kiya:** `common.sh` ka network step ab `01-static.yaml` mein interface ko **MAC se** match karta
hai aur naam `ens33` set karta hai:
```yaml
    ens33:
      match:
        macaddress: "00:0c:29:7c:76:18"   # s4 ka MAC (/sys/class/net/ens33/address se)
      set-name: ens33
      dhcp4: false
      ... (baaqi settings wohi)
```
Ye `sudo bash common.sh <node> network` se chalaya (sirf network step, apt waghera nahi), tarteeb
s4 → s3 → s2 → s1. Wohi `netplan generate` + `netplan-safe-apply.sh` (rollback ke saath). Har node pe
pehle aur baad `ip -4 addr` aur `ip route` **bilkul same** the.

| Node | MAC (ens33) |
|------|-------------|
| s1 | `00:0c:29:c5:96:3d` |
| s2 | `00:0c:29:d6:99:e3` |
| s3 | `00:0c:29:6a:28:4c` |
| s4 | `00:0c:29:7c:76:18` |

**Kyun (MAC match + set-name):**
- Linux interface ka "predictable" naam **hardware ki jagah aur type** se banata hai. `ens33` ka
  matlab hai PCI slot 33. VMware mein adapter `pcnet32` se `vmxnet3` karo to naya device naye slot
  pe aata hai aur naam badal jata hai (aam tor pe `ens160`/`ens192`).
- Purani config `ens33:` naam se match karti thi. Naam badalte hi koi config match nahi karti:
  na IP, na route. Node network se kat jata aur sirf VMware console se theek hota.
- `match: macaddress` interface ko **MAC** se pehchanta hai, aur adapter type badalne pe bhi VMware
  aam tor pe MAC wohi rakhta hai. `set-name: ens33` us interface ka naam wapas `ens33` kar deta hai,
  is liye baaqi sab (scripts, docs, firewall rules, k8s config) jaisa hai waisa chalta rahega.
- Andar kya banta hai: netplan `/run/systemd/network/10-netplan-ens33.link` banata hai
  (`[Match] PermanentMACAddress=...` → `[Link] Name=ens33`). Boot pe udev isi `.link` file se naam
  rakhta hai. Check karne ke liye: `udevadm info /sys/class/net/ens33 | grep ID_NET_LINK_FILE`.

**⚠️ Adapter badalne se pehle/baad:**
- VMware mein adapter badalne ke baad VM ka MAC wohi rehna chahiye. Agar VMware naya MAC de de (misal
  `.vmx` mein `ethernet0.addressType`/`generatedAddress` reset ho jaye), to match fail ho jayega aur
  network nahi aayega. Tab console se `01-static.yaml` mein naya MAC dalo, ya `ip link` se dekh kar
  `common.sh <node> network` chalao.
- Aik waqt mein aik node badlo (pehle s4), aur verify karke hi agla node.

**Production mein ahmiyat:** Servers pe NIC ka naam badalna (driver update, hardware change, VM
migration, cloud instance type change) aam masla hai, aur iska nateeja "server boot hua lekin network
nahi". MAC-based match + stable naam isi se bachata hai. Cloud images (cloud-init) bhi yahi karti
hain: `match: macaddress` + `set-name`.

**Verify:**
```bash
ip -br link show ens33                          # naam ens33, MAC wohi
sudo netplan get ethernets.ens33                # match.macaddress + set-name
sudo cat /run/systemd/network/10-netplan-ens33.link
udevadm info /sys/class/net/ens33 | grep -E "ID_NET_LINK_FILE|ID_NET_NAME="
ip -4 addr show ens33; ip route                 # static IP + default via 192.168.2.2
```

**Interview sawal:** *VM ka network adapter badalne ke baad server pe network nahi aa raha. Kya wajah ho sakti hai aur kaise bachoge?*
**Jawab:** Naye adapter ka PCI slot/driver mukhtalif hai, is liye predictable interface naam badal gaya
(misal `ens33` → `ens160`). Netplan/network config purane naam se match karti thi, is liye naye
interface pe koi config nahi lagi. Bachao: config ko MAC se match karo (`match: macaddress`) aur
`set-name` se naam stable rakho. Ye change adapter badalne se **pehle** kar lo, aur MAC ka wohi
rehna confirm karo.

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
| Purani sudoers files | s1: `/root/sudoers-backup/` (`nopasswd-sudo`, `username`, aur `full-<timestamp>/`) |
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
Adapter badalne se interface ka naam (`ens33`) badal sakta hai. Isi liye **Step 12** mein netplan
ko MAC match + `set-name: ens33` pe kar diya gaya. Adapter khud VMware mein badalna hai.
