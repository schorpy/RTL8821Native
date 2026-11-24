#!/bin/bash
# One-shot online test for RTL8821Native true-boot session.
# Usage: sudo ./test_online.sh
# Everything lands in /Users/mac330/trueboot_report.txt — read it after rebooting back.

OUT=/Users/mac330/trueboot_report.txt
UC=/Users/mac330/RTL8821Port/RTL8821Native/Tools/test_uc
GW=10.206.102.241
exec > "$OUT" 2>&1

echo "=== RTL8821Native online test $(date) ==="

if ! kextstat 2>/dev/null | grep -q DrogaBox; then
	echo "[-] RTL8821Native NOT loaded — wrong boot. Aborting."
	exit 1
fi
echo "[+] kext loaded"

# 1. Join with retries — the AP can ignore auth for ~15s after a leave
assoc=0
for a in 1 2 3; do
	"$UC" join rn9p 12345672
	sleep 3
	if "$UC" status | grep -q "_FW_LINKED"; then assoc=1; echo "[+] associated (attempt $a)"; break; fi
	echo "[!] not associated (attempt $a) — waiting 15s before retry"
	sleep 15
done
if [ $assoc = 0 ]; then
	echo "[-] association failed after 3 attempts — aborting"
	"$UC" status > /Users/mac330/trueboot_status.txt
	exit 1
fi

# 2. Service-level manual config WITH gateway (the complete macOS-native
# configd setup: IP + router + persistent DNS all published by configd).
# No "ipconfig set" calls anywhere — they create interface-level overrides
# that suppress the service method and wipe its DNS.
networksetup -setmanual "802.11ac NIC" 10.206.102.183 255.255.255.0 $GW
networksetup -setdnsservers "802.11ac NIC" 8.8.8.8 1.1.1.1
sleep 3

# Fallback: raw ifconfig if configd didn't apply the address
if ! ifconfig en1 | grep -q "inet 10.206"; then
	echo "[!] configd did not apply manual service config — raw ifconfig"
	ifconfig en1 inet 10.206.102.183 netmask 255.255.255.0 up
	route delete default 2>/dev/null
	route add default $GW
fi

echo; echo "--- ifconfig en1 ---"; ifconfig en1
echo; echo "--- routes ---"; netstat -rn | grep -E "^default|10.206" | head -6

# RX A-MPDU A/B: disable aggregation to remove reorder stalls on a lossy link
echo; echo "--- RX A-MPDU off (knob 4) ---"
"$UC" knob 4 1
# TX A-MPDU A/B: disable aggregated TX (suspect for unicast data loss)
echo; echo "--- TX A-MPDU off (knob 5) ---"
"$UC" knob 5 1

echo; echo "--- ping gateway ---"; ping -c 5 $GW
echo; echo "--- ping internet IP ---"; ping -c 5 8.8.8.8

echo; echo "--- DNS ---"; dscacheutil -q host -a name www.google.com | head -4
echo; echo "--- HTTP (numeric, no DNS) ---"
curl -s -o /dev/null -w "1.1.1.1 http: %{http_code} in %{time_total}s\n" --max-time 15 http://1.1.1.1/
curl -s -o /dev/null -w "google.com: %{http_code} in %{time_total}s\n" --max-time 15 http://www.google.com

echo; echo "--- throughput (2 MB) ---"
curl -s -o /dev/null -w "http-2MB: %{speed_download} B/s (%{size_download} bytes in %{time_total}s)\n" --max-time 30 http://speedtest.tele2.net/2MB.zip
curl -s -o /dev/null -w "https-2MB: %{speed_download} B/s (%{size_download} bytes in %{time_total}s, tls=%{time_appconnect}s)\n" --max-time 30 "https://speed.cloudflare.com/__down?bytes=2000000"

echo; echo "--- telemetry ---"; "$UC" status
"$UC" bootlog > /Users/mac330/bootlog_online.txt

echo; echo "=== DONE ==="
