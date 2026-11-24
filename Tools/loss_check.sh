#!/bin/bash
# loss_check.sh — efi-airdrop 50-70% ping-loss diagnostic.
# Run ON an efi-airdrop boot, with Wi-Fi joined, as root:  sudo ./loss_check.sh
# Sweeps knob 12 (RX parse), knob 6 (TX rate), knob 10 (coex) and measures
# gateway ping loss for each, so the culprit is isolated in one run.

OUT=/Users/mac330/loss_check_$(date +%Y%m%d_%H%M%S).txt
UC=/Users/mac330/RTL8821Port/RTL8821Native/Tools/test_uc
N=${N:-60}                 # pings per stage (override: N=120 sudo ./loss_check.sh)
GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}')

log() { echo "$@" | tee -a "$OUT"; }

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 1; fi
if [ ! -x "$UC" ]; then echo "test_uc missing at $UC"; exit 1; fi
if [ -z "$GATEWAY" ]; then
  log "!! No default gateway — join Wi-Fi first. Dumping status only."
  $UC status > "$OUT" 2>&1
  echo "wrote $OUT (status only)"; exit 1
fi

log "=== loss_check $(date)  gw=$GATEWAY  pings=$N ==="

log "--- [0] boot tree + gate ---"
kextstat 2>/dev/null | grep -iE "DrogaBox|Tahoe|RTL8814" | tee -a "$OUT"
ioreg -r -c RTL8814Native -d 1 2>/dev/null | grep -E "RTLAirGate|RTLAirGateBuild" | tee -a "$OUT"

log "--- [1] baseline status (before any knob change) ---"
$UC status 2>&1 | tee -a "$OUT" | grep -E "RSSI|Reassembly|Rate|coex|COEX|rate" || true

ping_loss() {
  # $1 = label; echoes "loss%"
  # macOS ping: -t N is the TOTAL runtime (useless here); -W is the
  # per-reply wait in ms. -c 60 -i 0.25 = ~15 s on a healthy link.
  local out loss rtt
  out=$(ping -c "$N" -i 0.25 -W 1000 "$GATEWAY" 2>/dev/null)
  loss=$(echo "$out" | grep "% packet loss" | sed -E 's/.*, ([0-9.]+)% packet loss.*/\1/')
  rtt=$(echo "$out" | grep "^round-trip" | cut -d= -f2)
  [ -z "$loss" ] && loss=100
  log "  $1: ${loss}% loss${rtt:+ | rtt$rtt}"
  echo "$loss"
}

BASE=$(ping_loss "baseline (current knobs)")

log "--- [2] knob 12 sweep (proven-default 0 vs light additions; carry modes = harmful) ---"
for v in 0 1 2 3; do
  $UC knob 12 "$v" >/dev/null 2>&1
  sleep 2
  ping_loss "knob12=$v" >/dev/null
done
$UC knob 12 0 >/dev/null 2>&1   # restore proven default

log "--- [3] knob 6 sweep (TX rate; 36M=72 skipped below -70 dBm = measured rate wall) ---"
RSSI=$($UC status 2>/dev/null | awk '/Signal RSSI/ {print $4}')
for v in 48 72 255; do
  if [ "$v" = "72" ] && [ -n "$RSSI" ] && [ "$RSSI" -lt -70 ] 2>/dev/null; then
    log "  (skip knob6=72: RSSI $RSSI dBm <= -70, 36M measured 100% loss there)"
    continue
  fi
  $UC knob 6 "$v" >/dev/null 2>&1
  sleep 3
  ping_loss "knob6=$v (48=24M,72=36M,255=auto)" >/dev/null
done
$UC knob 6 255 >/dev/null 2>&1   # restore auto (RSSI cap re-engages)

log "--- [4] knob 10 coex re-assert (4 = TDMA 55/10 data-first) ---"
$UC knob 10 4 >/dev/null 2>&1
sleep 2
ping_loss "knob10=4 TDMA 55/10" >/dev/null

log "--- [5] final counters + RXBAD count ---"
$UC status 2>&1 | tee -a "$OUT" | grep -E "Reassembly|RSSI|Link State" || true
$UC bootlog > /tmp/loss_check_bootlog.txt 2>&1
cp /tmp/loss_check_bootlog.txt /Users/mac330/loss_check_bootlog_$(date +%Y%m%d_%H%M%S).txt
grep -c "RXBAD" /tmp/loss_check_bootlog.txt | tee -a "$OUT"

# restore proven defaults so the sweep never leaves a dead link
$UC knob 12 0 >/dev/null 2>&1
$UC knob 6 255 >/dev/null 2>&1
$UC knob 10 4 >/dev/null 2>&1

log "=== end ==="
log "Verdict hints:"
log "  loss collapses at knob6=48       -> TX-rate wall (blind FW RA); check ccx ladder state"
log "  loss varies wildly with knob12   -> RX parse regression; adopt best value, report to notes"
log "  loss drops after knob10=4        -> coex was wrong mode"
log "  stage_dropped climbs in [5]      -> RX drop path still losing frames under load"
echo "wrote $OUT"
