#!/usr/bin/env bash
# repo-credentials.sh — private GitOps repo (platform-gitops) ko Argo CD se jorna, READ-ONLY deploy key ke saath.
#
# Istemaal (s1 pe, gohar se):
#   bash repo-credentials.sh                      # Part A: key banao (agar nahi) + PUBLIC key dikhao. Yahin ruk jati hai.
#   bash repo-credentials.sh --deploy-key-added   # Part B: (GitHub pe read-only deploy key lagane KE BAAD)
#                                                 #         s3 pe declarative repository Secret + verify
# - Private key: s1 /root/argocd-repo-key/platform-gitops (700/600) — backup; KABHI repo mein nahi.
# - Secret mein key stdin/file se jati hai (command line pe nahi); kahin print nahi hoti.
# - GitHub ki SSH host keys Argo CD known_hosts mein hain aur GitHub ki published keys se match karti hain — check.
# Idempotent: key dobara nahi banti; Secret sirf farq ho to update.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../phase3/versions.sh
source "${SCRIPT_DIR}/../phase3/versions.sh"
log()  { echo "[$(hostname)] [repo-credentials] $*"; }
fail() { echo "[$(hostname)] [repo-credentials] ERROR: $*" >&2; exit 1; }
M=(kubectl --context "$MGMT_CONTEXT")
REPO_URL="git@github.com:goharch555/platform-gitops.git"
KEY_DIR="/root/argocd-repo-key"
KEY="${KEY_DIR}/platform-gitops"
SECRET_NAME="repo-platform-gitops"
[[ "$(hostname)" == "s1" ]] || fail "s1 pe chalao"

# --- Part A1: deploy key (sirf pehli dafa) ---------------------------------------------------------
sudo install -d -m 0700 -o root -g root "$KEY_DIR"
if ! sudo test -f "$KEY"; then
  sudo ssh-keygen -q -t ed25519 -N "" -C "argocd@lab-mgmt platform-gitops (read-only deploy key)" -f "$KEY"
  log "nayi ED25519 key: ${KEY}"
fi
sudo chmod 600 "$KEY"; sudo chmod 644 "${KEY}.pub"
[[ "$(sudo stat -c '%a' "$KEY_DIR") $(sudo stat -c '%a' "$KEY")" == "700 600" ]] || fail "key permissions ghalat"

# --- Part A2: GitHub host keys — Argo CD known_hosts vs GitHub ki published keys (api.github.com/meta) -----
gh_keys="$(curl -fsSL https://api.github.com/meta | jq -r '.ssh_keys[]' | sort)"
argo_keys="$("${M[@]}" -n "$ARGOCD_NS" get cm argocd-ssh-known-hosts-cm -o jsonpath='{.data.ssh_known_hosts}' \
             | awk '$1=="github.com"{print $2" "$3}' | sort)"
[[ -n "$argo_keys" ]] || fail "Argo CD known_hosts mein github.com nahi"
missing="$(comm -23 <(echo "$gh_keys") <(echo "$argo_keys"))"
extra="$(comm -13 <(echo "$gh_keys") <(echo "$argo_keys"))"
[[ -z "$missing" ]] || fail "GitHub ki ye host keys Argo CD known_hosts mein nahi: ${missing}"
[[ -z "$extra" ]] || fail "Argo CD known_hosts mein github.com ki ghair-published key: ${extra}"
log "known_hosts: github.com ki $(wc -l <<<"$argo_keys") host keys Argo CD mein hain, aur GitHub ki published keys se match ($(awk '{print $1}' <<<"$argo_keys" | xargs))"

if [[ "${1:-}" != "--deploy-key-added" ]]; then
  echo
  echo "=== PUBLIC key (GitHub → goharch555/platform-gitops → Settings → Deploy keys → Add, 'Allow write access' OFF):"
  sudo cat "${KEY}.pub"
  echo "=== fingerprint: $(sudo ssh-keygen -lf "${KEY}.pub")"
  log "RUK RAHI HOON: deploy key lagane ke baad: bash repo-credentials.sh --deploy-key-added"
  exit 0
fi

# --- Part B1: repo access test (isi deploy key se, s1 se) -------------------------------------------------
kh="$(mktemp)"; trap 'rm -f "$kh"' EXIT
awk '$1=="github.com"' <<<"$("${M[@]}" -n "$ARGOCD_NS" get cm argocd-ssh-known-hosts-cm -o jsonpath='{.data.ssh_known_hosts}')" > "$kh"
if ! sudo env GIT_SSH_COMMAND="ssh -i ${KEY} -o IdentitiesOnly=yes -o UserKnownHostsFile=${kh} -o StrictHostKeyChecking=yes" \
     git ls-remote "$REPO_URL" >/dev/null 2>&1; then
  fail "deploy key se ${REPO_URL} tak access nahi (deploy key lagi? repo mojood?)"
fi
log "deploy key se git ls-remote ${REPO_URL}: OK"

# --- Part B2: declarative repository Secret (key file se; stdin pe YAML) ------------------------------------
before="$("${M[@]}" -n "$ARGOCD_NS" get secret "$SECRET_NAME" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
sudo cat "$KEY" | "${M[@]}" -n "$ARGOCD_NS" create secret generic "$SECRET_NAME" \
    --from-literal=type=git --from-literal=url="$REPO_URL" --from-literal=name=platform-gitops \
    --from-file=sshPrivateKey=/dev/stdin --dry-run=client -o yaml \
  | "${M[@]}" label --local -f - argocd.argoproj.io/secret-type=repository app.kubernetes.io/managed-by=lab-infra-phase4 -o yaml \
  | "${M[@]}" apply -f - >/dev/null
after="$("${M[@]}" -n "$ARGOCD_NS" get secret "$SECRET_NAME" -o jsonpath='{.metadata.resourceVersion}')"
[[ "$before" == "$after" ]] && log "repository Secret ${SECRET_NAME} pehle se theek" || log "repository Secret ${SECRET_NAME} apply kiya"

# --- Verify -------------------------------------------------------------------------------------------------
"${M[@]}" -n "$ARGOCD_NS" get secret "$SECRET_NAME" -o json \
  | jq '{name: .metadata.name, labels: .metadata.labels, data_keys: (.data|keys), type: (.data.type|@base64d), url: (.data.url|@base64d)}'
st=""
for _ in $(seq 1 12); do
  st="$(argocd repo list --grpc-web -o json | jq -r --arg u "$REPO_URL" '.[] | select(.repo==$u) | .connectionState.status')"
  [[ "$st" == "Successful" ]] && break; sleep 5
done
argocd repo list --grpc-web
[[ "$st" == "Successful" ]] || fail "argocd repo list: ${REPO_URL} → ${st:-nahi mila}"
log "verify: ${REPO_URL} CONNECTION STATUS Successful (read-only deploy key, known_hosts verify)"
log "DONE"
