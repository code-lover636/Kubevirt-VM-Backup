#!/bin/bash
# ============================================================
# VMPVCBackup CLI — create a backup and watch live progress
# Usage: ./backup.sh <vm-name> <backup-name> <namespace> [os-type]
# ============================================================
set -uo pipefail

# ── Colors (use $'...' so they are real escape bytes) ─────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# ── Args ──────────────────────────────────────────────────────
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <vm-name> <backup-name> <namespace> [os-type]"
  echo "  os-type: linux (default) or windows"
  exit 1
fi

VM="$1"
BACKUP="$2"
NS="$3"
OS="${4:-linux}"

# ── Create the VMPVCBackup CR ─────────────────────────────────
echo "${BOLD}Creating VMPVCBackup '${BACKUP}' for VM '${VM}' in namespace '${NS}'...${RESET}"

kubectl apply -f - <<EOF
apiVersion: backup.kubevirt.io/v1alpha1
kind: VMPVCBackup
metadata:
  name: ${BACKUP}
  namespace: ${NS}
spec:
  vmName: ${VM}
  backupName: ${BACKUP}
  osType: ${OS}
EOF

if [[ $? -ne 0 ]]; then
  echo "${RED}Failed to create VMPVCBackup CR${RESET}"
  exit 1
fi

echo ""

# ── Helpers ───────────────────────────────────────────────────
format_bytes() {
  local b=$1
  if [[ $b -ge 1073741824 ]]; then
    awk "BEGIN{printf \"%.1f GiB\", $b/1073741824}"
  elif [[ $b -ge 1048576 ]]; then
    awk "BEGIN{printf \"%.1f MiB\", $b/1048576}"
  elif [[ $b -ge 1024 ]]; then
    awk "BEGIN{printf \"%.0f KiB\", $b/1024}"
  else
    echo "${b} B"
  fi
}

# Reads PodVolumeBackup resources directly for live byte-level progress.
# Sets global vars: PROGRESS_PCT, PROGRESS_STR
get_live_progress() {
  local backup=$1
  local pvb_list bytes_total=0 bytes_done=0 vols=0 active=0 completed_vols=0

  PROGRESS_PCT=0
  PROGRESS_STR=""

  pvb_list=$(kubectl get podvolumebackups -n velero \
    -l "velero.io/backup-name=${backup}" \
    -o custom-columns=DONE:.status.progress.bytesDone,TOTAL:.status.progress.totalBytes,PHASE:.status.phase \
    --no-headers 2>/dev/null) || return 1

  [[ -z "$pvb_list" ]] && return 1

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local d t p
    d=$(awk '{print $1}' <<< "$line")
    t=$(awk '{print $2}' <<< "$line")
    p=$(awk '{print $3}' <<< "$line")
    [[ "$d" == "<none>" ]] && d=0
    [[ "$t" == "<none>" ]] && t=0
    bytes_done=$((bytes_done + d))
    bytes_total=$((bytes_total + t))
    vols=$((vols + 1))
    [[ "$p" == "InProgress" ]] && active=$((active + 1))
    [[ "$p" == "Completed" ]] && completed_vols=$((completed_vols + 1))
  done <<< "$pvb_list"

  [[ $bytes_total -gt 0 ]] && PROGRESS_PCT=$((bytes_done * 100 / bytes_total))

  PROGRESS_STR="$(format_bytes $bytes_done) / $(format_bytes $bytes_total)  ${PROGRESS_PCT}%  [${completed_vols}/${vols} vols done]"
  return 0
}

draw_bar() {
  local pct=$1 width=30
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  local bar=""
  [[ $filled -gt 0 ]] && bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
  [[ $empty -gt 0 ]] && bar+=$(printf '%*s' "$empty" '' | tr ' ' '-')
  printf '[%s] %3d%%' "$bar" "$pct"
}

format_elapsed() {
  local secs=$1
  if [[ $secs -ge 3600 ]]; then
    printf '%dh%02dm%02ds' $((secs/3600)) $((secs%3600/60)) $((secs%60))
  elif [[ $secs -ge 60 ]]; then
    printf '%dm%02ds' $((secs/60)) $((secs%60))
  else
    printf '%ds' "$secs"
  fi
}

# ── Watch loop ────────────────────────────────────────────────
SPIN='|/-\'
START=$SECONDS
i=0
last_detail=""

echo "${CYAN}Watching backup progress (Ctrl+C to detach — backup continues in background)${RESET}"
echo ""

while true; do
  elapsed=$((SECONDS - START))
  elapsed_str=$(format_elapsed $elapsed)
  spin_char="${SPIN:i%4:1}"
  i=$((i + 1))

  phase=""
  detail=""
  PROGRESS_PCT=0
  PROGRESS_STR=""

  # ── 1. Read CR status (controller sets this) ────────────────
  cr_phase=$(kubectl get vmpvcbackup "$BACKUP" -n "$NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  cr_message=$(kubectl get vmpvcbackup "$BACKUP" -n "$NS" \
    -o jsonpath='{.status.message}' 2>/dev/null || echo "")

  # ── 2. Read Velero backup directly (ground truth) ───────────
  velero_phase=$(kubectl get backup "$BACKUP" -n velero \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  # ── 3. Read PodVolumeBackups directly (live byte progress) ──
  has_pvb=false
  get_live_progress "$BACKUP" && has_pvb=true

  # ── 4. Decide what to display (Velero > CR > default) ───────
  if [[ -n "$velero_phase" ]]; then
    # Velero backup exists — use its phase as ground truth
    case "$velero_phase" in
      Completed)
        phase="Completed"
        if [[ $has_pvb == true ]]; then
          PROGRESS_PCT=100
          detail="$PROGRESS_STR"
        else
          PROGRESS_PCT=100
          detail="Backup completed"
        fi
        ;;
      Failed|PartiallyFailed)
        phase="Failed"
        detail=$(kubectl get backup "$BACKUP" -n velero \
          -o jsonpath='{.status.failureReason}' 2>/dev/null || echo "see velero logs")
        ;;
      InProgress|"")
        phase="BackingUp"
        if [[ $has_pvb == true ]]; then
          detail="$PROGRESS_STR"
        else
          detail="Waiting for volume uploads to start..."
        fi
        ;;
      *)
        phase="BackingUp"
        detail="Velero phase: $velero_phase"
        ;;
    esac
  elif [[ -n "$cr_phase" ]]; then
    # No Velero backup yet — use CR phase from controller
    phase="$cr_phase"
    detail="$cr_message"
  else
    # Nothing yet
    phase="Pending"
    detail="Waiting for controller..."
  fi

  # ── 5. Color the phase ──────────────────────────────────────
  case "$phase" in
    Completed)  phase_colored="${GREEN}${BOLD}Completed${RESET}" ;;
    Failed)     phase_colored="${RED}${BOLD}Failed${RESET}" ;;
    BackingUp)  phase_colored="${YELLOW}${BOLD}BackingUp${RESET}" ;;
    *)          phase_colored="${CYAN}${phase}${RESET}" ;;
  esac

  bar=$(draw_bar "$PROGRESS_PCT")

  # ── 6. Print status line (overwrites in place) ──────────────
  printf '\r\033[K  %s %s  %s  %s%s%s' \
    "$spin_char" "$phase_colored" "$bar" "$DIM" "$elapsed_str" "$RESET"

  # Print detail line when it changes
  if [[ -n "$detail" && "$detail" != "$last_detail" ]]; then
    printf '\n    %s%s%s\n' "$DIM" "$detail" "$RESET"
    last_detail="$detail"
  fi

  # ── 7. Exit on terminal states ──────────────────────────────
  case "$phase" in
    Completed)
      echo ""
      echo "  ${GREEN}Backup completed successfully in ${elapsed_str}${RESET}"
      [[ $has_pvb == true ]] && echo "  ${DIM}Final: ${PROGRESS_STR}${RESET}"
      echo ""
      exit 0
      ;;
    Failed)
      echo ""
      echo "  ${RED}Backup failed after ${elapsed_str}${RESET}"
      [[ -n "$detail" ]] && echo "  ${DIM}${detail}${RESET}"
      echo ""
      exit 1
      ;;
  esac

  sleep 3
done
