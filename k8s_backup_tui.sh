#!/usr/bin/env bash
# K8s Backup Console v0.2 — Bash-only interactive terminal UI.
# Requires bash 4+, kubectl, tput (ncurses/terminfo), and common Linux utilities.
set -u
umask 077

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-$HERE/k8s_full_backup.sh}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/k8s-backups}"
KCONFIG="${KUBECONFIG:-}"
CONTEXT=""
SCREEN=0
SELECTED=0
RESOURCE_OFFSET=0
MESSAGE="Ready. Press f to load a kubeconfig YAML, b to back up."
BACKUP_PID=""
BACKUP_STATUS="idle"
SESSION_DIR=""
SESSION_LOG=""
SESSION_EXIT=""
RESOURCES=()
CONTEXTS=()
REACHABLE="UNKNOWN"
CLUSTER_NAME="-"
NS_COUNT="-"
CRD_COUNT="-"
RESOURCE_COUNT="-"
LAST_REFRESH=0
LAST_DRAW_SIGNATURE=""
LAST_DRAW_SECOND=-1
DIRTY=1
TERM_OK=0
SAVED_STTY=""

# ANSI styles
R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
BLUE=$'\033[38;5;39m'; CYAN=$'\033[38;5;51m'; GREEN=$'\033[38;5;78m'
RED=$'\033[38;5;203m'; YELLOW=$'\033[38;5;221m'; WHITE=$'\033[38;5;255m'
BG=$'\033[48;5;235m'; SEL=$'\033[48;5;24m'; MUTED=$'\033[38;5;245m'

cleanup() {
  if (( TERM_OK )); then
    printf '\033[?25h\033[?1049l\033[0m'
    [[ -n "$SAVED_STTY" ]] && stty "$SAVED_STTY" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cut_text() { local s="$1" n="$2"; (( n < 1 )) && return; printf '%s' "${s:0:n}"; }
repeat() { local ch="$1" n="$2"; (( n < 1 )) && return; printf '%*s' "$n" '' | tr ' ' "$ch"; }
line() { local y="$1" x="$2" str="$3"; printf '\033[%d;%dH\033[K%s' "$y" "$x" "$str"; }
width() { COLS=$(tput cols 2>/dev/null || echo 100); ROWS=$(tput lines 2>/dev/null || echo 30); }
kv() { line "$1" 5 "${MUTED}$(printf '%-18s' "$2")${R} ${WHITE}$(cut_text "$3" "$((COLS-28))")${R}"; }

k() {
  local -a opts=()
  [[ -n "$KCONFIG" ]] && opts+=(--kubeconfig "$KCONFIG")
  [[ -n "$CONTEXT" ]] && opts+=(--context "$CONTEXT")
  command kubectl "${opts[@]}" --request-timeout=8s "$@"
}

refresh_contexts() {
  local -a opts=()
  [[ -n "$KCONFIG" ]] && opts+=(--kubeconfig "$KCONFIG")
  mapfile -t CONTEXTS < <(command kubectl "${opts[@]}" config get-contexts -o name 2>/dev/null)
  if [[ -z "$CONTEXT" ]]; then
    CONTEXT=$(command kubectl "${opts[@]}" config current-context 2>/dev/null || true)
  fi
}

refresh_cluster() {
  LAST_REFRESH=$(date +%s)
  if k get --raw=/version >/dev/null 2>&1; then
    REACHABLE="ONLINE"
    CLUSTER_NAME="${CONTEXT:--}"
    NS_COUNT=$(k get namespaces -o name 2>/dev/null | wc -l | tr -d ' ')
    CRD_COUNT=$(k get crd -o name 2>/dev/null | wc -l | tr -d ' ')
    mapfile -t RESOURCES < <(k api-resources --verbs=list -o name 2>/dev/null | LC_ALL=C sort -u)
    RESOURCE_COUNT="${#RESOURCES[@]}"
    MESSAGE="Cluster refreshed. API types: $RESOURCE_COUNT."
  else
    REACHABLE="OFFLINE"
    NS_COUNT="-"; CRD_COUNT="-"; RESOURCE_COUNT="-"; RESOURCES=()
    MESSAGE="Cannot connect. Verify kubeconfig, context, VPN and RBAC."
  fi
}

start_backup() {
  if [[ "$BACKUP_STATUS" == "running" ]]; then MESSAGE="Backup already running."; return; fi
  if [[ ! -f "$BACKUP_SCRIPT" ]]; then MESSAGE="Missing backup engine: $BACKUP_SCRIPT"; return; fi
  SESSION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/k8s-tui.XXXXXXXX") || { MESSAGE="Cannot create temp directory"; return; }
  SESSION_LOG="$SESSION_DIR/console.log"
  SESSION_EXIT="$SESSION_DIR/exit-code"
  : > "$SESSION_LOG"
  local -a args=(--output "$OUTPUT_DIR")
  [[ -n "$KCONFIG" ]] && args+=(--kubeconfig "$KCONFIG")
  [[ -n "$CONTEXT" ]] && args+=(--context "$CONTEXT")
  (
    bash "$BACKUP_SCRIPT" "${args[@]}" > "$SESSION_LOG" 2>&1
    echo "$?" > "$SESSION_EXIT"
  ) </dev/null >/dev/null 2>&1 &
  BACKUP_PID=$!
  BACKUP_STATUS="running"
  SCREEN=3
  MESSAGE="Backup started. Logs update automatically."
}

check_backup() {
  if [[ "$BACKUP_STATUS" == "running" && -f "$SESSION_EXIT" ]]; then
    local code
    code=$(cat "$SESSION_EXIT")
    if [[ "$code" == 0 ]]; then BACKUP_STATUS="complete"; MESSAGE="Backup completed successfully."
    else BACKUP_STATUS="failed ($code)"; MESSAGE="Backup returned exit code $code; inspect the logs."; fi
  fi
}

prompt_value() {
  local label="$1" current="$2" result
  # Input must be echoed, even though navigation keeps the cursor hidden.
  # Clear the prompt row, display a visible cursor, and restore TUI mode.
  stty echo 2>/dev/null || true
  printf '\033[?25h\033[%d;1H\033[2K%s%s%s ' "$((ROWS-2))" "$CYAN" "$label" "$R"
  [[ -n "$current" ]] && printf '[current: %s] ' "$current"
  IFS= read -r result </dev/tty || result=""
  stty -echo 2>/dev/null || true
  printf '\033[?25l'
  REPLY_VALUE="${result:-$current}"
  DIRTY=1
}

percent_from_log() {
  [[ -f "$SESSION_LOG" ]] || { printf '0'; return; }
  local p
  p=$(grep -oE '[[:space:]][0-9]{1,3}% \|' "$SESSION_LOG" 2>/dev/null | tail -1 | tr -cd '0-9' || true)
  printf '%s' "${p:-0}"
}

header() {
  line 1 1 "${BG}${WHITE}${B}  K8S BACKUP CONSOLE   ${R}${BG}${DIM}  bash edition · v0.2  ${R}"
  local state_color="$RED"
  [[ "$REACHABLE" == ONLINE ]] && state_color="$GREEN"
  line 2 3 "${state_color}● ${REACHABLE}${R}   ${MUTED}Context:${R} ${WHITE}$(cut_text "${CONTEXT:--}" 28)${R}   ${MUTED}Backup:${R} ${YELLOW}${BACKUP_STATUS}${R}"
  line 3 1 "${MUTED}$(repeat '─' "$COLS")${R}"
}

sidebar() {
  local entries=('DASHBOARD' 'API RESOURCES' 'CONTEXTS' 'BACKUP / LOGS')
  local i
  line 5 3 "${CYAN}${B}NAVIGATION${R}"
  for i in 0 1 2 3; do
    local label="  $((i+1))  ${entries[$i]}"
    if ((SCREEN==i)); then
      line "$((7+i*2))" 2 "${SEL}${WHITE}${B}$(printf '%-21s' "$label")${R}"
    else
      line "$((7+i*2))" 2 "${MUTED}$(printf '%-21s' "$label")${R}"
    fi
  done
  local y
  for ((y=4;y<ROWS-3;y++)); do line "$y" 25 "${MUTED}│${R}"; done
}

panel_title() { line 5 29 "${WHITE}${B}$1${R}"; }

dashboard() {
  panel_title 'CLUSTER OVERVIEW'
  kv 8 'Cluster status' "$REACHABLE"
  kv 10 'Context' "${CONTEXT:--}"
  kv 12 'Kubeconfig' "${KCONFIG:-default kubectl configuration}"
  kv 14 'Namespaces' "$NS_COUNT"
  kv 16 'CRD definitions' "$CRD_COUNT"
  kv 18 'API resource types' "$RESOURCE_COUNT"
  kv 20 'Backup destination' "$OUTPUT_DIR"
  if ((ROWS>27)); then
    line 23 29 "${CYAN}AVAILABLE ACTIONS${R}"
    line 25 29 "${WHITE}[b]${R} Start backup    ${WHITE}[r]${R} Refresh cluster"
    line 26 29 "${WHITE}[f]${R} Set kubeconfig ${WHITE}[o]${R} Output directory"
    line 27 29 "${WHITE}[c]${R} Select context ${WHITE}[q]${R} Quit"
  fi
}

resources_panel() {
  panel_title 'DISCOVERED API RESOURCE TYPES'
  line 7 29 "${MUTED}Read-only inventory · select with j/k or ↑/↓${R}"
  local visible=$((ROWS-13)); ((visible<1)) && visible=1
  if ((SELECTED<RESOURCE_OFFSET)); then RESOURCE_OFFSET=$SELECTED; fi
  if ((SELECTED>=RESOURCE_OFFSET+visible)); then RESOURCE_OFFSET=$((SELECTED-visible+1)); fi
  local i index text
  for ((i=0;i<visible;i++)); do
    index=$((RESOURCE_OFFSET+i))
    ((index<${#RESOURCES[@]})) || break
    text="$(printf '%4d  %-s' "$((index+1))" "${RESOURCES[$index]}")"
    if ((index==SELECTED)); then
      line "$((9+i))" 29 "${SEL}${WHITE}$(printf '%-*s' "$((COLS-32))" "$(cut_text "$text" "$((COLS-34))")")${R}"
    else
      line "$((9+i))" 29 "${MUTED}$(cut_text "$text" "$((COLS-32))")${R}"
    fi
  done
  line "$((ROWS-5))" 29 "${CYAN}Showing $((${#RESOURCES[@]}==0?0:SELECTED+1))/${#RESOURCES[@]} resource types${R}"
}

contexts_panel() {
  panel_title 'KUBERNETES CONTEXTS'
  line 7 29 "${MUTED}Press j/k to choose, Enter to activate for this TUI only${R}"
  local i=0
  for item in "${CONTEXTS[@]}"; do
    ((9+i<ROWS-5)) || break
    local mark=' '
    [[ "$item" == "$CONTEXT" ]] && mark='●'
    local text="${mark}  $item"
    if ((i==SELECTED)); then
      line "$((9+i))" 29 "${SEL}${WHITE}$(printf '%-*s' "$((COLS-32))" "$(cut_text "$text" "$((COLS-34))")")${R}"
    else
      line "$((9+i))" 29 "${MUTED}$(cut_text "$text" "$((COLS-32))")${R}"
    fi
    ((i+=1))
  done
}

backup_panel() {
  panel_title 'YAML BACKUP / LIVE LOGS'
  local p=0 barlen=$((COLS-48)); ((barlen<10)) && barlen=10
  ((barlen>54)) && barlen=54
  p=$(percent_from_log)
  ((p>100)) && p=100
  local filled=$((p*barlen/100))
  line 7 29 "${MUTED}Status:${R} ${WHITE}${BACKUP_STATUS}${R}   ${MUTED}Actual resource-type completion${R}"
  line 9 29 "${GREEN}[$(repeat '#' "$filled")${MUTED}$(repeat '-' "$((barlen-filled))")${GREEN}]${R} ${B}${p}%${R}"
  line 11 29 "${MUTED}Destination:${R} $(cut_text "$OUTPUT_DIR" "$((COLS-47))")"
  line 13 29 "${CYAN}RECENT OUTPUT${R}"
  local logheight=$((ROWS-20))
  ((logheight<1)) && logheight=1
  if [[ -f "$SESSION_LOG" ]]; then
    local i=0
    while IFS= read -r entry; do
      entry=$(printf '%s' "$entry" | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g')
      line "$((15+i))" 29 "${MUTED}$(cut_text "$entry" "$((COLS-32))")${R}"
      ((i+=1))
    done < <(tail -n "$logheight" "$SESSION_LOG")
  else
    line 15 29 "${MUTED}No backup started in this session.${R}"
  fi
  line "$((ROWS-5))" 29 "${CYAN}[b] Start backup   [o] Output folder   [l] Show log path${R}"
}

render() {
  width
  # Redraw only when requested; do not clear the screen every polling tick.
  # Buffered output avoids revealing partially drawn frames.
  printf '\033[H'
  if (( COLS<77 || ROWS<22 )); then
    printf 'Terminal too small (%sx%s). Resize to at least 77x22. Press q to exit.\n' "$COLS" "$ROWS"
    return
  fi
  header
  sidebar
  case "$SCREEN" in
    0) dashboard ;;
    1) resources_panel ;;
    2) contexts_panel ;;
    3) backup_panel ;;
  esac
  line "$((ROWS-3))" 1 "${MUTED}$(repeat '─' "$COLS")${R}"
  line "$((ROWS-2))" 3 "${YELLOW}$(cut_text "$MESSAGE" "$((COLS-5))")${R}"
  line "$ROWS" 3 "${DIM}1-4 view  ·  j/k or ↑/↓ navigate  ·  Enter select  ·  b backup  ·  f config  ·  c contexts  ·  o output  ·  r refresh  ·  q quit${R}"
  printf '\033[?25l'
}

read_key() {
  KEY=''
  IFS= read -rsn1 -t 0.25 KEY || true
  if [[ "$KEY" == $'\033' ]]; then
    local a='' b=''
    IFS= read -rsn1 -t 0.04 a || true
    IFS= read -rsn1 -t 0.04 b || true
    [[ "$a$b" == '[A' ]] && KEY='k'
    [[ "$a$b" == '[B' ]] && KEY='j'
  fi
}

usage() {
  cat <<'EOF'
Usage: k8s_backup_tui.sh [--kubeconfig FILE] [--context NAME] [--output DIR]

Without arguments, uses your existing kubectl configuration.
While running: press f to enter a kubeconfig YAML path (typing is visible),
                 c to select context, b to launch backup.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      -k|--kubeconfig) (($#>=2)) || { echo "Missing kubeconfig file" >&2; exit 2; }; KCONFIG="$2"; shift 2 ;;
      -c|--context) (($#>=2)) || { echo "Missing context" >&2; exit 2; }; CONTEXT="$2"; shift 2 ;;
      -o|--output) (($#>=2)) || { echo "Missing output directory" >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
  done
  if [[ -n "$KCONFIG" && ! -r "$KCONFIG" ]]; then
    echo "Cannot read kubeconfig YAML: $KCONFIG" >&2
    exit 2
  fi
}

main() {
  parse_args "$@"
  if [[ ! -t 0 || ! -t 1 ]]; then echo 'Run in an interactive Linux terminal.' >&2; exit 1; fi
  command -v kubectl >/dev/null || { echo 'kubectl is required' >&2; exit 1; }
  command -v tput >/dev/null || { echo 'tput is required' >&2; exit 1; }
  [[ -f "$BACKUP_SCRIPT" ]] || echo "Warning: backup engine missing at $BACKUP_SCRIPT" >&2
  SAVED_STTY=$(stty -g)
  stty -echo
  printf '\033[?1049h\033[2J\033[?25l'
  TERM_OK=1
  refresh_contexts
  refresh_cluster
  while :; do
    check_backup
    # Only repaint when a key changes state, terminal dimensions change,
    # or a running backup has produced fresh log data. Never repaint at 3 FPS.
    local signature now
    now=$(date +%s)
    width
    signature="$SCREEN|$SELECTED|$MESSAGE|$REACHABLE|$BACKUP_STATUS|$COLS|$ROWS|$KCONFIG|$CONTEXT|$OUTPUT_DIR"
    if [[ "$BACKUP_STATUS" == running && "$SCREEN" == 3 ]]; then
      signature+="|$(wc -c < "$SESSION_LOG" 2>/dev/null || echo 0)"
    fi
    if ((DIRTY)) || [[ "$signature" != "$LAST_DRAW_SIGNATURE" ]]; then
      # build whole frame before emitting it, without repeatedly clearing screen
      frame=$(render)
      printf '%s' "$frame"
      LAST_DRAW_SIGNATURE="$signature"
      DIRTY=0
    fi
    read_key
    [[ -n "$KEY" ]] && DIRTY=1
    case "$KEY" in
      q|Q) break ;;
      1|2|3|4) SCREEN=$((KEY-1)); SELECTED=0; RESOURCE_OFFSET=0 ;;
      r|R) refresh_contexts; refresh_cluster ;;
      b|B) start_backup ;;
      f|F)
        width
        prompt_value 'Kubeconfig YAML path (press Enter to keep current):' "$KCONFIG"
        if [[ -z "$REPLY_VALUE" ]]; then
          KCONFIG=""; CONTEXT=""; refresh_contexts; refresh_cluster
        elif [[ -r "$REPLY_VALUE" && -f "$REPLY_VALUE" ]]; then
          KCONFIG="$REPLY_VALUE"; CONTEXT=""; refresh_contexts; refresh_cluster
          MESSAGE="Loaded kubeconfig YAML: $KCONFIG"
        else MESSAGE="Cannot read kubeconfig YAML: $REPLY_VALUE"; fi
        ;;
      o|O)
        width; prompt_value 'Output parent directory:' "$OUTPUT_DIR"
        [[ -n "$REPLY_VALUE" ]] && OUTPUT_DIR="$REPLY_VALUE"
        MESSAGE="Backup destination: $OUTPUT_DIR"
        ;;
      c|C) SCREEN=2; SELECTED=0 ;;
      l|L) [[ -n "$SESSION_LOG" ]] && MESSAGE="Log: $SESSION_LOG" || MESSAGE="No backup log yet." ;;
      j)
        if ((SCREEN==1 && SELECTED+1<${#RESOURCES[@]})); then ((SELECTED+=1));
        elif ((SCREEN==2 && SELECTED+1<${#CONTEXTS[@]})); then ((SELECTED+=1)); fi
        ;;
      k) ((SELECTED>0)) && ((SELECTED-=1)) ;;
      ''|$'\n')
        if ((SCREEN==2 && SELECTED<${#CONTEXTS[@]})); then
          CONTEXT="${CONTEXTS[$SELECTED]}"; refresh_cluster
          MESSAGE="Selected context: $CONTEXT (no kubeconfig modifications)."
        fi
        ;;
    esac
  done
  if [[ "$BACKUP_STATUS" == running ]]; then
    MESSAGE='Backup is running in the background; quitting does not cancel it.'
  fi
}
main "$@"