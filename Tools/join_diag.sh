#!/bin/bash
# join_diag.sh — efi-airdrop join-failure diagnostic.
# Run ON an efi-airdrop boot BEFORE joining:  sudo ./join_diag.sh
# Then join via the NATIVE Wi-Fi menu and type the password.
# The script watches for a DHCP lease (or 120 s timeout), then dumps
# the driver bootlog + telemetry so the failure point is visible
# (auth -> assoc -> EAPOL -> DHCP).

OUT=/Users/mac330/join_diag_$(date +%Y%m%d_%H%M%S).txt
UC=/Users/mac330/RTL8821Port/RTL8821Native/Tools/test_uc
log() { echo "$@" | tee -a "$OUT"; }

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 1; fi

log "=== join_diag $(date) ==="
log "--- tree check (expect RTL8814Native YES, Tahoe NO) ---"
kextstat 2>/dev/null | grep -iE "RTL8814|DrogaBox|Tahoe" | tee -a "$OUT"
ioreg -r -c RTL8814Native -d 1 2>/dev/null | grep -E "RTLAirGate|RTLAirGateBuild" | tee -a "$OUT"

log ""
log ">>> NOW JOIN the network via the Wi-Fi menu and type the password."
log ">>> Watching for a lease (up to 120 s)..."
START=$(date +%s)
GOT=""
while [ $(( $(date +%s) - START )) -lt 120 ]; do
  if ifconfig en1 2>/dev/null | grep -q "inet 10\.\|inet 192\.\|inet 172\."; then
    GOT=1; break
  fi
  sleep 2
done

log ""
if [ -n "$GOT" ]; then
  log "[+] LEASE ACQUIRED after $(( $(date +%s) - START ))s: $(ifconfig en1 | grep 'inet ')"
else
  log "[!] NO lease within 120 s (self-assigned/failed join)"
fi

log "--- join events in bootlog ---"
$UC bootlog > /tmp/join_diag_bootlog.txt 2>&1
cp /tmp/join_diag_bootlog.txt /Users/mac330/join_diag_bootlog_$(date +%Y%m%d_%H%M%S).txt
grep -iaE "report_join_res|auth|assoc|eapol|wpa|join|RXBAD|stage_dropped|RTL8814Native" /tmp/join_diag_bootlog.txt | tail -80 | tee -a "$OUT"

log "--- final telemetry ---"
$UC status 2>&1 | grep -E "Link State|WPA2|rx_frames|Reassembly|RSSI|TX Rate|RX Rate|BSS Count" | tee -a "$OUT"

log "=== end ==="
echo "wrote $OUT"
