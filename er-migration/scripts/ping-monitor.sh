#!/usr/bin/env bash
#
# ping-monitor.sh - Continuous, timestamped reachability monitor for the
# ExpressRoute migration lab. Run this ON THE GCP "on-prem" VM during the
# Azure managed ExpressRoute gateway migration to measure whether (and for
# how long) the data path is interrupted.
#
# It pings the Azure hub VM once per second, logs every probe with a
# timestamp, tracks consecutive failures as "outage windows", and prints a
# running + final summary (sent / received / loss %, longest outage).
#
# Usage:
#   ./ping-monitor.sh [TARGET_IP] [-i INTERVAL_SEC] [-l LOGFILE]
#
# Examples:
#   ./ping-monitor.sh                       # ping 10.0.0.4 every 1s
#   ./ping-monitor.sh 10.0.0.4 -i 1 -l migration.log
#
# Stop with Ctrl+C; a final summary is printed and written to the log.
#
# Portability note: %3N (millisecond timestamps) requires GNU coreutils date.
# This is the default on Debian/Ubuntu GCP VMs (iputils-ping, coreutils).
# Busybox date (Alpine) does not support %3N — replace with %S if needed.

set -uo pipefail

TARGET="${1:-10.0.0.4}"
[[ "${TARGET}" == -* ]] && TARGET="10.0.0.4" || shift || true

INTERVAL=1
LOGFILE="ping-monitor-$(date +%Y%m%d-%H%M%S).log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    -l|--logfile)  LOGFILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [TARGET_IP] [-i INTERVAL_SEC] [-l LOGFILE]"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

sent=0
recv=0
cur_outage=0
max_outage=0
outage_start=""

ts() { date '+%Y-%m-%d %H:%M:%S.%3N'; }

log() { echo "$1" | tee -a "$LOGFILE"; }

summary() {
  local lost=$(( sent - recv ))
  local loss=0
  [[ $sent -gt 0 ]] && loss=$(( lost * 100 / sent ))
  log ""
  log "===================== SUMMARY ====================="
  log "Target           : $TARGET"
  log "Probes sent      : $sent"
  log "Replies received : $recv"
  log "Lost             : $lost (${loss}%)"
  log "Longest outage   : $(( max_outage * INTERVAL ))s  ($max_outage consecutive missed probe(s) x ${INTERVAL}s each)"
  log "Log file         : $LOGFILE"
  log "==================================================="
}

on_exit() {
  # Close any open outage window before summarizing.
  if [[ $cur_outage -gt 0 && -n "$outage_start" ]]; then
    log "$(ts) [STILL-DOWN] script stopped during active outage; started at $outage_start, duration ~$(( cur_outage * INTERVAL ))s (NOT recovered)"
  fi
  summary
  exit 0
}
trap on_exit INT TERM

log "$(ts) [START]   Monitoring $TARGET every ${INTERVAL}s. Logging to $LOGFILE. Press Ctrl+C to stop."
log "$(ts) [START]   Begin the Azure managed gateway migration now; watch for [DOWN] lines."

while true; do
  sent=$(( sent + 1 ))
  if rtt=$(ping -c 1 -W 1 "$TARGET" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p'); [[ -n "${rtt:-}" ]]; then
    recv=$(( recv + 1 ))
    if [[ $cur_outage -gt 0 ]]; then
      log "$(ts) [UP]      reply from $TARGET time=${rtt}ms  (recovered after ~$(( cur_outage * INTERVAL ))s outage that began $outage_start)"
      cur_outage=0
      outage_start=""
    else
      log "$(ts) [UP]      reply from $TARGET time=${rtt}ms"
    fi
  else
    if [[ $cur_outage -eq 0 ]]; then
      outage_start="$(ts)"
    fi
    cur_outage=$(( cur_outage + 1 ))
    [[ $cur_outage -gt $max_outage ]] && max_outage=$cur_outage
    log "$(ts) [DOWN]    no reply from $TARGET  (outage ~$(( cur_outage * INTERVAL ))s)"
  fi
  sleep "$INTERVAL"
done
