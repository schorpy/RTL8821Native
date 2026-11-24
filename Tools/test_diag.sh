#!/bin/bash
# One-shot TX-quality diagnostic: runs knob 9 (true TXAGC readback + IQK flags),
# captures the bootlog, and writes the decoded results to a txt file.
UC=/Users/mac330/RTL8821Port/RTL8821Native/Tools/test_uc
OUT=/Users/mac330/tx_diag.txt
{
echo "=== TX quality diagnostic $(date) ==="
"$UC" knob 9 1
sleep 1
"$UC" bootlog > /Users/mac330/tx_diag_bootlog.txt
grep -a "knob9\|knob8" /Users/mac330/tx_diag_bootlog.txt
echo "=== raw bootlog saved to /Users/mac330/tx_diag_bootlog.txt ==="
} | tee "$OUT"
