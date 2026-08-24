#!/system/bin/sh
# Cleanup when module is uninstalled
GUARDIAN_DIR="/data/adb/android_guardian"

# Only allow uninstall if control file says DISABLED
if [ -f "$GUARDIAN_DIR/control" ]; then
  status=$(cat "$GUARDIAN_DIR/control")
  if [ "$status" != "DISABLED" ]; then
    echo "Guardian is still enabled! Use ADB to disable first:"
    echo "  adb shell 'echo DISABLED > /data/adb/android_guardian/control'"
    exit 1
  fi
fi

# Clean up guardian data
rm -rf "$GUARDIAN_DIR"
