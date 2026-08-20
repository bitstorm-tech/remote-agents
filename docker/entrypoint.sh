#!/usr/bin/env bash
# Runs once at container start:
# copy seeds (logins), set up the deploy key, clone the repo,
# then keep the container alive.
#
# Expected env variables (set by the rc script):
#   REPO_URL   e.g. git@github.com:joe/my-repo.git
#   REPO_NAME  e.g. my-repo
#   BRANCH     optional, e.g. fix-login
#   GIT_USER_NAME / GIT_USER_EMAIL  optional
#
# Expected mounts (read-only):
#   /seed/claude       -> copied to ~/.claude (login/settings)
#   /seed/claude.json  -> copied to ~/.claude.json
#   /seed/codex        -> copied to ~/.codex (Codex login)
#   /seed/gh           -> copied to ~/.config/gh (gh login)
#   /deploy_key        -> SSH deploy key for the repo (separate mount,
#                         must not live in /seed: /seed is read-only)
#
# Expected mount (read-write):
#   /auth/claude       -> shared Claude credentials for all sessions
#                         (a sync loop keeps ~/.claude/.credentials.json
#                         and /auth/claude/.credentials.json mutually
#                         up to date — the newer file wins)
#   /auth/codex        -> same for Codex (~/.codex/auth.json)
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# --- Is the container running as root (= Sysbox mode)? Then start the
# --- inner Docker and restart from the top as the normal user "node". ---
if [ "$(id -u)" = "0" ]; then
    log "Sysbox mode: starting inner Docker (dockerd) ..."
    dockerd > /var/log/dockerd.log 2>&1 &
    for _ in $(seq 1 30); do
        [ -S /var/run/docker.sock ] && break
        sleep 1
    done
    if [ -S /var/run/docker.sock ]; then
        log "Inner Docker is running"
    else
        log "WARNING: dockerd did not come up (log: /var/log/dockerd.log)"
    fi
    export HOME=/home/node USER=node
    exec gosu node "$0" "$@"
fi

# --- Copy logins from the seeds (copy, don't mount,
# --- so parallel sessions don't get in each other's way) ---
if [ -d /seed/claude ]; then
    mkdir -p "$HOME/.claude"
    cp -r /seed/claude/. "$HOME/.claude/"
    log "Claude login copied"
fi
if [ -f /seed/claude.json ]; then
    cp /seed/claude.json "$HOME/.claude.json"
fi
if [ -d /seed/codex ]; then
    mkdir -p "$HOME/.codex"
    cp -r /seed/codex/. "$HOME/.codex/"
    log "Codex login copied"
fi
if [ -d /seed/gh ]; then
    mkdir -p "$HOME/.config/gh"
    cp -r /seed/gh/. "$HOME/.config/gh/"
    log "gh login copied"
fi

# --- Turn off Codex's own sandbox: Landlock is not available inside
# --- Docker, so Codex cannot even read files. The container itself is
# --- the sandbox, so nothing is lost. ---
mkdir -p "$HOME/.codex"
codex_cfg="$HOME/.codex/config.toml"
if ! grep -q '^sandbox_mode' "$codex_cfg" 2>/dev/null; then
    # Prepend, don't append: a top-level TOML key appended after a
    # [section] header would land inside that section
    tmp="$(mktemp)"
    { echo 'sandbox_mode = "danger-full-access"'; cat "$codex_cfg" 2>/dev/null; } > "$tmp"
    mv "$tmp" "$codex_cfg"
    log "Codex sandbox disabled (container is the sandbox)"
fi

# --- Shared credentials (/auth): Claude + Codex ---
# Without this, every session would have its own token copy. When one
# session refreshes its token, the server rotates the refresh token — the
# other sessions' copies become invalid ("Login expired"). Hence: one
# shared file per tool on the host, shared by all sessions (and "rc login").
AUTH_PAIRS="/auth/claude/.credentials.json:$HOME/.claude/.credentials.json
/auth/codex/auth.json:$HOME/.codex/auth.json"
copy_cred() {
    # Copy atomically (nobody may ever read half a JSON file) and preserve
    # the mtime — the sync loop compares with -nt, a fresh timestamp
    # would trigger endless back-and-forth copying.
    local src="$1" dst="$2" tmp
    tmp="$(mktemp "$(dirname "$dst")/.cred.XXXXXX")" || return 1
    cp -p "$src" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$dst"
}
sync_pair() {
    # "|| true": a single failed copy attempt (e.g. mount briefly busy)
    # must not kill the caller (set -e)
    local shared="$1" local_file="$2"
    if [ -f "$shared" ] && [ "$shared" -nt "$local_file" ]; then
        copy_cred "$shared" "$local_file" || true
    elif [ -f "$local_file" ] && [ "$local_file" -nt "$shared" ]; then
        copy_cred "$local_file" "$shared" || true
    fi
}
if [ -d /auth ]; then
    mkdir -p /auth/claude /auth/codex "$HOME/.claude" "$HOME/.codex"
    while IFS=: read -r shared local_file; do
        if [ -f "$shared" ]; then
            # At startup the shared file always wins over the seed copy
            copy_cred "$shared" "$local_file"
            log "Adopted shared credentials: $shared"
        elif [ -f "$local_file" ]; then
            # First session: create the shared file from the seed login
            copy_cred "$local_file" "$shared"
            log "Created shared credentials from seed: $shared"
        fi
    done <<<"$AUTH_PAIRS"
    (
        while sleep 15; do
            while IFS=: read -r shared local_file; do
                sync_pair "$shared" "$local_file"
            done <<<"$AUTH_PAIRS"
        done
    ) &
    log "Credentials sync running (claude + codex)"
fi

# --- Set up statusbar + Concise output style (statusline comes from the image) ---
mkdir -p "$HOME/.claude"
cp /usr/local/share/statusline.sh "$HOME/.claude/statusline.sh"
chmod +x "$HOME/.claude/statusline.sh"
settings="$HOME/.claude/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
tmp="$(mktemp)"
jq '.statusLine = {type: "command", command: "~/.claude/statusline.sh", padding: 0}
    | .outputStyle = "Concise"
    | .remoteControlAtStartup = true' \
    "$settings" > "$tmp" && mv "$tmp" "$settings"
log "Statusbar + Concise style + Remote Control set up"

# --- Pre-answer the trust dialog ("Trust this folder?"):
# --- the container is a throwaway sandbox, the question would just be click work ---
claude_json="$HOME/.claude.json"
[ -f "$claude_json" ] || echo '{}' > "$claude_json"
tmp="$(mktemp)"
jq --arg dir "/work/${REPO_NAME:-}" \
    'if $dir != "/work/" then
         .projects[$dir] = ((.projects[$dir] // {}) + {hasTrustDialogAccepted: true})
     else . end' \
    "$claude_json" > "$tmp" && mv "$tmp" "$claude_json"
log "Trust dialog pre-accepted"

# --- SSH / deploy key ---
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -f /deploy_key ]; then
    cp /deploy_key "$HOME/.ssh/id_deploy"
    chmod 600 "$HOME/.ssh/id_deploy"
    cat > "$HOME/.ssh/config" <<EOF
Host *
    IdentityFile ~/.ssh/id_deploy
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
    chmod 600 "$HOME/.ssh/config"
    log "Deploy key set up"
fi

# --- Git identity ---
git config --global user.name  "${GIT_USER_NAME:-Josef Bauer}"
git config --global user.email "${GIT_USER_EMAIL:-josef.bauer.1st@gmail.com}"
git config --global init.defaultBranch main

# --- Clone the repo (each session gets its own full workspace) ---
if [ -z "${REPO_URL:-}" ] || [ -z "${REPO_NAME:-}" ]; then
    log "ERROR: REPO_URL/REPO_NAME not set"
    exit 1
fi
if [ ! -d "/work/$REPO_NAME/.git" ]; then
    log "Clone $REPO_URL -> /work/$REPO_NAME"
    git clone "$REPO_URL" "/work/$REPO_NAME"
fi
cd "/work/$REPO_NAME"
if [ -n "${BRANCH:-}" ]; then
    # Take over the branch if it already exists remotely; otherwise create it
    if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
        git checkout "$BRANCH"
    else
        git checkout -b "$BRANCH"
    fi
    log "Branch: $BRANCH"
fi

# Signal for the rc script: everything is ready
touch /work/.ready
log "Ready. Waiting for docker exec ..."

# Keep the container alive; the actual work happens via docker exec
exec sleep infinity
