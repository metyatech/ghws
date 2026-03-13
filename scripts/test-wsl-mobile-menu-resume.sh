#!/usr/bin/env bash
set -euo pipefail

menu_session="shell-menu-runner-$$"
target_session="shell-resume-check-$$"

cleanup() {
  tmux kill-session -t "$menu_session" >/dev/null 2>&1 || true
  tmux kill-session -t "$target_session" >/dev/null 2>&1 || true
}

trap cleanup EXIT

tmux new-session -d -s "$menu_session" -c /mnt/d/ghws 'env AI_AGENT_SESSION_NO_ATTACH=1 /mnt/d/ghws/scripts/wsl-agent-mobile-menu.sh'
sleep 1

tmux new-session -d -s "$target_session" -c /mnt/d/ghws
sleep 1

tmux send-keys -t "$menu_session" '2' C-m
sleep 1
tmux send-keys -t "$menu_session" '1' C-m
sleep 1

pane_output="$(tmux capture-pane -pt "$menu_session" -S -200)"

printf '%s\n' "$pane_output" | grep -q '^\[1\] '
printf '%s\n' "$pane_output" | grep -q 'resume-check'
printf '%s\n' "$pane_output" | grep -q "Session ready: $target_session"

printf 'PASS\n'
