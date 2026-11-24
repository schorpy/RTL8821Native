#!/bin/bash
# stall_capture.sh — capture WHY internet dies while gateway pings still work.
# Run on an efi-airdrop boot THE MOMENT browsing stops working:
#   sudo /Users/mac330/RTL8821Port/RTL8821Native/Tools/stall_capture.sh
# It answers: is the Wi-Fi link still good (pings), does traffic through
# the phone's NAT still work (1.1.1.1), and is the ARP exchange alive?

OUT=/Users/mac330/stall_$(date +%Y%m%d_%H%M%S).txt
UC=/Users/mac330/RTL8821Port/RTL8821Native/Tools/test_uc
GW=10.221.137.26
log() { echo "$@" | tee -a "$OUT"; }

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo"; exit 1; fi
log "=== stall_capture $(date) ==="

log "--- [1] link check ---"
$UC status 2>&1 | grep -E "Link State|WPA2|RSSI|TX Rate|RX Rate|Frame Types|Reassembly|TX Bulk" | tee -a "$OUT"

log "--- [2] gateway ping (direct L2 to the phone) ---"
ping -c 20 -i 0.25 -t 3 "$GW" 2>&1 | tail -2 | tee -a "$OUT"

log "--- [3] through-NAT ping (needs the phone to route for us) ---"
ping -c 20 -i 0.25 -t 3 1.1.1.1 2>&1 | tail -2 | tee -a "$OUT"

log "--- [4] ARP alive? (tcpdump 8 s on en1) ---"
(timeout 8 tcpdump -i en1 -c 40 -n arp or icmp 2>/dev/null | tail -25) | tee -a "$OUT"
log "  (look for: ARP requests from the phone, our replies leaving)"

log "--- [5] TCP connect to two IPs (no DNS in the path) ---"
curl -m 8 -o /dev/null -s -w "  1.1.1.1:443  -> http %{http_code} in %{time_connect}s\n" "https://1.1.1.1/__down?bytes=1000" | tee -a "$OUT"
curl -m 8 -o /dev/null -s -w "  8.8.8.8:443  -> http %{http_code} in %{time_connect}s\n" "https://8.8.8.8/__down?bytes=1000" | tee -a "$OUT"

log "--- [6] driver counters after the checks ---"
$UC status 2>&1 | grep -E "TX Bulk|RX Frames|Reassembly|RSSI|Link State" | tee -a "$OUT"
$UC bootlog > "${OUT%.txt}_bootlog.txt" 2>&1
grep -iaE "sctx_wait|deauth|disconn|RXBAD|stage_dropped|auth" "${OUT%.txt}_bootlog.txt" | tail -30 | tee -a "$OUT"

log "=== end ==="
log "verdict guide:"
log "  [2] ok + [3] dead + [4] shows no ARP replies  -> phone lost L2 reach of us"
log "     (unicast replies lost: truncation/TX retry death) -> driver TX/RX path"
log "  [2] dead too                                  -> the Wi-Fi link itself stalled"
log "  [2][3][5] all ok but browsing dead            -> DNS/OS-side, not the link"
echo "wrote $OUT"
