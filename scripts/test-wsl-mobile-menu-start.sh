#!/usr/bin/env bash
set -euo pipefail

menu_session="shell-menu-start-$$"
session_title="start-menu-check-$$"
created_session=''

cleanup() {
  tmux kill-session -t "$menu_session" >/dev/null 2>&1 || true
  if [[ -n "${created_session// }" ]]; then
    tmux kill-session -t "$created_session" >/dev/null 2>&1 || true
  fi

  SESSION_CATALOG_PATH="$(wslpath "$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')")/agent-handoff/session-catalog.json" \
  SESSION_TITLE="$session_title" \
  SESSION_NAME="$created_session" \
  node <<'NODE' >/dev/null 2>&1 || true
const fs = require('fs');

const catalogPath = process.env.SESSION_CATALOG_PATH;
const sessionTitle = process.env.SESSION_TITLE;
const sessionName = process.env.SESSION_NAME;

if (!fs.existsSync(catalogPath)) {
  process.exit(0);
}

const raw = fs.readFileSync(catalogPath, 'utf8').trim();
const entries = raw ? JSON.parse(raw) : [];
const filtered = (Array.isArray(entries) ? entries : [entries]).filter((entry) => {
  return String(entry.title || '') !== sessionTitle && String(entry.session_name || '') !== sessionName;
});
fs.writeFileSync(catalogPath, `${JSON.stringify(filtered, null, 2)}\n`);
NODE
}

trap cleanup EXIT

tmux new-session -d -s "$menu_session" -c /mnt/d/ghws 'env AI_AGENT_SESSION_NO_ATTACH=1 /mnt/d/ghws/scripts/wsl-agent-mobile-menu.sh'
sleep 1

tmux send-keys -t "$menu_session" '1' C-m
sleep 1
tmux send-keys -t "$menu_session" 'shell' C-m
sleep 1
tmux send-keys -t "$menu_session" "$session_title" C-m
sleep 1
tmux send-keys -t "$menu_session" '/mnt/d/ghws/scripts' C-m
sleep 2

pane_output="$(tmux capture-pane -pt "$menu_session" -S -200)"
created_session="$(printf '%s\n' "$pane_output" | sed -n 's/.*Session ready: \([^[:space:]]\+\).*/\1/p' | tail -n 1)"

[[ -n "${created_session// }" ]]
printf '%s\n' "$pane_output" | grep -q 'Session ready:'
printf '%s\n' "$pane_output" | grep -q "$session_title"

tmux display-message -p -t "$created_session" '#{pane_current_path}' | grep -qx '/mnt/d/ghws/scripts'

SESSION_CATALOG_PATH="$(wslpath "$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')")/agent-handoff/session-catalog.json" \
SESSION_TITLE="$session_title" \
SESSION_NAME="$created_session" \
node <<'NODE'
const fs = require('fs');

const catalogPath = process.env.SESSION_CATALOG_PATH;
const sessionTitle = process.env.SESSION_TITLE;
const sessionName = process.env.SESSION_NAME;

const raw = fs.readFileSync(catalogPath, 'utf8').trim();
const entries = raw ? JSON.parse(raw) : [];
const items = Array.isArray(entries) ? entries : [entries];
const entry = items.find((item) => String(item.title || '') === sessionTitle && String(item.session_name || '') === sessionName);

if (!entry) {
  console.error(`Missing catalog entry for ${sessionTitle}`);
  process.exit(1);
}

if (String(entry.working_directory_windows || '') !== 'D:\\ghws\\scripts') {
  console.error(`Unexpected working_directory_windows: ${entry.working_directory_windows}`);
  process.exit(1);
}
NODE

printf 'PASS\n'
