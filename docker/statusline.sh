#!/bin/bash
# Claude Code statusbar: directory | branch *changes | model (effort) | context%
input=$(cat)
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')
effort=$(echo "$input" | jq -r '.effort.level // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // "0"')

git_branch=$(cd "$current_dir" && git branch --show-current 2>/dev/null || echo '')
git_status=$(cd "$current_dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
dir_name=$(basename "$current_dir")

# Extract thinking budget from ~/.claude/settings.json (e.g. "opus[1m]" -> "1m")
thinking_budget=$(jq -r '.model // ""' "$HOME/.claude/settings.json" 2>/dev/null | grep -oE '\[[^]]+\]' | tr -d '[]')

# Output: Directory name (blue)
printf '\033[94m%s\033[0m' "$dir_name"

# Output: Git branch (green) if exists
if [ -n "$git_branch" ]; then
  printf ' \033[90m|\033[0m \033[92m%s\033[0m' "$git_branch"
fi

# Output: Uncommitted changes count (yellow) if any
if [ "$git_status" -gt 0 ]; then
  printf ' \033[93m*%s\033[0m' "$git_status"
fi

# Output: Model name (magenta), with effort level if present
if [ -n "$effort" ]; then
  printf ' \033[90m|\033[0m \033[95m%s\033[0m \033[90m(%s)\033[0m' "$model" "$effort"
else
  printf ' \033[90m|\033[0m \033[95m%s\033[0m' "$model"
fi

# Output: Context usage (cyan), with thinking budget if set
if [ -n "$thinking_budget" ]; then
  printf ' \033[90m|\033[0m \033[96m%s%% used\033[0m \033[90m(\033[33mthinking: %s\033[90m)\033[0m' "$used_pct" "$thinking_budget"
else
  printf ' \033[90m|\033[0m \033[96m%s%% used\033[0m' "$used_pct"
fi
