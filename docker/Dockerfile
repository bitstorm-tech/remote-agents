# Session-Image: eine Sandbox pro Coding-Session.
# Enthält claude, codex, git und Basis-Tooling.
FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client ca-certificates curl wget jq ripgrep \
        less vim nano procps unzip build-essential python3 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @openai/codex

# GitHub CLI (offizielles apt-Repo)
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        > /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY statusline.sh /usr/local/share/statusline.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/share/statusline.sh \
    && mkdir -p /work && chown node:node /work

# uid 1000 — passt zum Standard-User auf dem Host, damit
# read-only gemountete Seeds/Keys lesbar sind.
USER node
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
