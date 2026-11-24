#!/usr/bin/env bash
# Read-only, best-effort backup of all discoverable listable Kubernetes API resources.
set -Eeuo pipefail
umask 077

PROGRAM="$(basename "$0")"
OUTPUT_ROOT="./k8s-backups"
KUBECONFIG_FILE=""
KUBE_CONTEXT=""
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-120s}"
BAR_WIDTH="${BAR_WIDTH:-36}"
PAGE_SIZE="${PAGE_SIZE:-200}"

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTIONS]

No arguments: use the current kubectl configuration (KUBECONFIG or
~/.kube/config) and create ./k8s-backups/<context>_<UTC-timestamp>/

Options:
  -k, --kubeconfig FILE   Explicit kubeconfig YAML file
  -c, --context NAME      Context in that kubeconfig (default: current-context)
  -o, --output DIR        Parent backup directory (default: ./k8s-backups)
      --timeout DURATION  kubectl request timeout (default: 120s)
  -h, --help              Show this help

Examples:
  $PROGRAM
  $PROGRAM --kubeconfig ./my-cluster.yaml
  $PROGRAM -k ./my-cluster.yaml -c prod -o ./my-backups
EOF
}

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    -k|--kubeconfig|-c|--context|-o|--output|--timeout)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        -k|--kubeconfig) KUBECONFIG_FILE="$2" ;;
        -c|--context) KUBE_CONTEXT="$2" ;;
        -o|--output) OUTPUT_ROOT="$2" ;;
        --timeout) REQUEST_TIMEOUT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || die 'kubectl is required'
[[ "$BAR_WIDTH" =~ ^[0-9]+$ ]] && ((BAR_WIDTH >= 10 && BAR_WIDTH <= 100)) || die 'BAR_WIDTH must be 10..100'
[[ "$PAGE_SIZE" =~ ^[0-9]+$ ]] && ((PAGE_SIZE > 0)) || die 'PAGE_SIZE must be a positive integer'

# IMPORTANT: Never run 'kubectl config use-context'; it edits the user's config.
# Always pass --kubeconfig/--context explicitly if provided.
KARGS=()
if [[ -n "$KUBECONFIG_FILE" ]]; then
  [[ -f "$KUBECONFIG_FILE" && -r "$KUBECONFIG_FILE" ]] || die "Cannot read kubeconfig: $KUBECONFIG_FILE"
  KUBECONFIG_FILE="$(cd "$(dirname "$KUBECONFIG_FILE")" && printf '%s/%s' "$PWD" "$(basename "$KUBECONFIG_FILE")")"
  KARGS+=(--kubeconfig "$KUBECONFIG_FILE")
fi
[[ -n "$KUBE_CONTEXT" ]] && KARGS+=(--context "$KUBE_CONTEXT")
k() { command kubectl "${KARGS[@]}" "$@"; }

CONTEXT="${KUBE_CONTEXT:-$(k config current-context 2>/dev/null || true)}"
[[ -n "$CONTEXT" ]] || die 'No current context. Pass --kubeconfig and optionally --context.'

printf '[INFO] Connecting using context: %s\n' "$CONTEXT"
if ! k --request-timeout="$REQUEST_TIMEOUT" get --raw=/version >/dev/null 2>&1; then
  die 'Unable to reach the Kubernetes API with the supplied configuration'
fi

safe_context="$(printf '%s' "$CONTEXT" | tr -c '[:alnum:]_.-' '_')"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${OUTPUT_ROOT%/}/${safe_context}_${TIMESTAMP}"
if [[ -e "$BACKUP_DIR" ]]; then
  die "Backup destination already exists: $BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"/{metadata,cluster-scoped,namespaces,logs}
LOG="$BACKUP_DIR/logs/backup.log"
ERRORS="$BACKUP_DIR/logs/errors.log"
INDEX="$BACKUP_DIR/metadata/index.tsv"
touch "$LOG" "$ERRORS"
printf 'scope\tnamespace\tresource_type\tobject\tstatus\tbytes\tpath\n' > "$INDEX"
START=$(date +%s)
SUCCESS=0
FAILED=0
COMPLETED=0
TOTAL=0
DISCOVERY_WARNINGS=0
OBJECT_SUCCESS=0
OBJECT_FAILED=0
CRD_COUNT='unknown'

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; RESET=''
fi

log() {
  local level="$1"; shift
  local stamp; stamp="$(date +%H:%M:%S)"
  printf '[%s] [%-5s] %s\n' "$stamp" "$level" "$*" >> "$LOG"
  local color="$CYAN"
  case "$level" in OK) color="$GREEN";; WARN) color="$YELLOW";; ERROR) color="$RED";; esac
  printf '%s[%s] [%-5s]%s %s\n' "$color" "$stamp" "$level" "$RESET" "$*"
}

fmt_time() { printf '%02dm %02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; }

progress() {
  ((TOTAL > 0)) || return 0
  local pct=$((COMPLETED * 100 / TOTAL))
  local filled=$((COMPLETED * BAR_WIDTH / TOTAL))
  local empty=$((BAR_WIDTH - filled))
  local left=$((TOTAL - COMPLETED))
  local bar spaces
  printf -v bar '%*s' "$filled" ''
  bar="${bar// /#}"
  printf -v spaces '%*s' "$empty" ''
  spaces="${spaces// /-}"
  printf '%s[%s%s]%s %3d%% | %d/%d types | OK:%d FAILED:%d LEFT:%d | elapsed %s\n' \
    "$GREEN" "$bar" "$spaces" "$RESET" "$pct" "$COMPLETED" "$TOTAL" \
    "$SUCCESS" "$FAILED" "$left" "$(fmt_time "$(($(date +%s)-START))")"
}

finish() {
  local status=$?
  trap - EXIT
  if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]]; then
    chmod -R go-rwx "$BACKUP_DIR" 2>/dev/null || true
    if ((status != 0)); then
      printf '\n[WARN] Backup stopped or incomplete (exit %s). Inspect %s\n' "$status" "$ERRORS" >&2
    fi
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log INFO "Backup directory: $BACKUP_DIR"
log INFO "Layout: one YAML per object (namespaces/<ns>/<api-type>/<object>.yaml)"
log INFO "kubectl context: $CONTEXT"
if [[ -n "$KUBECONFIG_FILE" ]]; then
  log INFO "Kubeconfig: $KUBECONFIG_FILE"
else
  log INFO 'Kubeconfig: kubectl defaults (KUBECONFIG or ~/.kube/config)'
fi
log WARN 'Sensitive Secrets and credential-bearing objects may be exported. Protect this folder.'

printf '%s\n' "$CONTEXT" > "$BACKUP_DIR/metadata/context.txt"
(k version -o yaml > "$BACKUP_DIR/metadata/kubectl-version.yaml") 2>>"$ERRORS" || { DISCOVERY_WARNINGS=$((DISCOVERY_WARNINGS+1)); log WARN 'Could not export version metadata'; }
(k api-versions > "$BACKUP_DIR/metadata/api-versions.txt") 2>>"$ERRORS" || { DISCOVERY_WARNINGS=$((DISCOVERY_WARNINGS+1)); log WARN 'Could not export API versions'; }
(k api-resources -o wide > "$BACKUP_DIR/metadata/api-resources.txt") 2>>"$ERRORS" || { DISCOVERY_WARNINGS=$((DISCOVERY_WARNINGS+1)); log WARN 'Could not export detailed API resource inventory'; }

# api-resources gives group-qualified types, including discoverable CRDs.
# Suppress no warnings: retain stderr so incomplete API discovery is visible.
discover() {
  local namespaced="$1" output="$2" tmp="${2}.tmp"
  log INFO "Discovering listable resources (namespaced=$namespaced)"
  if ! k api-resources --cached=false --verbs=list --namespaced="$namespaced" -o name > "$tmp" 2>>"$ERRORS"; then
    rm -f "$tmp"
    log ERROR "Resource discovery FAILED (namespaced=$namespaced); refusing to report complete backup"
    return 1
  fi
  LC_ALL=C sort -u "$tmp" > "$output"
  rm -f "$tmp"
  log OK "Discovered $(wc -l < "$output" | tr -d ' ') resource types (namespaced=$namespaced)"
}

discover false "$BACKUP_DIR/metadata/cluster-resource-types.txt" || exit 2
discover true "$BACKUP_DIR/metadata/namespaced-resource-types.txt" || exit 2

CLUSTER_LIST="$BACKUP_DIR/metadata/cluster-resource-types.txt"
NAMESPACE_LIST="$BACKUP_DIR/metadata/namespaced-resource-types.txt"
TOTAL=$(( $(wc -l < "$CLUSTER_LIST") + $(wc -l < "$NAMESPACE_LIST") ))
((TOTAL > 0)) || die 'No listable resource types were discovered'

# A separate, human-readable inventory. The actual CRD definitions and custom
# resource instances are exported by the generic discovery loops below.
if k get customresourcedefinitions.apiextensions.k8s.io -o name > "$BACKUP_DIR/metadata/crd-list.txt" 2>>"$ERRORS"; then
  CRD_COUNT="$(wc -l < "$BACKUP_DIR/metadata/crd-list.txt" | tr -d ' ')"
  log OK "CRDs currently visible: $CRD_COUNT"
else
  DISCOVERY_WARNINGS=$((DISCOVERY_WARNINGS+1))
  log WARN 'CRD inventory unavailable (insufficient RBAC or unsupported endpoint)'
fi

# Namespaces are also exported as normal cluster-scoped resources.
log INFO "Export queue created: $TOTAL API resource types"
progress

# Files are exported individually; a failed object cannot silently truncate a
# combined file. Namespaces/object names are Kubernetes DNS-style identifiers;
# sanitize components anyway to prevent unexpected path traversal.
safe_name() { printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'; }

backup_type() {
  local scope="$1" type="$2" base="$3"
  local t0 elapsed result='OK' listed=0 exported=0 type_failed=0
  local inventory="$BACKUP_DIR/logs/.objects.$$.tsv"
  local errtmp="$BACKUP_DIR/logs/.list-error.$$.tmp"
  local -a scope_args=()
  [[ "$scope" == namespaced ]] && scope_args=(--all-namespaces)
  log RUN "[$((COMPLETED+1))/$TOTAL] Listing $scope: $type"
  t0=$(date +%s)

  # Ask Kubernetes for object name and namespace, not whitespace-parsed YAML.
  # For cluster-scoped types, the namespace column is deliberately omitted.
  local format='custom-columns=NAME:.metadata.name'
  [[ "$scope" == namespaced ]] && format='custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name'
  if ! k get "$type" "${scope_args[@]}" -o "$format" --no-headers \
      --chunk-size="$PAGE_SIZE" --request-timeout="$REQUEST_TIMEOUT" \
      > "$inventory" 2> "$errtmp"; then
    result='FAILED'; type_failed=1
    log ERROR "Unable to list $scope/$type"
    { printf 'FAILED list: %s/%s\n' "$scope" "$type"; cat "$errtmp"; } >> "$ERRORS"
  else
    if [[ -s "$errtmp" ]]; then
      { printf 'WARNINGS listing %s/%s:\n' "$scope" "$type"; cat "$errtmp"; } >> "$ERRORS"
      DISCOVERY_WARNINGS=$((DISCOVERY_WARNINGS+1))
    fi
    while IFS=$'\t ' read -r column1 column2 rest; do
      [[ -n "$column1" ]] || continue
      local namespace='' name='' directory='' dest='' tmp='' bytes=0
      if [[ "$scope" == namespaced ]]; then
        namespace="$column1"; name="${column2:-}"
        [[ -n "$name" && "$namespace" != '<none>' ]] || continue
        directory="$base/$(safe_name "$namespace")/$(safe_name "$type")"
      else
        name="$column1"
        directory="$base/$(safe_name "$type")"
      fi
      listed=$((listed+1))
      mkdir -p "$directory"
      dest="$directory/$(safe_name "$name").yaml"
      tmp="${dest}.part"
      local -a object_scope=()
      [[ "$scope" == namespaced ]] && object_scope=(--namespace "$namespace")
      log RUN "  -> ${namespace:+$namespace/}$type/$name"
      if k get "$type" "$name" "${object_scope[@]}" -o yaml \
          --request-timeout="$REQUEST_TIMEOUT" > "$tmp" 2> "$errtmp"; then
        mv -- "$tmp" "$dest"
        bytes=$(wc -c < "$dest" | tr -d ' ')
        OBJECT_SUCCESS=$((OBJECT_SUCCESS+1)); exported=$((exported+1))
        printf '%s\t%s\t%s\t%s\tOK\t%s\t%s\n' \
          "$scope" "$namespace" "$type" "$name" "$bytes" "$dest" >> "$INDEX"
        log OK "  saved ${namespace:+$namespace/}$type/$name (${bytes} bytes)"
      else
        rm -f -- "$tmp"
        OBJECT_FAILED=$((OBJECT_FAILED+1)); type_failed=1; result='FAILED'
        printf '%s\t%s\t%s\t%s\tFAILED\t0\t%s\n' \
          "$scope" "$namespace" "$type" "$name" "$dest" >> "$INDEX"
        { printf 'FAILED object: %s/%s/%s\n' "$namespace" "$type" "$name"; cat "$errtmp"; } >> "$ERRORS"
        log ERROR "  FAILED ${namespace:+$namespace/}$type/$name"
      fi
    done < "$inventory"
  fi
  rm -f -- "$inventory" "$errtmp"
  elapsed=$(($(date +%s)-t0))
  COMPLETED=$((COMPLETED+1))
  if ((type_failed)); then FAILED=$((FAILED+1))
  else SUCCESS=$((SUCCESS+1)); fi
  log INFO "$scope/$type: exported $exported/$listed objects (${elapsed}s)"
  progress
}

log INFO 'PHASE 1/2: Exporting cluster-scoped resources (including CRD definitions)'
while IFS= read -r resource; do
  [[ -n "$resource" ]] || continue
  backup_type cluster "$resource" "$BACKUP_DIR/cluster-scoped"
done < "$CLUSTER_LIST"

log INFO 'PHASE 2/2: Exporting all-namespace resources (including CRD instances)'
while IFS= read -r resource; do
  [[ -n "$resource" ]] || continue
  backup_type namespaced "$resource" "$BACKUP_DIR/namespaces"
done < "$NAMESPACE_LIST"

ELAPSED=$(($(date +%s)-START))
cat > "$BACKUP_DIR/metadata/summary.txt" <<EOF
Kubernetes API YAML backup
UTC timestamp: $TIMESTAMP
Context: $CONTEXT
Backup folder: $BACKUP_DIR
Resource types attempted: $TOTAL
Successful resource types: $SUCCESS
Failed resource types: $FAILED
Individual YAML objects saved: $OBJECT_SUCCESS
Individual objects failed: $OBJECT_FAILED
Discovery/metadata warnings: $DISCOVERY_WARNINGS
Visible CRD definitions: $CRD_COUNT
Elapsed seconds: $ELAPSED

Exports are raw API objects, including status/server-managed fields.
This is NOT a complete disaster-recovery backup: it excludes PVC contents,
etcd snapshots, node-local files, and external application data. Some
resources may not be listable due to RBAC or API server availability.
Secrets and other credentials may be present; protect the backup.
See metadata/index.tsv and logs/errors.log for completeness checks.
EOF
log INFO '========================================'
log INFO "Finished in $(fmt_time "$ELAPSED")"
log INFO "Resource types: $COMPLETED/$TOTAL | OK: $SUCCESS | Failed: $FAILED"
log INFO "Individual objects: $OBJECT_SUCCESS saved | $OBJECT_FAILED failed"
log INFO "CRDs visible: $CRD_COUNT | Additional warnings: $DISCOVERY_WARNINGS"
log INFO "Destination: $BACKUP_DIR"
log INFO '========================================'
if ((FAILED > 0 || DISCOVERY_WARNINGS > 0)); then
  log WARN 'Backup needs review: see metadata/summary.txt and logs/errors.log'
  exit 2
fi
log OK 'All discovered API resource types exported without reported errors'