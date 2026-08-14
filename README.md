# remote-agents

KI-Coding-Sessions (Claude Code, Codex, …) auf einem Hetzner-Server. Jede Session:

- läuft in einem eigenen Docker-Container (Sandbox),
- hat einen eigenen frischen `git clone` (kein Worktree),
- lebt in einem eigenen herdr-Workspace und überlebt so das Schließen des Terminals,
- kann den Council-Workflow nutzen (Codex ist im Image).

## Teile

| Pfad | Was es ist |
| --- | --- |
| `docker/Dockerfile` | Session-Image: claude, codex, git, Tools |
| `docker/entrypoint.sh` | Container-Start: Logins kopieren, Deploy-Key, Clone |
| `bin/rc` | Session-Manager: `new` / `ls` / `attach` / `claude` / `shell` / `rm` / `login` / `build` |
| `rc-home.example/` | Vorlage für `~/.rc` auf dem Server |

## Server einrichten (einmalig)

```bash
# 1. Docker installieren (falls noch nicht da)
sudo apt install docker.io
sudo usermod -aG docker $USER   # danach neu einloggen

# 2. herdr + jq installieren
curl -fsSL https://herdr.dev/install.sh | sh
sudo apt-get install -y jq

# 3. Dieses Repo auf den Server holen und rc verfügbar machen
git clone <dieses-repo> ~/remote-agents
chmod +x ~/remote-agents/bin/rc ~/remote-agents/docker/entrypoint.sh
ln -s ~/remote-agents/bin/rc ~/.local/bin/rc   # oder in PATH deiner Wahl

# 4. Konfig-Ordner anlegen
mkdir -p ~/.rc/keys ~/.rc/seed
cp ~/remote-agents/rc-home.example/repos.conf ~/.rc/repos.conf
# repos.conf editieren: eine Zeile pro Repo

# 5. Logins einmal auf dem Server machen, dann als Seed ablegen
npm install -g @anthropic-ai/claude-code @openai/codex   # nur fürs Login auf dem Host
claude   # einloggen, dann beenden
codex    # einloggen, dann beenden
cp -r ~/.claude      ~/.rc/seed/claude
cp    ~/.claude.json ~/.rc/seed/claude.json
cp -r ~/.codex       ~/.rc/seed/codex
sudo apt install gh   # GitHub CLI, fürs Login auf dem Host
gh auth login         # GitHub-Login (für PRs/Issues in den Sessions)
cp -r ~/.config/gh   ~/.rc/seed/gh

# 6. Deploy-Keys ablegen (pro Repo, Name muss zu repos.conf passen)
# Key erzeugen: ssh-keygen -t ed25519 -f ~/.rc/keys/mein-repo.key -N ""
# Public-Key (.pub) bei GitHub als Deploy-Key eintragen (mit Schreibrecht!)

# 7. Sysbox installieren (gibt jeder Session ihr eigenes inneres Docker,
#    damit Testcontainers-Integrationstests in der Sandbox laufen können)
#    Achtung: vorher alle laufenden Sessions beenden (rc rm ...) und
#    alle Container entfernen, sonst bricht der Installer ab:
docker rm -f $(docker ps -a -q) 2>/dev/null || true
wget https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb
sudo apt install jq ./sysbox-ce_0.7.1.linux_amd64.deb

# 7b. AppArmor-Ausnahme für Sysbox (nötig ab Ubuntu 25.04):
#     Das fusermount3-Profil blockiert sonst Sysbox' FUSE-Mounts
#     (Symptom: "fusermount3: mount failed: Permission denied" beim rc new,
#     Details: https://github.com/nestybox/sysbox/issues/947)
echo '  mount fstype=fuse -> /var/lib/sysboxfs/**/,' | sudo tee -a /etc/apparmor.d/local/fusermount3
sudo apparmor_parser -r /etc/apparmor.d/fusermount3
sudo systemctl restart sysbox

# 8. Image bauen
rc build
```

## Täglicher Gebrauch

```bash
ssh server
rc new fix-login mein-repo   # neue Session: Sandbox + Clone + Claude läuft
rc issues                    # pro offenem Issue mit Label "ready-for-agent"
                             # eine Session starten (Branch issue-<NR>);
                             # schon Begonnenes wird übersprungen
rc issues --dry-run          # nur anzeigen, was starten würde
rc attach                    # herdr öffnen, Tabs = Sessions
# Detach in herdr: Ctrl+B Q  — alles läuft weiter
rc ls                        # was läuft gerade?
rc shell mein-repo-fix-login # Bash in der Sandbox
rc rm mein-repo-fix-login    # Session komplett aufräumen
rc login                     # bei "Login expired": einmal neu einloggen,
                             # alle Sessions übernehmen es automatisch
rc login codex               # dasselbe für den Codex-Login
```

Claude läuft im Container mit `--permission-mode auto`: Harmloses läuft ohne
Nachfrage durch, riskante Befehle erzeugen eine Rückfrage (erreichbar per
Remote Control). Bewusst nicht Bypass — der Container schützt zwar den Host,
enthält aber Deploy-Key und gh-Login, kann also nach draußen wirken.

## Logins (Claude & Codex): wie sie frisch bleiben

Alle Sessions teilen sich **eine** Credentials-Datei pro Tool: `~/.rc/auth/`
wird read-write in jeden Container gemountet, ein Sync-Loop im Container
gleicht die geteilten Dateien mit den lokalen ab (die neuere gewinnt):

- Claude: `auth/claude/.credentials.json` ↔ `~/.claude/.credentials.json`
- Codex:  `auth/codex/auth.json` ↔ `~/.codex/auth.json`

Erneuert eine Session ihr OAuth-Token, bekommen alle anderen das neue Token
automatisch — vorher hatte jede Session ihre eigene Kopie, und ein
Token-Refresh in einer Session machte die Kopien der anderen ungültig
("Login expired").

Kommt trotzdem mal "Login expired" (z.B. Login serverseitig widerrufen):

```bash
rc login         # Claude: auf dem Host einloggen; Sessions ziehen es in ~15 s nach
rc login codex   # Codex: dasselbe
```

Meckert eine laufende Claude-Instanz danach immer noch, dort Claude beenden
und mit `claude -c` (setzt die Unterhaltung fort) neu starten.
