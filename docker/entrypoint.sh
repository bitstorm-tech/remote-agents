#!/usr/bin/env bash
# Läuft einmal beim Container-Start:
# Seeds (Logins) kopieren, Deploy-Key einrichten, Repo clonen,
# dann den Container am Leben halten.
#
# Erwartete Env-Variablen (setzt das rc-Skript):
#   REPO_URL   z.B. git@github.com:joe/mein-repo.git
#   REPO_NAME  z.B. mein-repo
#   BRANCH     optional, z.B. fix-login
#   GIT_USER_NAME / GIT_USER_EMAIL  optional
#
# Erwartete Mounts (read-only):
#   /seed/claude       -> wird nach ~/.claude kopiert (Login/Settings)
#   /seed/claude.json  -> wird nach ~/.claude.json kopiert
#   /seed/codex        -> wird nach ~/.codex kopiert (Codex-Login)
#   /deploy_key        -> SSH-Deploy-Key fürs Repo (eigener Mount,
#                         darf nicht in /seed liegen: /seed ist read-only)
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# --- Logins aus den Seeds kopieren (kopieren, nicht mounten,
# --- damit parallele Sessions sich nicht in die Quere kommen) ---
if [ -d /seed/claude ]; then
    mkdir -p "$HOME/.claude"
    cp -r /seed/claude/. "$HOME/.claude/"
    log "Claude-Login kopiert"
fi
if [ -f /seed/claude.json ]; then
    cp /seed/claude.json "$HOME/.claude.json"
fi
if [ -d /seed/codex ]; then
    mkdir -p "$HOME/.codex"
    cp -r /seed/codex/. "$HOME/.codex/"
    log "Codex-Login kopiert"
fi

# --- Statusbar einrichten (Skript kommt aus dem Image) ---
mkdir -p "$HOME/.claude"
cp /usr/local/share/statusline.sh "$HOME/.claude/statusline.sh"
chmod +x "$HOME/.claude/statusline.sh"
settings="$HOME/.claude/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
tmp="$(mktemp)"
jq '.statusLine = {type: "command", command: "~/.claude/statusline.sh", padding: 0}' \
    "$settings" > "$tmp" && mv "$tmp" "$settings"
log "Statusbar eingerichtet"

# --- SSH / Deploy-Key ---
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
    log "Deploy-Key eingerichtet"
fi

# --- Git-Identität ---
git config --global user.name  "${GIT_USER_NAME:-Josef Bauer}"
git config --global user.email "${GIT_USER_EMAIL:-josef.bauer.1st@gmail.com}"
git config --global init.defaultBranch main

# --- Repo clonen (eigener, voller Workspace pro Session) ---
if [ -z "${REPO_URL:-}" ] || [ -z "${REPO_NAME:-}" ]; then
    log "FEHLER: REPO_URL/REPO_NAME nicht gesetzt"
    exit 1
fi
if [ ! -d "/work/$REPO_NAME/.git" ]; then
    log "Clone $REPO_URL -> /work/$REPO_NAME"
    git clone "$REPO_URL" "/work/$REPO_NAME"
fi
cd "/work/$REPO_NAME"
if [ -n "${BRANCH:-}" ]; then
    # Branch übernehmen, falls es ihn remote schon gibt; sonst neu anlegen
    if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
        git checkout "$BRANCH"
    else
        git checkout -b "$BRANCH"
    fi
    log "Branch: $BRANCH"
fi

# Signal für das rc-Skript: alles bereit
touch /work/.ready
log "Bereit. Warte auf docker exec ..."

# Container am Leben halten; die eigentliche Arbeit passiert per docker exec
exec sleep infinity
