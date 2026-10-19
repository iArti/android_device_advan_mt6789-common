#!/system/bin/sh
#
# T812 mobile data diagnostics. Run as root while the problem is visible
# (LTE icon with "!" and no internet), before switching to EDGE:
#
#   adb push t812-modem-diag.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/t812-modem-diag.sh"
#   adb pull /data/local/tmp/t812-modem.txt
#
# The log contains the phone numbers, IMSI/ICCID prefixes and cell IDs the
# radio reports; strip what you do not want to share.

OUT=/data/local/tmp/t812-modem.txt

{
    echo "=== 0. identity"
    date
    getprop ro.build.fingerprint
    getprop gsm.version.baseband
    getprop gsm.operator.alpha
    getprop gsm.network.type
    getprop gsm.sim.state

    echo
    echo "=== 1. service / data state"
    dumpsys telephony.registry | grep -i -E "mServiceState|mDataConnectionState|mDataConnectionNetworkType|mPreciseDataConnectionStates|mSignalStrength|mPhysicalChannelConfigs|mDisplayInfo" | head -40

    echo
    echo "=== 2. data networks (framework)"
    dumpsys telephony 2>/dev/null | grep -i -E "DataNetwork|apn|state=|setupDataCall|failCause|DataStall|Recovery" | head -80

    echo
    echo "=== 3. connectivity / validation"
    dumpsys connectivity | grep -i -E "NetworkAgentInfo|VALIDATED|PARTIAL|everValidated|lastValidated|captive|DNS|Lost|cellular" | head -40

    echo
    echo "=== 4. interfaces and routes"
    ip -4 addr show | grep -E "ccmni|rmnet|inet"
    ip -6 addr show | grep -E "ccmni|inet6" | head -20
    ip route show table all 2>/dev/null | grep -E "ccmni|default" | head -20

    echo
    echo "=== 5. reachability (bypasses Android validation)"
    for h in 8.8.8.8 1.1.1.1; do ping -c 2 -W 3 $h 2>&1 | tail -n 2; done
    ping -c 2 -W 3 ya.ru 2>&1 | tail -n 2

    echo
    echo "=== 6. APNs"
    content query --uri content://telephony/carriers/preferapn 2>&1
    content query --uri content://telephony/carriers --where "current=1" --projection name:apn:type:protocol:roaming_protocol:mcc:mnc:carrier_enabled 2>&1 | head -30

    echo
    echo "=== 7. radio log (last 400 relevant lines)"
    logcat -b radio -d 2>/dev/null | grep -i -E "SETUP_DATA_CALL|DEACTIVATE_DATA|DATA_CALL_LIST|setInitialAttachApn|SET_INITIAL_ATTACH|ATTACH|RAT|rat=|DataNetwork|DataStall|cause|fail|EGPRS|EDGE|LTE|ia" | tail -n 400

    echo
    echo "=== 8. main log"
    logcat -b main -d 2>/dev/null | grep -i -E "DataStall|NetworkMonitor|ccmni|DataNetworkController" | tail -n 150
} > "$OUT" 2>&1

chmod 644 "$OUT"
echo "Saved to $OUT"
