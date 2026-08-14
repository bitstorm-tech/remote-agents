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
#   /seed/gh           -> wird nach ~/.config/gh kopiert (gh-Login)
#   /deploy_key        -> SSH-Deploy-Key fürs Repo (eigener Mount,
#                         darf nicht in /seed liegen: /seed ist read-only)
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# --- Läuft der Container als root (= Sysbox-Modus)? Dann inneres Docker
# --- starten und danach als normaler User "node" von vorn beginnen. ---
if [ "$(id -u)" = "0" ]; then
    log "Sysbox-Modus: starte inneres Docker (dockerd) ..."
    dockerd > /var/log/dockerd.log 2>&1 &
    for _ in $(seq 1 30); do
        [ -S /var/run/docker.sock ] && break
        sleep 1
    done
    if [ -S /var/run/docker.sock ]; then
        log "Inneres Docker läuft"
    else
        log "WARNUNG: dockerd kam nicht hoch (Log: /var/log/dockerd.log)"
    fi
    export HOME=/home/node USER=node
    exec gosu node "$0" "$@"
fi

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
if [ -d /seed/gh ]; then
    mkdir -p "$HOME/.config/gh"
    cp -r /seed/gh/. "$HOME/.config/gh/"
    log "gh-Login kopiert"
fi

# --- Statusbar + ELI5-Output-Style einrichten (kommen aus dem Image) ---
mkdir -p "$HOME/.claude/output-styles"
cp /usr/local/share/statusline.sh "$HOME/.claude/statusline.sh"
chmod +x "$HOME/.claude/statusline.sh"
cp /usr/local/share/eli5.md "$HOME/.claude/output-styles/eli5.md"
settings="$HOME/.claude/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
tmp="$(mktemp)"
jq '.statusLine = {type: "command", command: "~/.claude/statusline.sh", padding: 0}
    | .outputStyle = "ELI5"
    | .remoteControlAtStartup = true' \
    "$settings" > "$tmp" && mv "$tmp" "$settings"
log "Statusbar + ELI5-Style + Remote Control eingerichtet"

# --- Trust-Dialog ("Ordner vertrauen?") vorab beantworten:
# --- der Container ist eine Wegwerf-Sandbox, die Frage wäre nur Klick-Arbeit ---
claude_json="$HOME/.claude.json"
[ -f "$claude_json" ] || echo '{}' > "$claude_json"
tmp="$(mktemp)"
jq --arg dir "/work/${REPO_NAME:-}" \
    'if $dir != "/work/" then
         .projects[$dir] = ((.projects[$dir] // {}) + {hasTrustDialogAccepted: true})
     else . end' \
    "$claude_json" > "$tmp" && mv "$tmp" "$claude_json"
log "Trust-Dialog vorab bestätigt"

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
