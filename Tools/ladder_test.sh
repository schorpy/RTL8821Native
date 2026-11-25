#!/bin/bash
# ladder_test.sh — live test of the host-side rate ladder (knob 11).
# Run on an efi-airdrop boot with Wi-Fi joined:  sudo ./ladder_test.sh
#
# 2026-11-25: fix_rate is now known to be a DESC rate code (not MGN).
# The shipped fixed rate is DESC 0x30 = VHT 1SS MCS4 (58.5 Mbps @20 MHz).
# The ladder walks DESC 0x30 -> 0x31 -> 0x32 -> 0x33 (VHT MCS4..MCS7).
# Expected bootlog lines: "ccx ladder UP -> desc 0x31" / "DOWN -> desc 0x30".
#
# Generates traffic for a few minutes while polling TX rate and printing new
# ladder events, then dumps the bootlog. Answers: did the ladder step UP?
# did the link survive? did it recover DOWN?

UC=/Users/mac330/RTL8821Port/RTL8821Native/Tools/test_uc
STAMP=$(date +%Y%m%d_%H%M%S)
OUT=/Users/mac330/ladder_test_$STAMP.txt
BOOT=/Users/mac330/ladder_bootlog_$STAMP.txt
log() { echo "$@" | tee -a "$OUT"; }
uc() { $UC "$@"; }

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 1; fi
command -v $UC >/dev/null || { echo "missing $UC"; exit 1; }

log "=== ladder_test $(date) ==="
uc status 2>/dev/null | grep -E "802.11 Link State|Signal RSSI|Current Channel|TX Rate|RX Rate" | tee -a "$OUT"

log "--- enable CCX TX reports (knob 11 1) ---"
uc knob 11 1 | tee -a "$OUT"

# 3 x 40 MB attempts; a lossy window can kill one attempt without meaning
# the ladder failed, so keep going and report each.
URL="https://speed.cloudflare.com/__down?bytes=40000000"
for a in 1 2 3; do
  ( curl -m 45 -o /dev/null -s -w "attempt $a: http=%{http_code} %{speed_download} B/s (%{size_download} bytes)\n" "$URL" >> "$OUT" ) &
  CPID=$!
  for i in $(seq 1 20); do
    LINE=$(uc status 2>/dev/null | grep -E "TX Rate \(FW RA\)" | sed 's/^\[+\][[:space:]]*//')
    log "a$a t=$((i*2))s  $LINE"
    # show ladder decisions as they happen (only lines not seen yet)
    SEEN=$(wc -l < "$BOOT.seen" 2>/dev/null || echo 0)
    uc bootlog 2>/dev/null | grep -a "ccx ladder" | tail -n +$((SEEN + 1)) > "$BOOT.new"
    if [ -s "$BOOT.new" ]; then
      tee -a "$OUT" < "$BOOT.new"
      cat "$BOOT.new" >> "$BOOT.seen"
    fi
    sleep 2
  done
  wait $CPID
done

log "--- bootlog tail ---"
uc bootlog > "$BOOT.raw" 2>&1
grep -aE "ccx ladder|ladder: fix_rate|knob11|watchdog re-applied" "$BOOT.raw" | tail -40 | tee -a "$OUT"

log "--- restore: knob 11 off, knob 6 48 (= DESC 0x30) ---"
uc knob 11 0 >/dev/null 2>&1
uc knob 6 48 >/dev/null 2>&1

log "=== end; wrote $OUT (bootlog: $BOOT.raw) ==="
