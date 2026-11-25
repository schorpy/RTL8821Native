# RTL8821Native

A port of [DrogaBox's RTL8814Native](https://github.com/DrogaBox/RTL8814Native) to the **Realtek RTL8821CU** (`0bda:c820`, 1x1 802.11ac/bgn USB dongle): a native macOS driver that shows up in the **normal Wi-Fi menu**, built as two kexts loaded through OpenCore.

- `RTL8821Native.kext` — the radio driver: USB transport, the Realtek HAL/PHY code (`Source/rtl8821cu/`, vendored from the Linux vendor driver) behind a Linux-to-XNU compatibility layer, firmware loading, in-kernel WPA2-PSK supplicant, and the radio ABI (`RTLRadioABI.h`) that includes the AWDL ops.
- `RTL8814AirLayer.kext` — publishes the radio to macOS as a native Skywalk/IO80211 interface so `airportd`, the menu bar and System Settings can scan, join and reconnect on their own.

Everything below is about the 8821CU port. For the original RTL8814AU project — including its working AirDrop implementation and the full reverse-engineering notes — see [README-UPSTREAM-8814AU.md](README-UPSTREAM-8814AU.md).

## Where this port stands (2026-11-24)

Tested on: iMac20,2 Hackintosh, macOS 26.7.3 (25G342), x86_64, RTL8821CU dongle (`0bda:c820`, interface 2). One machine, one adapter, one OS build — treat everything as untested elsewhere.

### What works

- **Native Wi-Fi end to end**: scan, toggle, network list, typed-password WPA2-PSK join from macOS's own Wi-Fi menu, DHCP lease, default route, real HTTPS. No menu-bar helper app, no `networksetup` tricks. **Joins work at boot with no manual steps** (2026-11-24 session); a join may take 60–120 s because auth/assoc responses that land in a USB burst-boundary truncation window are recovered by the protocol's own retries.
- **The connection holds**: scans are suppressed while associated (a periodic scan used to wedge the radio off-channel for 11.8 s until the beacon watchdog disconnected — the "connects for a few seconds then drops" cycle).
- **TX**: healthy at every rate (true TXAGC readback, clean IQK). Ships with TX fixed at descriptor rate `0x30` (VHT 1SS MCS4, 58.5 Mbps at 20 MHz) — measured 3.3% ping loss at −54 dBm. **Note the units:** `fix_rate` is a `DESC_*` code written straight into the 8821C descriptor, not an `MGN_*` code, so the old "24M" label was really VHT MCS4 and the old "36M = 100% loss wall" was `0x48` = VHT 3SS MCS8, a 3-stream rate on a 1x1 radio and impossible by construction. True auto (FW RA) measured 20–25% loss in the Nov-24 sweeps and is being re-tested now that the rate values are known to be sane. The watchdog re-applies the fixed rate after every association.
- **DHCP**: reliable. Root-caused and fixed — the STA-mode BMC station never had an init rate, so every broadcast frame (DHCP DISCOVER, ARP) left at "invalid rate 0x0" and was silently lost.
- **Bluetooth coexistence**: data-first TDMA (55 ms Wi-Fi / 10 ms BT). The firmware's own BT_COEXIST stack regresses the native UI and is OFF — do not re-enable it.
- **RX parse** (`knob 12`): zero-desc filler skip + continuity-validated resync scan shipped as the boot default (measured 1.7% ping loss at −54 dBm vs 10–25% stock). Measured against mainline Linux `rtw88` (same chip): upstream has **no** straddle handling and loses the same frames we do — burst-boundary truncations never continue, so the plain vendor abort is the correct handling. The old reassembly-carry approach is superseded (it spliced truncation tails onto the next transfer's clean head and corrupted frames).
- **RX USB aggregation**: bounded, with a 16 KB hard limit (association default was 5 KB — the chip cuts aggregates mid-frame at the limit, and at this port's throughput 5 KB measured ~12 truncated frames/second under load; 16 KB cuts 3× less often).

### What does not work / help wanted

These are the open items, in priority order. Any of them is a good first issue.

1. **TX-rate adaptation.** The firmware's rate adapter was assumed blind, but the Nov-24 rate sweep that produced the "36M = 100% loss wall" was written in `MGN_*` codes into a `DESC_*` field: 72 = `0x48` is VHT 3SS MCS8, a 3-stream rate a 1x1 radio cannot send (hence 100% loss), while the shipped "24M" (48 = `0x30`) is really VHT 1SS MCS4. That premise is now suspect. The shipped fixed rate is safe; the host-side CCX ladder (VHT MCS4→MCS7, `knob 11`) is the measured stepping stone, and true FW RA (`knob 6 255`) needs a clean A/B now that the rate values are understood. Compare DrogaBox's 8814AU driver, which never forces a rate and reaches 300+ Mbit/s (with USB 3, 4x4 and 80 MHz).
2. **Dynamic RX aggregation** (mainline-rtw88-style: agg OFF below 1 Mbps of traffic, ON above) would remove the truncation loss entirely at idle/browsing traffic. Blocked by one known issue: at `size=0` this port's RXDMA burst config lets packets straddle 32 KB URBs (compare `rtw_usb_init_burst_pkt_len`: `BIT_DMA_MODE | BURST_CNT=4 | BURST_SIZE_512`); fix that first, then port the toggle.
3. **Intermittent high-loss windows** (run-to-run swing 2%→38% at similar RSSI) correlate with phone-side conditions (the hotspot shares its radio with BT audio; Tahoe control boots show the same stalls). `Tools/stall_capture.sh` exists to pin the remaining cases; one capture showed the "dead internet" window was actually alive (TCP 47 ms) with only DNS dying — mitigated outside the driver by fallback DNS resolvers.
4. **Hardware-MAC (Private Address OFF) joins** — rejected with a "wrong password" popup; a real `setMacAddress` is implemented and the SAE capability bit is cleared, retest pending.
5. **AirDrop / AWDL** — the AWDL ops and the HW-ack port are ported to the 8821 HAL (`AWDLTx.c`), and upstream's AirDrop architecture is proven on 8814AU, but nothing is tested on this chip yet. That is the next chapter.
6. **WPA3-SAE networks cannot join** — SAE is unimplemented on this port; WPA2/WPA3 transition networks join as WPA2.
7. Cosmetic/unknown: recurring `REG_TXDMA_STATUS 0x401` every 2 s; the status decoder shows HT rates as "VHT MCS…" labels.

## Building

macOS with the Xcode Command Line Tools:

```
./build_rtl8821.sh    # -> Build/RTL8821Native.kext
./build_airlayer.sh   # -> Build/RTL8814AirLayer.kext
```

Verify **before deploying**: the build log must show `exit=0` **and** a `Built:` line — a failed build + chained deploy silently ships a stale binary. Then:

```
codesign --force --sign - Build/RTL8821Native.kext && codesign -vv Build/RTL8821Native.kext
nm -u Build/RTL8821Native.kext/Contents/MacOS/RTL8814Native | grep -E "rtw|rtl|hal|dm_|odm"   # must print nothing
```

Do not compile anything under `Source/rtl8821cu/os_dep/linux/` as-is; the OS-specific parts live in `Source/Compat/` and `Source/Driver/` (`VendorProbe.c`, `VendorOsDep8821.c`).

## Installing (OpenCore)

1. Copy `Build/RTL8821Native.kext` and `Build/RTL8814AirLayer.kext` into `EFI/OC/Kexts/`, `dot_clean -m` each, `sync`.
2. In `config.plist` under `Kernel -> Add`, enable both; the layer goes **after** the driver.
3. Boot-args: `rtlair=2` for native Wi-Fi; add `rtlawdl=1` for the AWDL experiment.
4. `rtlairtrust=<build>` — the layer checks the macOS build at boot and stays inert on an untrusted build. Validated for 25G342 (26.7.3); see upstream's [After a macOS update](README-UPSTREAM-8814AU.md#after-a-macos-update).

If anything goes wrong, disable both kexts and remove the `rtlair*` boot-args.

## Diagnostics

```
clang -Wall -O2 Tools/test_uc.c -framework IOKit -framework CoreFoundation -o Tools/test_uc
sudo Tools/test_uc status     # link, RSSI, rates, counters
sudo Tools/test_uc joinlog    # join/leave timeline
sudo Tools/test_uc bootlog    # kernel ring, 4096 entries
```

Runtime knobs (`sudo Tools/test_uc knob <n> <v>`), the ones specific to this port:

| Knob | Effect |
|---|---|
| 4 / 5 | RX / TX A-MPDU off (+DELBA) |
| 6 | force rate — **`DESC_*` code** written raw into the 8821C TX descriptor (255 = auto). **Boot default 48 = `0x30` = VHT 1SS MCS4** (58.5 Mbps @20 MHz), re-applied by the watchdog after every association. Useful: `0x08` OFDM 24M, `0x1b` HT MCS7, `0x33` VHT MCS7. Do not pass `0x48`: that is VHT 3SS MCS8, impossible on 1x1 (the old "36M wall") |
| 7 / 8 / 9 | force IQK / TX power snapshot / true TXAGC readback |
| 10 | coex mode: 0 lock, 1 hw-PTA, 2 static grant, 3 TDMA 35/30, **4 TDMA 55/10 (default)** |
| 11 | CCX data reports: enables the host-side rate ladder (`fix_rate` walks DESC `0x30`→`0x31`→`0x32`→`0x33` = VHT MCS4→MCS7 on clean windows, down on failures). Off by default |
| 12 | RX parse strategy bitmask: 1 zero-desc filler skip, 2 resync scan, 4 reassembly-carry (harmful — splices truncation tails and corrupts frames), 8 skip-straddle (regressed joins). **Boot default 3 = zero-skip + resync** (measured 1.7% loss vs 10–25% stock) |
| 13 | **1 (default)** suppress scan requests while associated — a post-join scan wedged the radio off-channel until the beacon watchdog disconnected |
| 14 / 15 | RX-agg hard-limit size (KB; assoc default 16 — the chip cuts aggregates mid-frame at the limit) / timeout (0x20) |

New here: `Tools/ladder_test.sh` (live CCX-ladder run: 3 × 40 MB, polls TX rate, prints each `ccx ladder UP -> desc 0x31`, restores the default).

`Tools/test_diag.sh` (knob 9 + bootlog capture) and `Tools/test_online.sh` (join → DHCP → pings → HTTP → download in one run) automate the common sessions. This port adds `Tools/loss_check.sh` (boot-state snapshot + knob sweeps with honest ping parsing), `Tools/join_diag.sh` (live join capture with the full bootlog persisted) and `Tools/stall_capture.sh` (during a dead window: direct-L2 vs through-NAT pings, ARP tcpdump, direct-IP TCP — separates link loss from DNS death).

## Port notes — where this differs from upstream

The interesting bugs were all 8821CU-specific; upstream's 8814AU code was the reference that proved what "correct" looks like:

- **USB burst-boundary truncations**: the chip cuts its USB RX aggregate mid-frame at the size hard limit and the remainder never arrives — the next transfer starts at a frame boundary, so the correct handling is exactly the stock vendor abort (verified against mainline `rtw88`, which has no straddle handling and drops the same frames via the FCS check). Earlier lore said the carry/reassembly logic was the fix; three boots of evidence showed it instead spliced truncation tails onto the next transfer's clean head and corrupted frames. Zero-desc filler skip + continuity-validated resync scan (`knob 12` = 3) shipped instead. Do not re-enable bit 4.
- **`HW_VAR_RXDMA_AGG_PG_TH` must always use bounded values**. The vendor low-traffic branch (size=0/timeout=1) re-enables unbounded burst packing exactly while idle/scanning — that was the "empty Wi-Fi list" root cause. The shipped hard limit is 16 KB (5 KB measured ~12 truncated frames/s under load); `knob 14` re-tunes at runtime. Mainline rtw88 uses 5 KB/0x20 and is fine at full speed — at this port's capped TX rate, bigger limits matter more.
- **C2H length**: `c2h_pre_handler_rtl8821c` must be called with the packet's own extent (`RXDESC_SIZE + pkt_len`), not the remaining transfer length — else phydm parses padding as content (page fault in the RA report handler).
- **Channel plan init** (`rtw_rfctl_chplan_init`) was missing from `rtw_init_drv_sw` — "0 channels active", empty scans.
- **Zero-length descriptors** are chip page padding between DMA agg bursts, sometimes with junk in the shift_sz bits. The parser skips them (adaptive advance, cap 32); rejecting them instead aborts the transfer and eats auth/assoc responses.
- **BMC broadcast rate**: the STA-mode BMC station's `init_rate` was never set (only AP mode set it upstream-adjacent code) — broadcasts left at invalid rate 0x0. Fixed in `rtw_joinbss_update_stainfo` (lowest advertised rate, CCK 1M fallback) + broadcast duplication in the TX work queue.
- **`CONFIG_BT_COEXIST` must NOT be defined** in `autoconf.h` — the define alone activates HAL-wide coex hooks that break the native Wi-Fi toggle.

Full history of every bug and fix: `Docs/ARCHITECTURE.md` and upstream's `Docs/`.

## License and credit

GPL-2.0, see [LICENSE](LICENSE). This is a port of [DrogaBox/RTL8814Native](https://github.com/DrogaBox/RTL8814Native) — the architecture, the AirLayer, the radio ABI and the AWDL work are his (Copyright (c) 2026 DrogaBox); the original README is preserved at [README-UPSTREAM-8814AU.md](README-UPSTREAM-8814AU.md). The Realtek vendor code comes from the Linux `rtl8821cu` / `morrownr/8814au` sources.

If you use any part of this, keep the copyright notices and credit both projects. The license requires it, and it is the only thing they ask.
