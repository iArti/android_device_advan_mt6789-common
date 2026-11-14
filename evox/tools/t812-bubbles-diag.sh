#!/system/bin/sh
#
# T812 bubbles diagnostics. Open a bubble so that the empty translucent
# rectangle is on screen, then right away run as root:
#
#   adb push t812-bubbles-diag.sh /data/local/tmp/
#   adb shell su -c "sh /data/local/tmp/t812-bubbles-diag.sh"
#   adb pull /data/local/tmp/t812-bubbles.txt
#
# Test with the OpenGL HWUI renderer instead of Vulkan (reverts on reboot):
#   adb shell su -c "sh /data/local/tmp/t812-bubbles-diag.sh --skiagl"

OUT=/data/local/tmp/t812-bubbles.txt

if [ "$1" = "--skiagl" ]; then
    setprop debug.hwui.renderer skiagl
    # SystemUI and the launcher must restart to pick the renderer up.
    pkill -f com.android.systemui
    home=$(cmd package resolve-activity --brief -c android.intent.category.HOME \
        -a android.intent.action.MAIN | tail -n 1 | cut -d/ -f1)
    [ -n "$home" ] && am force-stop "$home"
    echo "HWUI renderer is skiagl until reboot. Force-stop the app you test, then open a bubble again."
    exit 0
fi

{
    echo "=== 0. identity"
    date
    getprop ro.build.fingerprint
    for p in debug.hwui.renderer debug.renderengine.backend ro.sf.blurs_are_expensive \
             ro.surface_flinger.supports_background_blur; do
        echo "$p=$(getprop $p)"
    done
    echo "global notification_bubbles=$(settings get global notification_bubbles)"
    echo "secure notification_bubbles=$(settings get secure notification_bubbles)"

    echo
    echo "=== 1. bubbles state (SystemUI / WMShell)"
    dumpsys activity service com.android.systemui/.SystemUIService WMShell bubbles 2>&1 | head -150

    echo
    echo "=== 2. tasks"
    dumpsys activity activities | grep -i -E "Task\{|mode=|bubble|taskview|visible=" | head -80

    echo
    echo "=== 3. surfaces"
    dumpsys SurfaceFlinger --list 2>/dev/null | grep -i -E "bubble|taskview|Task=" | head -60

    echo
    echo "=== 4. log"
    logcat -d -b main -b system -b crash 2>/dev/null | grep -i -E "bubble|TaskView|WMShell|ActivityTaskManager|AndroidRuntime|FATAL|BLASTBuffer|vulkan|OpenGLRenderer" | tail -n 400
} > "$OUT" 2>&1

chmod 644 "$OUT"
echo "Saved to $OUT"
