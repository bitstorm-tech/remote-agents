# Session-Image: eine Sandbox pro Coding-Session.
# Enthält claude, codex, git und Basis-Tooling.
FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client ca-certificates curl wget jq ripgrep \
        less vim nano procps unzip build-essential python3 \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code @openai/codex

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /work && chown node:node /work

# uid 1000 — passt zum Standard-User auf dem Host, damit
# read-only gemountete Seeds/Keys lesbar sind.
USER node
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
