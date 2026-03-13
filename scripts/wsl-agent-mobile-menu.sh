#!/usr/bin/env bash
set -euo pipefail

declare -A STARTUP_COMMANDS=(
  [codex]="${HOME}/.local/bin/codex"
  [claude]="${HOME}/.local/bin/claude"
  [gemini]="${HOME}/.local/bin/gemini"
  [shell]=''
)

declare -A HEALTHCHECK_COMMANDS=(
  [codex]="${HOME}/.local/bin/codex --version"
  [claude]="${HOME}/.local/bin/claude --version"
  [gemini]="${HOME}/.local/bin/gemini --version"
  [shell]=''
)

WINDOWS_USERPROFILE="$(cmd.exe /c "echo %USERPROFILE%" < /dev/null 2>/dev/null | tr -d '\r')"
SESSION_CATALOG_PATH="$(wslpath "$WINDOWS_USERPROFILE")/agent-handoff/session-catalog.json"
DEFAULT_WORKSPACE_ROOT='/mnt/d/ghws'

trim_cr() {
  tr -d '\r'
}

get_windows_env() {
  local variable_name="$1"
  local value

  value="$(cmd.exe /c "echo %${variable_name}%" 2>/dev/null | trim_cr || true)"
  if [[ "$value" == "%${variable_name}%" ]]; then
    value=''
  fi
  printf '%s\n' "$value"
}

no_attach_requested() {
  [[ -n "${AI_AGENT_SESSION_NO_ATTACH:-}" ]] && return 0
  [[ -n "$(get_windows_env 'AI_AGENT_SESSION_NO_ATTACH')" ]] && return 0
  return 1
}

usage() {
  cat <<'EOF'
Usage:
  wsl-agent-mobile-menu.sh
  wsl-agent-mobile-menu.sh menu
  wsl-agent-mobile-menu.sh list
  wsl-agent-mobile-menu.sh start <codex|claude|gemini|shell> [title...]
  wsl-agent-mobile-menu.sh resume <session-name>
  wsl-agent-mobile-menu.sh shell
  wsl-agent-mobile-menu.sh --help
EOF
}

normalize_label() {
  local value="$1"
  local safe
  safe="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$safe" ]]; then
    printf 'Session name is empty after normalization.\n' >&2
    return 1
  fi
  printf '%s\n' "$safe"
}

ensure_session_catalog_file() {
  local catalog_dir
  catalog_dir="$(dirname "$SESSION_CATALOG_PATH")"
  mkdir -p "$catalog_dir"
  [[ -f "$SESSION_CATALOG_PATH" ]] || printf '[]\n' > "$SESSION_CATALOG_PATH"
}

upsert_session_catalog_entry() {
  local session_name="$1"
  local session_type="$2"
  local session_title="${3:-}"
  local working_directory_windows="${4:-}"
  ensure_session_catalog_file

  SESSION_CATALOG_PATH="$SESSION_CATALOG_PATH" \
  SESSION_NAME="$session_name" \
  SESSION_TYPE="$session_type" \
  SESSION_TITLE="$session_title" \
  WORKING_DIRECTORY_WINDOWS="$working_directory_windows" \
  node <<'NODE'
const fs = require('fs');

const catalogPath = process.env.SESSION_CATALOG_PATH;
const sessionName = process.env.SESSION_NAME;
const sessionType = process.env.SESSION_TYPE;
const sessionTitle = (process.env.SESSION_TITLE || '').trim();
const workingDirectoryWindows = (process.env.WORKING_DIRECTORY_WINDOWS || '').trim();
const nowUtc = new Date().toISOString();

let entries = [];
try {
  const raw = fs.readFileSync(catalogPath, 'utf8').trim();
  if (raw) {
    const parsed = JSON.parse(raw);
    entries = Array.isArray(parsed) ? parsed : [parsed];
  }
} catch (error) {
  entries = [];
}

const existingIndex = entries.findIndex((entry) => String(entry.session_name) === sessionName);
if (existingIndex >= 0) {
  const entry = { ...entries[existingIndex], session_type: sessionType, updated_utc: nowUtc };
  if (sessionTitle) {
    entry.title = sessionTitle;
  }
  if (workingDirectoryWindows) {
    entry.working_directory_windows = workingDirectoryWindows;
  }
  entries[existingIndex] = entry;
} else {
  entries.push({
    session_name: sessionName,
    session_type: sessionType,
    title: sessionTitle,
    working_directory_windows: workingDirectoryWindows,
    created_utc: nowUtc,
    updated_utc: nowUtc,
  });
}

fs.writeFileSync(catalogPath, `${JSON.stringify(entries, null, 2)}\n`);
NODE
}

get_session_title_from_catalog() {
  local session_name="$1"
  ensure_session_catalog_file

  SESSION_CATALOG_PATH="$SESSION_CATALOG_PATH" \
  SESSION_NAME="$session_name" \
  node <<'NODE'
const fs = require('fs');

const catalogPath = process.env.SESSION_CATALOG_PATH;
const sessionName = process.env.SESSION_NAME;

try {
  const raw = fs.readFileSync(catalogPath, 'utf8').trim();
  if (!raw) {
    process.exit(0);
  }

  const parsed = JSON.parse(raw);
  const entries = Array.isArray(parsed) ? parsed : [parsed];
  const entry = entries.find((item) => String(item.session_name) === sessionName);
  if (entry && typeof entry.title === 'string' && entry.title.trim()) {
    process.stdout.write(entry.title.trim());
  }
} catch (error) {
  process.exit(0);
}
NODE
}

get_working_directory_from_catalog() {
  local session_name="$1"
  ensure_session_catalog_file

  SESSION_CATALOG_PATH="$SESSION_CATALOG_PATH" \
  SESSION_NAME="$session_name" \
  node <<'NODE'
const fs = require('fs');

const catalogPath = process.env.SESSION_CATALOG_PATH;
const sessionName = process.env.SESSION_NAME;

try {
  const raw = fs.readFileSync(catalogPath, 'utf8').trim();
  if (!raw) {
    process.exit(0);
  }

  const parsed = JSON.parse(raw);
  const entries = Array.isArray(parsed) ? parsed : [parsed];
  const entry = entries.find((item) => String(item.session_name) === sessionName);
  if (entry && typeof entry.working_directory_windows === 'string' && entry.working_directory_windows.trim()) {
    process.stdout.write(entry.working_directory_windows.trim());
  }
} catch (error) {
  process.exit(0);
}
NODE
}

new_auto_session_label() {
  printf 'auto-%s-%s\n' "$(date '+%Y%m%d-%H%M%S')" "$(cut -c1-4 /proc/sys/kernel/random/uuid)"
}

pretty_agent_label() {
  local session_type="$1"
  case "$session_type" in
    codex) printf 'Codex' ;;
    claude) printf 'Claude' ;;
    gemini) printf 'Gemini' ;;
    shell) printf 'Shell' ;;
    *) printf 'Session' ;;
  esac
}

resolve_working_directory() {
  local input_path="${1:-}"
  local resolved_path

  if [[ -n "${input_path// }" ]]; then
    resolved_path="$(realpath -m "$input_path")"
  else
    resolved_path="$DEFAULT_WORKSPACE_ROOT"
  fi

  [[ -d "$resolved_path" ]] || {
    printf 'Working directory not found: %s\n' "$resolved_path" >&2
    return 1
  }

  printf '%s\n' "$resolved_path"
}

convert_wsl_to_windows_path() {
  local wsl_path="$1"
  wslpath -a -w "$wsl_path" | tr -d '\r'
}

get_session_working_directory_windows() {
  local session_name="$1"
  local catalog_directory pane_directory

  catalog_directory="$(get_working_directory_from_catalog "$session_name")"
  if [[ -n "${catalog_directory// }" ]]; then
    printf '%s\n' "$catalog_directory"
    return 0
  fi

  pane_directory="$(tmux display-message -p -t "$session_name" '#{pane_current_path}' 2>/dev/null || true)"
  if [[ -n "${pane_directory// }" ]]; then
    convert_wsl_to_windows_path "$pane_directory"
  fi
}

format_local_timestamp() {
  local epoch_seconds="$1"
  if [[ -z "$epoch_seconds" || ! "$epoch_seconds" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  date -d "@$epoch_seconds" '+%Y-%m-%d %H:%M'
}

get_session_preview_text() {
  local session_name="$1"
  tmux capture-pane -pt "$session_name" -S -40 2>/dev/null | awk 'BEGIN { line = ""; found = 0 } NF { line = $0; found = 1 } END { if (found) print line }'
}

preview_is_meaningful() {
  local preview_text="$1"
  [[ -n "${preview_text// }" ]] || return 1
  [[ "$preview_text" =~ ^[^[:space:]@]+@[^:]+:.*[\$\#]$ ]] && return 1
  return 0
}

get_display_title() {
  local session_name="$1"
  local session_type="$2"
  local session_label="$3"
  local created_unix="$4"
  local preview_text="$5"
  local catalog_title agent_label

  catalog_title="$(get_session_title_from_catalog "$session_name")"
  if [[ -n "${catalog_title// }" ]]; then
    printf '%s\n' "$catalog_title"
    return 0
  fi

  if [[ -n "${session_label// }" && ! "$session_label" =~ ^auto- ]]; then
    printf '%s\n' "$session_label"
    return 0
  fi

  if preview_is_meaningful "$preview_text"; then
    printf '%s\n' "$preview_text"
    return 0
  fi

  agent_label="$(pretty_agent_label "$session_type")"
  printf '%s %s\n' "$agent_label" "$(format_local_timestamp "$created_unix")"
}

split_session_name() {
  local name="$1"
  if [[ "$name" =~ ^(codex|claude|gemini|shell)-(.+)$ ]]; then
    printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi

  printf 'unknown|%s\n' "$name"
}

command_is_healthy() {
  local command_text="$1"
  if [[ -z "$command_text" ]]; then
    return 1
  fi

  bash -lc "$command_text" >/dev/null 2>&1
}

ensure_tmux_defaults() {
  tmux set-option -g mouse on >/dev/null 2>&1 || true
  tmux set-option -g history-limit 200000 >/dev/null 2>&1 || true
}

schedule_startup_on_attach() {
  local session_name="$1"
  local startup_command="$2"
  TMUX_SESSION="$session_name" TMUX_STARTUP="$startup_command" bash -lc '
    for _ in $(seq 1 100); do
      attached=$(tmux display-message -p -t "$TMUX_SESSION" "#{session_attached}" 2>/dev/null || echo 0)
      if [[ "$attached" -ge 1 ]]; then
        sleep 1
        tmux send-keys -t "$TMUX_SESSION" "$TMUX_STARTUP" C-m
        exit 0
      fi
      sleep 0.1
    done
  ' >/dev/null 2>&1 &
}

ensure_session_and_attach() {
  local session_type="$1"
  local session_label="$2"
  local session_title="${3:-}"
  local working_directory_input="${4:-}"
  local safe_label session_name startup healthcheck created_new working_directory working_directory_windows
  safe_label="$(normalize_label "$session_label")"
  session_name="${session_type}-${safe_label}"
  created_new=0
  working_directory="$(resolve_working_directory "$working_directory_input")"
  working_directory_windows="$(convert_wsl_to_windows_path "$working_directory")"

  if ! tmux has-session -t "$session_name" >/dev/null 2>&1; then
    tmux new-session -d -s "$session_name" -c "$working_directory"
    created_new=1
  fi

  if [[ "$created_new" -eq 1 ]]; then
    startup="${STARTUP_COMMANDS[$session_type]}"
    healthcheck="${HEALTHCHECK_COMMANDS[$session_type]}"
    upsert_session_catalog_entry "$session_name" "$session_type" "$session_title" "$working_directory_windows"
    if [[ -n "$startup" ]] && command_is_healthy "$healthcheck"; then
      if ! no_attach_requested; then
        schedule_startup_on_attach "$session_name" "$startup"
      fi
    elif [[ -n "$startup" ]]; then
      printf '%s startup is not runnable in WSL. Opening plain shell session instead.\n' "$session_type"
    fi
  elif [[ -n "${session_title// }" ]]; then
    upsert_session_catalog_entry "$session_name" "$session_type" "$session_title" "$working_directory_windows"
  fi

  if no_attach_requested; then
    printf 'Session ready: %s\n' "$session_name"
    return 0
  fi

  tmux attach-session -t "$session_name"
}

attach_existing_session() {
  local session_name="$1"
  tmux has-session -t "$session_name" >/dev/null 2>&1 || {
    printf 'Session not found: %s\n' "$session_name" >&2
    return 1
  }
  if no_attach_requested; then
    printf 'Session ready: %s\n' "$session_name"
    return 0
  fi
  tmux attach-session -t "$session_name"
}

list_sessions() {
  local line session_name created attached windows activity split type label preview_text display_title activity_local folder_text
  printf '%-24s %-8s %-26s %-28s %-8s %-8s %s\n' 'Title' 'Type' 'Folder' 'Preview' 'Attached' 'Windows' 'Last Activity'
  while IFS='|' read -r session_name created attached windows activity; do
    [[ -n "$session_name" ]] || continue
    split="$(split_session_name "$session_name")"
    type="${split%%|*}"
    label="${split#*|}"
    preview_text="$(get_session_preview_text "$session_name")"
    display_title="$(get_display_title "$session_name" "$type" "$label" "$created" "$preview_text")"
    folder_text="$(get_session_working_directory_windows "$session_name")"
    activity_local="$(format_local_timestamp "$activity")"
    printf '%-24s %-8s %-26s %-28s %-8s %-8s %s\n' "$display_title" "$type" "$folder_text" "$preview_text" "$attached" "$windows" "$activity_local"
  done < <(tmux list-sessions -F '#{session_name}|#{session_created}|#{session_attached}|#{session_windows}|#{session_activity}' 2>/dev/null | sort -t '|' -k5,5nr)
}

choose_agent_type() {
  local choice
  while true; do
    read -r -p 'Type (codex/claude/gemini/shell): ' choice
    case "$choice" in
      codex|claude|gemini|shell)
        printf '%s\n' "$choice"
        return 0
        ;;
      *)
        printf 'Invalid type.\n'
        ;;
    esac
  done
}

choose_existing_session() {
  SELECTED_SESSION_NAME=''
  local -a rows=()
  local index=1
  local line session_name created attached windows activity split type label preview_text display_title activity_local folder_text

  while IFS='|' read -r session_name created attached windows activity; do
    [[ -n "$session_name" ]] || continue
    rows+=("$session_name|$created|$attached|$windows|$activity")
  done < <(tmux list-sessions -F '#{session_name}|#{session_created}|#{session_attached}|#{session_windows}|#{session_activity}' 2>/dev/null | sort -t '|' -k5,5nr)

  if [[ "${#rows[@]}" -eq 0 ]]; then
    printf 'No tmux sessions found.\n' >&2
    return 1
  fi

  for line in "${rows[@]}"; do
    session_name="${line%%|*}"
    split="$(split_session_name "$session_name")"
    type="${split%%|*}"
    label="${split#*|}"
    created="$(printf '%s' "$line" | cut -d '|' -f 2)"
    attached="$(printf '%s' "$line" | cut -d '|' -f 3)"
    windows="$(printf '%s' "$line" | cut -d '|' -f 4)"
    activity="$(printf '%s' "$line" | cut -d '|' -f 5)"
    preview_text="$(get_session_preview_text "$session_name")"
    display_title="$(get_display_title "$session_name" "$type" "$label" "$created" "$preview_text")"
    folder_text="$(get_session_working_directory_windows "$session_name")"
    activity_local="$(format_local_timestamp "$activity")"
    printf '[%d] %s  type=%s  folder=%s  preview=%s  attached=%s  windows=%s  activity=%s\n' "$index" "$display_title" "$type" "$folder_text" "$preview_text" "$attached" "$windows" "$activity_local"
    index=$((index + 1))
  done

  while true; do
    local selected
    read -r -p 'Select session number: ' selected
    if [[ "$selected" =~ ^[0-9]+$ ]] && (( selected >= 1 && selected <= ${#rows[@]} )); then
      SELECTED_SESSION_NAME="${rows[$((selected - 1))]%%|*}"
      return 0
    fi
    printf 'Invalid number.\n'
  done
}

open_plain_shell() {
  export AI_AGENT_MOBILE_BYPASS=1
  exec bash --login
}

start_interactive_session() {
  local session_type session_label session_title session_working_directory
  session_type="$(choose_agent_type)"
  read -r -p 'What is this session about? (optional): ' session_title
  read -r -p "Working directory (optional, default: ${DEFAULT_WORKSPACE_ROOT}): " session_working_directory
  session_label="$(new_auto_session_label)"
  ensure_session_and_attach "$session_type" "$session_label" "$session_title" "$session_working_directory"
}

resume_interactive_session() {
  choose_existing_session
  attach_existing_session "$SELECTED_SESSION_NAME"
}

run_menu() {
  while true; do
    printf '\nAI session mobile menu\n'
    printf '[1] Start new typed session\n'
    printf '[2] Resume existing session\n'
    printf '[3] List sessions\n'
    printf '[4] Open plain shell\n'
    printf '[5] Exit\n'

    local choice
    read -r -p 'Choose 1/2/3/4/5: ' choice
    case "$choice" in
      1)
        start_interactive_session
        ;;
      2)
        resume_interactive_session
        ;;
      3)
        list_sessions
        ;;
      4)
        open_plain_shell
        ;;
      5)
        exit 0
        ;;
      *)
        printf 'Invalid choice.\n'
        ;;
    esac
  done
}

main() {
  local action="${1:-menu}"
  ensure_tmux_defaults
  case "$action" in
    menu)
      run_menu
      ;;
    list)
      list_sessions
      ;;
    start)
      [[ $# -ge 2 ]] || {
        usage >&2
        return 1
      }
      case "$2" in
        codex|claude|gemini|shell) ;;
        *)
          usage >&2
          return 1
          ;;
      esac
      ensure_session_and_attach "$2" "$(new_auto_session_label)" "${*:3}" ''
      ;;
    resume)
      [[ $# -eq 2 ]] || {
        usage >&2
        return 1
      }
      attach_existing_session "$2"
      ;;
    shell)
      open_plain_shell
      ;;
    --help|-h|help)
      usage
      ;;
    *)
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
