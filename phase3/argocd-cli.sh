#!/usr/bin/env bash
# argocd-cli.sh — s1 pe argocd CLI (server jitna hi version) + login + admin password badalna.
#
# Istemaal (s1 pe, gohar se):  bash argocd-cli.sh
# - CLI: GitHub release se, cli_checksums.txt se sha256 verify, /usr/local/bin/argocd.
# - Login: argocd login argocd.lab.local --grpc-web   (--insecure NAHI; Lab CA s1 pe trusted hai)
# - Passwords KABHI command line (argv), output ya repo mein nahi: CLI ke password PROMPT pe pty ke
#   zariye diye jate hain (env variable se). Naya admin password sirf s1 ki /root/argocd-admin-password (600) mein.
# - Password badalne ke baad argocd-initial-admin-secret delete.
# Idempotent: CLI sahi version ho to download nahi; password pehle badal chuka ho to sirf login.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.sh
source "${SCRIPT_DIR}/versions.sh"
log()  { echo "[$(hostname)] [argocd-cli] $*"; }
fail() { echo "[$(hostname)] [argocd-cli] ERROR: $*" >&2; exit 1; }
[[ "$(hostname)" == "s1" ]] || fail "s1 pe chalao"
PWFILE="/root/argocd-admin-password"
K=(kubectl --context "$MGMT_CONTEXT" -n "$ARGOCD_NS")

# --- Step 1: CLI install (version = server version) ----------------------------------------------
have="$(argocd version --client --short 2>/dev/null | awk '{print $2}' | cut -d+ -f1 || true)"
if [[ "$have" != "$ARGOCD_VERSION" ]]; then
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  base="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}"
  curl -fsSL -o "${work}/argocd-linux-amd64" "${base}/argocd-linux-amd64"
  curl -fsSL -o "${work}/cli_checksums.txt" "${base}/cli_checksums.txt"
  ( cd "$work" && grep ' argocd-linux-amd64$' cli_checksums.txt | sha256sum -c --quiet ) || fail "argocd CLI ka sha256 match nahi"
  sudo install -m 0755 -o root -g root "${work}/argocd-linux-amd64" /usr/local/bin/argocd
  log "argocd CLI ${ARGOCD_VERSION} install (sha256 OK)"
else
  log "argocd CLI pehle se ${ARGOCD_VERSION}"
fi

# --- pty helper: CLI ke "Password:" prompts pe env se jawab (argv/echo mein password nahi) ------------
run_pty() {  # run_pty <cmd...>   (jawab: env PTY_ANS_1, PTY_ANS_2, ... tarteeb se)
  python3 - "$@" <<'PY'
import os, pty, sys, re, select, signal
args = sys.argv[1:]
answers = [os.environ[k] for k in sorted(k for k in os.environ if k.startswith("PTY_ANS_"))]
secrets = list(answers)
pid, fd = pty.fork()
if pid == 0:
    os.execvp(args[0], args)
out, buf = b"", b""
while True:
    r, _, _ = select.select([fd], [], [], 120)
    if not r:
        os.kill(pid, signal.SIGKILL); sys.stderr.write("pty: timeout\n"); sys.exit(124)
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data; buf += data
    if re.search(rb"[Pp]assword[^\n]*:\s*$", buf):
        if not answers:
            os.kill(pid, signal.SIGKILL); sys.stderr.write("pty: ghair-mutawaqqa password prompt\n"); sys.exit(125)
        os.write(fd, answers.pop(0).encode() + b"\n"); buf = b""
_, st = os.waitpid(pid, 0)
text = out.decode(errors="replace")
for s in secrets:                      # ehtiyaatan: output mein password ho to mita do
    if s: text = text.replace(s, "***")
# sirf PROMPT lines hatao (errors dikhne chahiyen — jaise "does not match ^.{8,32}$")
prompt = re.compile(r"^\s*(\*\*\* )?(Enter|Confirm)[^\n]*assword|^\s*Password:\s*$")
sys.stdout.write("".join(l for l in text.splitlines(True) if not prompt.search(l)))
sys.exit(os.waitstatus_to_exitcode(st))
PY
}
login() {  # login <password>
  PTY_ANS_1="$1" run_pty argocd login "$ARGOCD_HOST" --grpc-web --username admin
}

# --- Step 2: Login + password badalna ------------------------------------------------------------------
initial_exists=no
"${K[@]}" get secret argocd-initial-admin-secret >/dev/null 2>&1 && initial_exists=yes

if sudo test -s "$PWFILE"; then
  # Password pehle badal chuka (ya pichli run beech mein ruki): stored password se login
  pw="$(sudo cat "$PWFILE")"
  login "$pw" >/dev/null || fail "stored password (${PWFILE}) se login nahi hua"
  unset pw
  log "login OK (stored admin password)"
else
  [[ "$initial_exists" == "yes" ]] || fail "na stored password hai na argocd-initial-admin-secret — khud dekho"
  initpw="$("${K[@]}" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  login "$initpw" | sed 's/^/  /' || fail "initial password se login nahi hua"
  # Argo CD ka default password pattern ^.{8,32}$ hai (argocd-cm accounts.passwordPattern) → exactly 32 random characters
  newpw="$(openssl rand -base64 48 | tr -d '\n/+=' | head -c 32)"
  [[ ${#newpw} -eq 32 ]] || fail "password generate nahi hua"
  # Pehle file mein (.new), phir badlo — beech mein ruk jaye to naya password kho na jaye
  printf '%s' "$newpw" | sudo install -m 0600 -o root -g root /dev/stdin "${PWFILE}.new"
  PTY_ANS_1="$initpw" PTY_ANS_2="$newpw" PTY_ANS_3="$newpw" run_pty argocd account update-password --grpc-web \
    | sed 's/^/  /' || fail "password update fail (naya password ${PWFILE}.new mein hai)"
  sudo mv "${PWFILE}.new" "$PWFILE"
  unset initpw
  log "admin password badla → ${PWFILE} (600, sirf root)"
  login "$newpw" >/dev/null || fail "naye password se login nahi hua"
  unset newpw
  log "naye password se login OK"
fi

# --- Step 3: argocd-initial-admin-secret delete -----------------------------------------------------------
if "${K[@]}" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  "${K[@]}" delete secret argocd-initial-admin-secret >/dev/null
  log "argocd-initial-admin-secret delete kiya"
fi

# --- Verify -------------------------------------------------------------------------------------------------
argocd version --grpc-web
argocd account get-user-info --grpc-web
[[ "$(sudo stat -c '%a %U' "$PWFILE")" == "600 root" ]] || fail "${PWFILE} 600 root nahi"
! "${K[@]}" get secret argocd-initial-admin-secret >/dev/null 2>&1 || fail "initial secret abhi bhi hai"
log "verify: CLI ${ARGOCD_VERSION}, logged in as admin (--grpc-web, TLS verify), initial secret deleted"
log "DONE"
