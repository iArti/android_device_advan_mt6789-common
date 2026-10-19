#!/system/bin/sh
#
# T812 charging diagnostics. Run as root on the tablet with a USB PD
# charger connected and the battery below 80%:
#
#   adb push t812-charging-diag.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/t812-charging-diag.sh"
#   adb pull /data/local/tmp/t812-charging.txt
#
# (If "su -c" is not supported: adb shell su 0 sh /data/local/tmp/t812-charging-diag.sh)

OUT=/data/local/tmp/t812-charging.txt
DT=/proc/device-tree

u32() {
    # Print a big-endian u32 device tree property as a decimal number.
    if [ -f "$1" ]; then
        echo $((0x$(xxd -p "$1" | head -c 8)))
    else
        echo "(missing)"
    fi
}

{
    echo "=== 0. identity"
    id
    getprop ro.boot.slot_suffix
    date

    echo
    echo "=== 1. dtbo applied?"
    echo "pdc status:                $(cat $DT/pdc/status 2>&1)"
    echo "pdc pd_vbus_low_bound:     $(u32 $DT/pdc/pd_vbus_low_bound)"
    echo "pdc pd_vbus_upper_bound:   $(u32 $DT/pdc/pd_vbus_upper_bound)"
    echo "pdc sc_input_current:      $(u32 $DT/pdc/sc_input_current)"
    echo "pdc pd_stop_battery_soc:   $(u32 $DT/pdc/pd_stop_battery_soc)"
    echo "charger max_charger_voltage: $(u32 $DT/charger/max_charger_voltage)"
    for n in pe pe2 pe4; do
        echo "$n status: $(cat $DT/$n/status 2>&1)"
    done

    echo
    echo "=== 2. battery"
    dumpsys battery | grep -i -E "level|status|max charging|temperature|voltage"

    echo
    echo "=== 3. charger sysfs"
    CHG=$(dirname "$(ls -d /sys/devices/platform/*charger*/Pump_Express 2>/dev/null | head -n 1)")
    echo "charger dir: $CHG"
    for f in Pump_Express High_voltage_chg_enable chr_type ADC_Charger_Voltage \
             ADC_Charging_Current input_current fast_chg_indicator Thermal_throttle \
             Charging_mode sc_ibat_limit; do
        [ -e "$CHG/$f" ] && echo "$f: $(cat "$CHG/$f" 2>&1 | tr '\n' ' ')"
    done
    for p in /sys/class/power_supply/*; do
        echo "--- $p"
        grep -E "ONLINE|TYPE|VOLTAGE_NOW|CURRENT_NOW|CURRENT_MAX|VOLTAGE_MAX|INPUT_CURRENT|USB_TYPE|CAPACITY=" "$p/uevent" 2>/dev/null
    done

    echo
    echo "=== 4. type-c / pd"
    for t in /sys/class/tcpc/*; do
        echo "--- $t"
        for f in "$t"/*; do
            [ -f "$f" ] && echo "$(basename "$f"): $(cat "$f" 2>/dev/null | head -c 300 | tr '\n' ' ')"
        done
    done
    ls /sys/class/typec 2>/dev/null

    echo
    echo "=== 5. drivers"
    ls -l /sys/bus/platform/devices/ | grep -i -E "pdc|pd_adapter|charger"
    ls /sys/bus/platform/drivers/ | grep -i -E "pd|charg|husb|tcpc"
    lsmod | grep -i -E "pd|charg|husb|tcpc|upm|sc896"

    echo
    echo "=== 6. kernel log"
    dmesg | grep -i -E "pdc|pd_|_pd|pd adapter|tcpc|husb|hv charg|Leo|pump|alg|upm6920|vbus" | tail -n 150
} > "$OUT" 2>&1

chmod 644 "$OUT"
echo "Saved to $OUT"
