#!/bin/bash
DEVICE_SERIAL="BL9000EEA0000102"
BACKUP_BASE="/home/kuhy/testsAndMisc_binaries/phone_focus_mode_backups"
APPS_TO_UNINSTALL=("com.android.settings" "com.android.systemui" "com.google.android.gms" "com.google.android.apps.docs" "com.google.android.apps.maps")
SUBSTITUTE_APPS=("com.android.tv" "com.android.managedprovisioning" "com.google.android.apps.fitness" "com.google.android.apps.books" "com.google.android.apps.wellbeing" "com.google.android.apps.mediashell")

function log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

function verify_device() {
  adb -s "$DEVICE_SERIAL" shell echo "Device OK" &>/dev/null
  [ $? -ne 0 ] && log_msg "ERROR: Device not accessible" && exit 1
}

function get_app_version() {
  adb -s "$DEVICE_SERIAL" shell dumpsys package "$1" 2>/dev/null | grep "versionName=" | head -1 | cut -d'=' -f2
}

function app_exists() {
  adb -s "$DEVICE_SERIAL" shell pm list packages | grep -q "^package:${1}$"
}

function get_substitute() {
  for sub in "${SUBSTITUTE_APPS[@]}"; do
    app_exists "$sub" && echo "$sub" && return 0
  done
  return 1
}

function execute_checkpoint() {
  local pkg=$1 app_num=$2
  log_msg "========================================="
  log_msg "APP #${app_num}: Processing $pkg"
  log_msg "========================================="

  if ! app_exists "$pkg"; then
    log_msg "WARNING: $pkg not found. Searching for substitute..."
    actual_pkg=$(get_substitute "$pkg")
    [ -z "$actual_pkg" ] && log_msg "ERROR: Could not find substitute. Skipping." && return 1
    log_msg "SUBSTITUTING: Using $actual_pkg"
    pkg="$actual_pkg"
  fi

  TIMESTAMP=$(date +%s)
  CHECKPOINT_DIR="${BACKUP_BASE}/checkpoint_${TIMESTAMP}_${pkg}"
  mkdir -p "$CHECKPOINT_DIR"
  log_msg "Checkpoint: $CHECKPOINT_DIR"

  log_msg "[1/6] Pulling APK..."
  adb -s "$DEVICE_SERIAL" shell pm path "$pkg" > "$CHECKPOINT_DIR/package_path.txt"
  if grep -q "^package:" "$CHECKPOINT_DIR/package_path.txt"; then
    APK_PATH=$(grep "^package:" "$CHECKPOINT_DIR/package_path.txt" | cut -d':' -f2)
    pull_log="$CHECKPOINT_DIR/pull_output.txt"
    adb -s "$DEVICE_SERIAL" pull "$APK_PATH" "$CHECKPOINT_DIR/app.apk" > "$pull_log" 2>&1 || true
    if ! grep -e "Pull" -e "error" "$pull_log"; then
      log_msg "APK pulled"
    fi
  fi

  log_msg "[2/6] Backing up PM state..."
  adb -s "$DEVICE_SERIAL" shell dumpsys package "$pkg" > "$CHECKPOINT_DIR/pm_state.txt"
  VNAME=$(get_app_version "$pkg")
  log_msg "Version: $VNAME"

  log_msg "[3/6] Taking snapshot..."
  adb -s "$DEVICE_SERIAL" shell dumpsys activity activities > "$CHECKPOINT_DIR/activities_before.txt"
  adb -s "$DEVICE_SERIAL" shell pm list packages > "$CHECKPOINT_DIR/packages_before.txt"

  log_msg "[4/6] Uninstalling: pm uninstall --user 0 $pkg"
  adb -s "$DEVICE_SERIAL" shell pm uninstall --user 0 "$pkg" > "$CHECKPOINT_DIR/uninstall_output.txt" 2>&1
  UNINSTALL_RESULT=$(cat "$CHECKPOINT_DIR/uninstall_output.txt")
  log_msg "Result: $UNINSTALL_RESULT"

  log_msg "[5/6] Rebooting device..."
  adb -s "$DEVICE_SERIAL" reboot
  sleep 5

  REBOOT_TIMEOUT=180
  WAIT_START=$(date +%s)
  while true; do
    adb -s "$DEVICE_SERIAL" shell echo "up" &>/dev/null && break
    [ $(($(date +%s) - WAIT_START)) -ge $REBOOT_TIMEOUT ] && log_msg "ERROR: Timeout" && break
    sleep 3
    echo -n "."
  done
  echo ""

  sleep 5
  adb -s "$DEVICE_SERIAL" shell pm list packages > "$CHECKPOINT_DIR/packages_after.txt"

  if adb -s "$DEVICE_SERIAL" shell pm list packages | grep -q "^package:${pkg}$"; then
    log_msg "WARNING: $pkg still present"
  else
    log_msg "SUCCESS: $pkg uninstalled"
  fi

  log_msg "[6/6] Generating report..."
  cat > "$CHECKPOINT_DIR/report.txt" <<< "CHECKPOINT REPORT: $pkg (Timestamp: $TIMESTAMP, Device: $DEVICE_SERIAL) - Version: $VNAME - Result: $UNINSTALL_RESULT - Checkpoint: $CHECKPOINT_DIR"
  log_msg "✓ Complete"
  return 0
}

log_msg "========================================="
log_msg "BATCH 3: BLOATWARE UNINSTALL"
log_msg "========================================="
verify_device
log_msg "Device verified"

for i in "${!APPS_TO_UNINSTALL[@]}"; do
  execute_checkpoint "${APPS_TO_UNINSTALL[$i]}" $((i + 1))
  [ $((i + 1)) -lt ${#APPS_TO_UNINSTALL[@]} ] && sleep 5
done

log_msg "========================================="
log_msg "BATCH 3 COMPLETE"
log_msg "========================================="
