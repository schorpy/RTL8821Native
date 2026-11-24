# RTL8821Native

A port of [DrogaBox's RTL8814Native](https://github.com/DrogaBox/RTL8814Native) to the **Realtek RTL8821CU** (`0bda:c820`, 1x1 802.11ac/bgn USB dongle): a native macOS driver that shows up in the **normal Wi-Fi menu**, built as two kexts loaded through OpenCore.

- `RTL8821Native.kext` — the radio driver: USB transport, the Realtek HAL/PHY code (`Source/rtl8821cu/`, vendored from the Linux vendor driver) behind a Linux-to-XNU compatibility layer, firmware loading, in-kernel WPA2-PSK supplicant, and the radio ABI (`RTLRadioABI.h`) that includes the AWDL ops.
- `RTL8814AirLayer.kext` — publishes the radio to macOS as a native Skywalk/IO80211 interface so `airportd`, the menu bar and System Settings can scan, join and reconnect on their own.

Everything below is about the 8821CU port. For the original RTL8814AU project — including its working AirDrop implementation and the full reverse-engineering notes — see [README-UPSTREAM-8814AU.md](README-UPSTREAM-8814AU.md).

## Where this port stands (2026-11-24)

Tested on: iMac20,2 Hackintosh, macOS 26.7.3 (25G342), x86_64, RTL8821CU dongle (`0bda:c820`, interface 2). One machine, one adapter, one OS build — treat everything as untested elsewhere.

### What works

- **Native Wi-Fi end to end**: scan, toggle, network list, typed-password WPA2-PSK join from macOS's own Wi-Fi menu, DHCP lease, default route, real HTTPS. No menu-bar helper app, no `networksetup` tricks.
- **TX**: healthy at every rate (true TXAGC readback, clean IQK); 3691/3693 CCX reports OK at MCS7.
- **DHCP**: reliable. Root-caused and fixed — the STA-mode BMC station never had an init rate, so every broadcast frame (DHCP DISCOVER, ARP) left at "invalid rate 0x0" and was silently lost.
- **Bluetooth coexistence**: data-first TDMA (55 ms Wi-Fi / 10 ms BT) gives 0% ping loss with BT audio running on the same dongle. The firmware's own BT_COEXIST stack regresses the native UI and is OFF — do not re-enable it.
- **RX**: bounded USB burst-packing aggregation + reassembly with straddle-carry. This chip lets packets straddle 32 KB USB transfer boundaries; the ported carry logic is the fix for that (upstream 8814AU never straddles, so it doesn't have it).

### What does not work / help wanted

These are the open items, in priority order. Any of them is a good first issue.

1. **Join instability.** Auth succeeds every time, but the association response is lost ~5× before one attempt gets through (`report_join_res(-2,1)` sequences in the bootlog). Several RX-path fixes shipped for this (zero-desc filler skip, resync scan, runtime `knob 12` bitmask) — needs a clean retest.
2. **Firmware rate-adaptation feedback is blind.** The FW adapts rates but never sends `C2H_RA_RPT` feedback to the driver (`handled=0`), so auto rate control parks at MCS7 and loses 20–60% at moderate distance. Interim mitigation: watchdog caps TX at OFDM 24M below −60 dBm. The real fix is the FW-RA feedback chain (H2C `RA_PARA` path re-check / FW RE). The 36M tier is untested; 54M measured 100% loss.
3. **Ping loss 10–30% under BT audio at times.** Watch `RX Reassembly: reassembled=` and `RXBAD` lines to see whether the straddle-carry engages.
4. **Hardware-MAC (Private Address OFF) joins** — rejected with a "wrong password" popup; a real `setMacAddress` is implemented and the SAE capability bit is cleared, retest pending.
5. **AirDrop / AWDL** — the AWDL ops and the HW-ack port are ported to the 8821 HAL (`AWDLTx.c`), and upstream's AirDrop architecture is proven on 8814AU, but nothing is tested on this chip yet. That is the next chapter.
6. **WPA3-SAE networks cannot join** — SAE is unimplemented on this port; WPA2/WPA3 transition networks join as WPA2.
7. Cosmetic/unknown: RX descriptor corruption warnings on drift (pkt_len vs transfer_len), recurring `REG_TXDMA_STATUS 0x401` every 2 s.

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
| 6 | force rate (`MGN_*` code, 255 = auto) |
| 7 / 8 / 9 | force IQK / TX power snapshot / true TXAGC readback |
| 10 | coex mode: 0 lock, 1 hw-PTA, 2 static grant, 3 TDMA 35/30, **4 TDMA 55/10 (default)** |
| 11 | CCX data reports (rate-ladder raw material) |
| 12 | RX parse strategy bitmask: 1 zero-desc skip, 2 resync scan, 4 carry; **7 = all on (default)** |

`Tools/test_diag.sh` (knob 9 + bootlog capture) and `Tools/test_online.sh` (join → DHCP → pings → HTTP → download in one run) automate the common sessions.

## Port notes — where this differs from upstream

The interesting bugs were all 8821CU-specific; upstream's 8814AU code was the reference that proved what "correct" looks like:

- **USB burst packing straddles 32 KB transfer boundaries** on this chip. RX reassembly with carry logic (ported into `Source/rtl8821cu/rtl8821cu_recv.c`) is mandatory; keep it ON at bring-up.
- **`HW_VAR_RXDMA_AGG_PG_TH` must always use the bounded vendor values** (size=5 pages, timeout=0x20). The vendor low-traffic branch (size=0/timeout=1) re-enables unbounded burst packing exactly while idle/scanning — that was the "empty Wi-Fi list" root cause.
- **C2H length**: `c2h_pre_handler_rtl8821c` must be called with the packet's own extent (`RXDESC_SIZE + pkt_len`), not the remaining transfer length — else phydm parses padding as content (page fault in the RA report handler).
- **Channel plan init** (`rtw_rfctl_chplan_init`) was missing from `rtw_init_drv_sw` — "0 channels active", empty scans.
- **Zero-length descriptors** are chip page padding between DMA agg bursts, sometimes with junk in the shift_sz bits. The parser skips them (adaptive advance, cap 32); rejecting them instead aborts the transfer and eats auth/assoc responses.
- **BMC broadcast rate**: the STA-mode BMC station's `init_rate` was never set (only AP mode set it upstream-adjacent code) — broadcasts left at invalid rate 0x0. Fixed in `rtw_joinbss_update_stainfo` (lowest advertised rate, CCK 1M fallback) + broadcast duplication in the TX work queue.
- **`CONFIG_BT_COEXIST` must NOT be defined** in `autoconf.h` — the define alone activates HAL-wide coex hooks that break the native Wi-Fi toggle.

Full history of every bug and fix: `Docs/ARCHITECTURE.md` and upstream's `Docs/`.

## License and credit

GPL-2.0, see [LICENSE](LICENSE). This is a port of [DrogaBox/RTL8814Native](https://github.com/DrogaBox/RTL8814Native) — the architecture, the AirLayer, the radio ABI and the AWDL work are his (Copyright (c) 2026 DrogaBox); the original README is preserved at [README-UPSTREAM-8814AU.md](README-UPSTREAM-8814AU.md). The Realtek vendor code comes from the Linux `rtl8821cu` / `morrownr/8814au` sources.

If you use any part of this, keep the copyright notices and credit both projects. The license requires it, and it is the only thing they ask.
