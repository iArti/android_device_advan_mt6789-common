#!/system/bin/sh
#
# Set the battery charging current of the Advan Tab V8 / Alldocube iPlay 60
# mini Pro (T812).
#
# The limit is not in the ROM: the preloader loads the "csci" partition (an
# ODM key/value config) and mtk_charger_framework reads "ac_charger_current"
# from it, overriding the device tree. Stock value: 2500000 (2.5 A).
# This script rewrites only that value, keeping the length of the config, so
# nothing else in the partition moves. The partition is not part of the ROM
# or OTA, so the change survives ROM updates.
#
# Current notes (USB PD charger, 9 V / 2 A contract, input limit 2.05 A):
#   - 3200 mA (default here): ~13 W into the battery, mild heat.
#   - Up to 3500 mA was tested stable: battery ~35 C, board (ap_ntc) ~45 C.
#     At 3.5 A the charger draws ~1.8 A at 9 V, still inside the 2 A contract.
#   - Above 3500 mA you approach the 9 V x 2.05 A input limit (~3.9-4.1 A at
#     the battery) and the PD contract; requires --force.
#   - With 5 V chargers the input limit (~2.3 A at the battery) wins, so a
#     higher value changes nothing there.
#   - thermal_core still cuts the current to 3.0/2.5/2.0/0 A at ap_ntc
#     51/52/53/56 C, and the charger driver throttles at battery 45/50 C.
#
# Usage (as root on the tablet):
#   sh t812-csci-charging.sh                 # set 3200 mA
#   sh t812-csci-charging.sh 3500            # set 3500 mA
#   sh t812-csci-charging.sh --show          # print the current value
#   sh t812-csci-charging.sh --restore       # write the stock backup back
#   sh t812-csci-charging.sh --dry-run 3300  # only build and check the image
# Reboot afterwards: the value is read once at boot.

set -e

DEV=/dev/block/by-name/csci
STOCK=/sdcard/csci_stock.img
TMP=/data/local/tmp/csci_work.img
KEY=ac_charger_current
STOCK_VALUE=2500000
DEFAULT_MA=3200
MIN_MA=1000
MAX_MA=3500

MA=$DEFAULT_MA
MODE="set"
DRY=0
FORCE=0

die() { echo "error: $*" >&2; exit 1; }

size_of() {
    if [ -b "$1" ]; then blockdev --getsize64 "$1"; else stat -c %s "$1"; fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --show) MODE=show ;;
        --restore) MODE=restore ;;
        --dry-run) DRY=1 ;;
        --force) FORCE=1 ;;
        --device) DEV="$2"; shift ;;
        --stock) STOCK="$2"; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *[!0-9]*|'') die "unknown argument: $1" ;;
        *) MA="$1" ;;
    esac
    shift
done

[ "$(id -u)" = 0 ] || die "run as root (su)"
[ -e "$DEV" ] || die "$DEV not found"

# Prints "<byte offset of the value> <value>" of the single KEY line.
find_value() {
    m=$(grep -a -b -o -E "^$KEY +[0-9]{7}$" "$1" || true)
    [ -n "$m" ] || die "no '$KEY <7 digits>' line in $1"
    [ "$(echo "$m" | wc -l)" -eq 1 ] || die "more than one '$KEY' line in $1"
    off=${m%%:*}
    line=${m#*:}
    val=${line##* }
    echo "$((off + ${#line} - 7)) $val"
}

case "$MODE" in
show)
    v=$(find_value "$DEV") || exit 1
    set -- $v
    echo "$KEY = $2 uA ($(( $2 / 1000 )) mA), byte offset $1"
    exit 0
    ;;
restore)
    [ -f "$STOCK" ] || die "no stock backup at $STOCK"
    [ "$(stat -c %s "$STOCK")" = "$(size_of "$DEV")" ] || die "backup size differs from $DEV"
    dd if="$STOCK" of="$DEV" bs=1M conv=fsync 2>/dev/null
    sync
    [ "$(sha256sum < "$DEV")" = "$(sha256sum < "$STOCK")" ] || die "verify after restore FAILED, retry"
    echo "Restored stock csci. Reboot to apply."
    exit 0
    ;;
esac

[ "$MA" -ge "$MIN_MA" ] || die "$MA mA is below $MIN_MA mA"
if [ "$MA" -gt "$MAX_MA" ] && [ "$FORCE" != 1 ]; then
    die "$MA mA is above the tested $MAX_MA mA, add --force if you really mean it"
fi
[ "$MA" -le 9999 ] || die "value must fit in 7 digits (max 9999 mA)"
NEW=$(printf '%07d' $((MA * 1000)))

# One-time stock backup, never overwritten. Only take it from an unmodified
# partition, otherwise --restore would bring back a patched value.
if [ ! -f "$STOCK" ]; then
    v=$(find_value "$DEV") || exit 1
    set -- $v
    [ "$2" = "$STOCK_VALUE" ] || die "csci already modified ($KEY = $2) and no stock backup at $STOCK; copy your original dump there first"
    dd if="$DEV" of="$STOCK" bs=1M 2>/dev/null
    echo "Stock backup saved to $STOCK (copy it to your PC)"
fi

dd if="$DEV" of="$TMP" bs=1M 2>/dev/null
v=$(find_value "$TMP") || exit 1
set -- $v
OFF=$1
OLD=$2
echo "current $KEY = $OLD, new = $NEW"
if [ "$OLD" = "$NEW" ]; then
    echo "Nothing to do."
    exit 0
fi

printf '%s' "$NEW" | dd of="$TMP" bs=1 seek="$OFF" conv=notrunc 2>/dev/null
v=$(find_value "$TMP") || exit 1
set -- $v
[ "$1" = "$OFF" ] && [ "$2" = "$NEW" ] || die "patched image check failed"
CHANGED=$(cmp -l "$DEV" "$TMP" | wc -l)
[ "$CHANGED" -ge 1 ] && [ "$CHANGED" -le 7 ] || die "unexpected diff ($CHANGED bytes), aborting"
echo "image ok: $CHANGED byte(s) differ, sha256 $(sha256sum < "$TMP" | cut -d' ' -f1)"

if [ "$DRY" = 1 ]; then
    echo "Dry run: $DEV not written."
    exit 0
fi

dd if="$TMP" of="$DEV" bs=1M conv=fsync 2>/dev/null
sync
[ "$(sha256sum < "$DEV")" = "$(sha256sum < "$TMP")" ] || die "verify after write FAILED, run --restore"
rm -f "$TMP"
echo "Written: $KEY = $NEW ($MA mA). Reboot to apply."
