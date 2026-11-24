#!/bin/bash
#
# RTL8821Native — port of DrogaBox's RTL8814Native to Realtek RTL8821CU
# (0BDA:C820). Same architecture: Compat Linux->XNU layer + vendor core +
# IOKit driver. RTL8821CU is USB 2.0 High-Speed only (no USB3 switch).
#
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-x86_64}"
BUILD="Build"
OBJ="$BUILD/obj"
KEXT="$BUILD/RTL8821Native.kext"
BUNDLE_ID="com.DrogaBox.driver.RTL8821Native"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VER="$(xcrun --sdk macosx --show-sdk-platform-version)"
KERN="$SDK/System/Library/Frameworks/Kernel.framework/Headers"

V="Source/rtl8821cu"

VENDOR_SOURCES=(
    "$V/hal/HalPwrSeqCmd.c"
    "$V/hal/hal_com.c"
    "$V/hal/hal_intf.c"
    "$V/hal/hal_dm.c"
    "$V/hal/hal_dm_acs.c"
    "$V/hal/hal_com_phycfg.c"
    "$V/hal/hal_phy.c"
    "$V/hal/hal_btcoex.c"
    "$V/hal/hal_btcoex_wifionly.c"
    "$V/hal/hal_mp.c"
    "$V/hal/hal_mcc.c"
    "$V/hal/hal_hci/hal_usb.c"
    "$V/hal/led/hal_led.c"
    "$V/hal/led/hal_usb_led.c"
    "$V/hal/hal_halmac.c"
    "$V/hal/rtl8821c/rtl8821c_halinit.c"
    "$V/hal/rtl8821c/rtl8821c_mac.c"
    "$V/hal/rtl8821c/rtl8821c_cmd.c"
    "$V/hal/rtl8821c/rtl8821c_phy.c"
    "$V/hal/rtl8821c/rtl8821c_dm.c"
    "$V/hal/rtl8821c/rtl8821c_ops.c"
    "$V/hal/rtl8821c/hal8821c_fw.c"
    "$V/hal/rtl8821c/usb/rtl8821cu_halinit.c"
    "$V/hal/rtl8821c/usb/rtl8821cu_halmac.c"
    "$V/hal/rtl8821c/usb/rtl8821cu_io.c"
    "$V/hal/rtl8821c/usb/rtl8821cu_xmit.c"
    "$V/hal/rtl8821c/usb/rtl8821cu_recv.c"
    "$V/hal/rtl8821c/usb/rtl8821cu_led.c"
    "$V/hal/rtl8821c/usb/rtl8821cu_ops.c"
    "$V/hal/efuse/rtl8821c/HalEfuseMask8821C_USB.c"
    "$V/hal/btc/halbtc8821cwifionly.c"
    "$V/hal/halmac/halmac_api.c"
    "$V/hal/halmac/halmac_88xx/halmac_bb_rf_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_cfg_wmac_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_common_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_efuse_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_flash_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_fw_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_gpio_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_init_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_mimo_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_usb_88xx.c"
    "$V/hal/halmac/halmac_88xx/halmac_8821c/halmac_cfg_wmac_8821c.c"
    "$V/hal/halmac/halmac_88xx/halmac_8821c/halmac_common_8821c.c"
    "$V/hal/halmac/halmac_88xx/halmac_8821c/halmac_gpio_8821c.c"
    "$V/hal/halmac/halmac_88xx/halmac_8821c/halmac_init_8821c.c"
    "$V/hal/halmac/halmac_88xx/halmac_8821c/halmac_phy_8821c.c"
    "$V/hal/halmac/halmac_88xx/halmac_8821c/halmac_pwr_seq_8821c.c"
    "$V/hal/halmac/halmac_88xx/halmac_8821c/halmac_usb_8821c.c"
    "$V/core/rtw_io.c"
    "$V/core/rtw_cmd.c"
    "$V/core/rtw_wlan_util.c"
    "$V/core/rtw_security.c"
    "$V/core/rtw_ieee80211.c"
    "$V/core/efuse/rtw_efuse.c"
    "$V/core/rtw_mem.c"
    "$V/core/rtw_debug.c"
    "$V/core/rtw_chplan.c"
    "$V/core/rtw_vht.c"
    "$V/core/rtw_rf.c"
    "$V/core/rtw_sta_mgt.c"
    "$V/core/rtw_pwrctrl.c"
    "$V/core/rtw_sreset.c"
    "$V/core/rtw_odm.c"
    "$V/core/rtw_mi.c"
    "$V/core/rtw_mlme.c"
    "$V/core/rtw_mlme_ext.c"
    "$V/core/rtw_mp.c"
    "$V/core/rtw_btcoex.c"
    "$V/core/rtw_btcoex_wifionly.c"
    "$V/core/rtw_beamforming.c"
    "$V/core/rtw_br_ext.c"
    "$V/core/rtw_tdls.c"
    "$V/core/rtw_p2p.c"
    "$V/core/rtw_ap.c"
    "$V/core/rtw_rm.c"
    "$V/core/rtw_rm_fsm.c"
    "$V/core/rtw_rm_util.c"
    "$V/core/rtw_wnm.c"
    "$V/core/rtw_swcrypto.c"
    "$V/core/crypto/ccmp.c"
    "$V/core/crypto/gcmp.c"
    "$V/core/crypto/aes-ccm.c"
    "$V/core/crypto/aes-ctr.c"
    "$V/core/crypto/aes-gcm.c"
    "$V/core/crypto/aes-internal.c"
    "$V/core/crypto/aes-internal-enc.c"
    "$V/core/crypto/aes-omac1.c"
    "$V/core/crypto/aes-siv.c"
    "$V/core/crypto/sha256.c"
    "$V/core/crypto/sha256-internal.c"
    "$V/core/crypto/sha256-prf.c"
    "$V/core/crypto/rtw_crypto_wrap.c"
    "$V/core/rtw_iol.c"
    "$V/core/rtw_ioctl_query.c"
    "$V/core/rtw_ioctl_set.c"
    "$V/core/rtw_wapi.c"
    "$V/core/rtw_wapi_sms4.c"
    "$V/core/rtw_xmit.c"
    "$V/core/rtw_recv.c"
    "$V/hal/phydm/phydm.c"
    "$V/hal/phydm/phydm_cck_pd.c"
    "$V/hal/phydm/phydm_hwconfig.c"
    "$V/hal/phydm/phydm_adaptivity.c"
    "$V/hal/phydm/phydm_interface.c"
    "$V/hal/phydm/phydm_rainfo.c"
    "$V/hal/phydm/phydm_dig.c"
    "$V/hal/phydm/phydm_math_lib.c"
    "$V/hal/phydm/phydm_beamforming.c"
    "$V/hal/phydm/phydm_primary_cca.c"
    "$V/hal/phydm/rtl8821c/phydm_rtl8821c.c"
    "$V/hal/phydm/rtl8821c/phydm_regconfig8821c.c"
    "$V/hal/phydm/rtl8821c/phydm_hal_api8821c.c"
    "$V/hal/phydm/rtl8821c/halhwimg8821c_bb.c"
    "$V/hal/phydm/rtl8821c/halhwimg8821c_mac.c"
    "$V/hal/phydm/halrf/halrf.c"
    "$V/hal/phydm/halrf/halrf_powertracking.c"
    "$V/hal/phydm/halrf/halrf_powertracking_ce.c"
    "$V/hal/phydm/halrf/halrf_kfree.c"
    "$V/hal/phydm/halrf/rtl8821c/halrf_8821c.c"
    "$V/hal/phydm/halrf/rtl8821c/halhwimg8821c_rf.c"
    "$V/hal/phydm/halrf/rtl8821c/halrf_iqk_8821c.c"
    "$V/hal/phydm/txbf/haltxbfinterface.c"
    "$V/hal/phydm/txbf/halcomtxbf.c"
    "$V/hal/phydm/txbf/phydm_hal_txbf_api.c"
    "$V/hal/phydm/txbf/haltxbfjaguar.c"
    "$V/hal/phydm/phydm_adc_sampling.c"
    "$V/hal/phydm/phydm_antdect.c"
    "$V/hal/phydm/phydm_antdiv.c"
    "$V/hal/phydm/phydm_api.c"
    "$V/hal/phydm/phydm_auto_dbg.c"
    "$V/hal/phydm/phydm_cck_rx_pathdiv.c"
    "$V/hal/phydm/phydm_ccx.c"
    "$V/hal/phydm/phydm_cfotracking.c"
    "$V/hal/phydm/phydm_debug.c"
    "$V/hal/phydm/phydm_dfs.c"
    "$V/hal/phydm/phydm_direct_bf.c"
    "$V/hal/phydm/phydm_dynamictxpower.c"
    "$V/hal/phydm/phydm_lna_sat.c"
    "$V/hal/phydm/phydm_mp.c"
    "$V/hal/phydm/phydm_noisemonitor.c"
    "$V/hal/phydm/phydm_pathdiv.c"
    "$V/hal/phydm/phydm_phystatus.c"
    "$V/hal/phydm/phydm_pmac_tx_setting.c"
    "$V/hal/phydm/phydm_pow_train.c"
    "$V/hal/phydm/phydm_psd.c"
    "$V/hal/phydm/phydm_rssi_monitor.c"
    "$V/hal/phydm/phydm_soml.c"
    "$V/hal/phydm/halrf/halphyrf_ce.c"
    "$V/hal/phydm/halrf/halrf_debug.c"
    "$V/hal/phydm/halrf/halrf_psd.c"
)

COMPAT_SOURCES=(
    "Source/Compat/Compat.c"
    "Source/Compat/VendorOsDep8821.c"
)

DRIVER_SOURCES=(
    "Source/Driver/RTL8814Native.cpp"
    "Source/Driver/RTLUsbDevice.cpp"
    "Source/Driver/RTLEthernetAdapter.cpp"
    "Source/Driver/RTLUserClient.cpp"
    "Source/Driver/VendorGlue.cpp"
    "Source/Driver/VendorProbe.c"
    "Source/Driver/WPA2Supplicant.c"
    "Source/Driver/SAE.c"
    "Source/Driver/SAEAuth.c"
    "Source/Driver/AWDLTx.c"
    "Source/Driver/AWDLSim.cpp"
    "Source/Driver/SAEJoin.c"
    "Source/Driver/PMF.c"
    "Source/Driver/SecurityIE.c"
    "Source/Driver/ReplayCheck.c"
    "Source/Driver/CSA.c"
)

KCOMMON="-mkernel -isysroot $SDK -DKERNEL \
 -DCONFIG_RTL8821C \
 -DCONFIG_USB_HCI \
 -DCONFIG_LITTLE_ENDIAN \
 -DDM_ODM_SUPPORT_TYPE=0x04 \
 -I$KERN \
 -ISource/Compat/include \
 -ISource/Driver \
 -I$V/include \
 -I$V/hal/phydm \
 -I$V/hal/btc \
 -I$V/core/crypto \
 -I$V/platform \
 -fno-stack-protector -fno-builtin \
 -Wno-deprecated-declarations -Wno-macro-redefined \
 -Wno-sign-conversion -Wno-shorten-64-to-32 \
 -Wno-pointer-sign -Wno-shadow -Wno-implicit-int-conversion \
 -Wno-address-of-packed-member -Wno-parentheses-equality"

CFLAGS="-x c -std=gnu11 -fgnu89-inline $KCOMMON"
CXXFLAGS="-x c++ -std=c++17 -fapple-kext -fno-rtti -fno-exceptions -fno-use-cxa-atexit $KCOMMON -Wno-inconsistent-missing-override"

case "${1:-build}" in
clean)
    rm -rf "$BUILD"
    echo "cleaned."
    exit 0
    ;;
esac

mkdir -p "$OBJ" "$KEXT/Contents/MacOS"

NEWEST_HDR="$(find Source/Compat/include Source/Driver Source/rtl8821cu/include -name '*.h' -o -name '*.hpp' 2>/dev/null | xargs ls -t 2>/dev/null | head -n 1 || true)"

compile() {
    local src="$1"; local force="${2:-0}"; local ext="${src##*.}"
    local obj="$OBJ/$(echo "$src" | tr '/' '_').o"
    if [ "$force" = "1" ] || [ ! -f "$obj" ] || [ "$src" -nt "$obj" ] || { [ -n "$NEWEST_HDR" ] && [ "$NEWEST_HDR" -nt "$obj" ]; }; then
        echo "  CC  $src"
        if [ "$ext" = "c" ]; then
            clang $CFLAGS -c "$src" -o "$obj"
        else
            clang++ $CXXFLAGS -c "$src" -o "$obj"
        fi
    fi
    echo "$obj" >> "$BUILD/objects.txt"
}

echo "== RTL8821Native build (arch $ARCH) =="

rm -f "$BUILD/objects.txt"
touch "$BUILD/objects.txt"

echo "-- compat layer"
for f in "${COMPAT_SOURCES[@]}"; do compile "$f" 1; done

echo "-- driver (IOKit)"
for f in "${DRIVER_SOURCES[@]}"; do compile "$f" 1; done

echo "-- vendor radio (rtl8821cu)"
for f in "${VENDOR_SOURCES[@]}"; do compile "$f"; done

echo "-- generating kmod info"
INFO_C="$OBJ/RTL8821Native_info.c"
cat << KMOD_EOF > "$INFO_C"
#include <mach/mach_types.h>
#include <mach/kmod.h>

extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);

__attribute__((visibility("default")))
KMOD_EXPLICIT_DECL($BUNDLE_ID, "0.1.0", _start, _stop)

__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
KMOD_EOF
clang $CFLAGS -c "$INFO_C" -o "$OBJ/RTL8821Native_info.o"

echo "-- link"
CLANG_RT="$(clang -print-resource-dir)/lib/darwin"
if [ -f "$CLANG_RT/libclang_rt.cc_kext.a" ]; then
    KEXT_LIB="-L$CLANG_RT -lclang_rt.cc_kext"
else
    KEXT_LIB="-lcc_kext"
fi

ld -kext -arch "$ARCH" \
   -platform_version macos "$SDK_VER" "$SDK_VER" \
   -o "$KEXT/Contents/MacOS/RTL8814Native" \
   "$OBJ/RTL8821Native_info.o" \
   $(cat "$BUILD/objects.txt") \
   -L"$SDK/usr/lib" -lkmod \
   $KEXT_LIB

cp Source/Driver/Info.plist "$KEXT/Contents/Info.plist"

echo "-- codesign (ad-hoc)"
codesign --force --sign - "$KEXT" >/dev/null 2>&1 || \
    echo "   (codesign skipped — sign manually if needed)"

echo ""
echo "Built: $KEXT"
