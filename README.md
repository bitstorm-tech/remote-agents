# remote-agents

AI coding sessions (Claude Code, Codex, …) on a Hetzner server. Each session:

- runs in its own Docker container (sandbox),
- has its own fresh `git clone` (no worktree),
- lives in its own herdr workspace and thus survives closing the terminal,
- can use the council workflow (Codex is in the image).

## Parts

| Path | What it is |
| --- | --- |
| `docker/Dockerfile` | Session image: claude, codex, git, tools |
| `docker/entrypoint.sh` | Container start: copy logins, deploy key, clone |
| `bin/rc` | Session manager: `new` / `issues` / `ls` / `attach` / `claude` / `shell` / `rm` / `login` / `build` |
| `rc-home.example/` | Template for `~/.rc` on the server |

## Server setup (one-time)

```bash
# 1. Install Docker (if not there yet)
sudo apt install docker.io
sudo usermod -aG docker $USER   # log in again afterwards

# 2. Install herdr + jq
curl -fsSL https://herdr.dev/install.sh | sh
sudo apt-get install -y jq

# 3. Get this repo onto the server and make rc available
git clone <this-repo> ~/remote-agents
chmod +x ~/remote-agents/bin/rc ~/remote-agents/docker/entrypoint.sh
ln -s ~/remote-agents/bin/rc ~/.local/bin/rc   # or any PATH dir you like

# 4. Create the config directory
mkdir -p ~/.rc/keys ~/.rc/seed
cp ~/remote-agents/rc-home.example/repos.conf ~/.rc/repos.conf
# edit repos.conf: one line per repo

# 5. Do the logins once on the server, then store them as seeds
npm install -g @anthropic-ai/claude-code @openai/codex   # only for the host login
claude   # log in, then quit
codex    # log in, then quit
cp -r ~/.claude      ~/.rc/seed/claude
cp    ~/.claude.json ~/.rc/seed/claude.json
cp -r ~/.codex       ~/.rc/seed/codex
sudo apt install gh   # GitHub CLI, for the host login
gh auth login         # GitHub login (for PRs/issues in the sessions)
cp -r ~/.config/gh   ~/.rc/seed/gh

# 6. Store deploy keys (per repo, name must match repos.conf)
# Create a key: ssh-keygen -t ed25519 -f ~/.rc/keys/my-repo.key -N ""
# Register the public key (.pub) on GitHub as a deploy key (with write access!)

# 7. Install Sysbox (gives every session its own inner Docker,
#    so Testcontainers integration tests can run inside the sandbox)
#    Attention: end all running sessions first (rc rm ...) and remove
#    all containers, otherwise the installer aborts:
docker rm -f $(docker ps -a -q) 2>/dev/null || true
wget https://github.com/nestybox/sysbox/releases/download/v0.7.1/sysbox-ce_0.7.1.linux_amd64.deb
sudo apt install jq ./sysbox-ce_0.7.1.linux_amd64.deb

# 7b. AppArmor exception for Sysbox (needed as of Ubuntu 25.04):
#     the fusermount3 profile otherwise blocks Sysbox's FUSE mounts
#     (symptom: "fusermount3: mount failed: Permission denied" during rc new,
#     details: https://github.com/nestybox/sysbox/issues/947)
echo '  mount fstype=fuse -> /var/lib/sysboxfs/**/,' | sudo tee -a /etc/apparmor.d/local/fusermount3
sudo apparmor_parser -r /etc/apparmor.d/fusermount3
sudo systemctl restart sysbox

# 8. Build the image
rc build
```

## Daily use

```bash
ssh server
rc new fix-login my-repo     # new session: sandbox + clone + Claude running
rc issues                    # start a session per open issue labeled
                             # "ready-for-agent" (branch issue-<NO>-<slug>,
                             # slug from the issue title);
                             # sub-issues and work in progress: skipped
rc issues list               # only show what would start
rc attach                    # open herdr, tabs = sessions
# Detach in herdr: Ctrl+B Q  — everything keeps running
rc ls                        # what's running right now?
rc shell my-repo-fix-login   # bash inside the sandbox
rc rm my-repo-fix-login      # clean up the session completely
rc login                     # on "Login expired": log in once,
                             # all sessions pick it up automatically
rc login codex               # same for the Codex login
```

Claude runs in the container with `--permission-mode auto`: harmless things
run without asking, risky commands trigger a question (reachable via Remote
Control). Deliberately not bypass — the container protects the host, but it
holds the deploy key and gh login, so it can act on the outside world.

## Logins (Claude & Codex): how they stay fresh

All sessions share **one** credentials file per tool: `~/.rc/auth/` is
mounted read-write into every container, and a sync loop in the container
reconciles the shared files with the local ones (the newer one wins):

- Claude: `auth/claude/.credentials.json` ↔ `~/.claude/.credentials.json`
- Codex:  `auth/codex/auth.json` ↔ `~/.codex/auth.json`

When one session refreshes its OAuth token, all others get the new token
automatically — previously every session had its own copy, and a token
refresh in one session invalidated the others' copies ("Login expired").

If "Login expired" still shows up (e.g. login revoked server-side):

```bash
rc login         # Claude: log in on the host; sessions pick it up in ~15 s
rc login codex   # Codex: same
```

If a running Claude instance still complains afterwards, quit Claude there
and restart it with `claude -c` (continues the conversation).
