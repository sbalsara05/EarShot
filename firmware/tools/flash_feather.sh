#!/bin/bash
# Builds the Feather firmware and flashes it over USB.
#
#   tools/flash_feather.sh
#
# PlatformIO's own upload (`pio run -e feather-s3 -t upload`) stumbles on this board: it resets
# the Feather into flashing mode, then gives up waiting for it, and afterwards the board stays
# in flashing mode instead of starting the new firmware. This script does the same job in steps
# that were tested on the board: reset into flashing mode, write, then start the firmware.
set -euo pipefail
cd "$(dirname "$0")/.."

PIO="$HOME/.platformio/penv/bin/pio"
PY="$HOME/.platformio/penv/bin/python"
ESPTOOL="$HOME/.platformio/packages/tool-esptoolpy/esptool.py"
CORE="$HOME/.platformio/packages/framework-arduinoespressif32"
# The board named in platformio.ini decides which bootloader goes on.
BOARD=$(awk '/^\[env:feather-s3\]/{f=1} f && /^board *=/{print $3; exit}' platformio.ini)

port() { ls /dev/cu.usbmodem* 2>/dev/null | head -1; }
# In flashing mode the chip shows up as Espressif's own USB device (303A:1001).
in_flashing_mode() { "$PIO" device list 2>/dev/null | grep -A3 "$(port)" | grep -qi '303A:1001'; }

"$PIO" run -e feather-s3 | grep -E 'RAM:|Flash:|SUCCESS|FAILED|rror' || true
test -f .pio/build/feather-s3/firmware.bin

if [ -z "$(port)" ]; then
  echo "No board found on USB. Check the cable carries data, not just power."
  exit 1
fi

if ! in_flashing_mode; then
  echo "Resetting the board into flashing mode..."
  # Opening the port at 1200 baud is the signal; the board drops off USB mid-close, which is expected.
  "$PY" -c 'import serial, sys; serial.Serial(sys.argv[1], 1200).close()' "$(port)" 2>/dev/null || true
  for _ in $(seq 1 20); do
    sleep 0.5
    if [ -n "$(port)" ] && in_flashing_mode; then break; fi
  done
fi
if ! in_flashing_mode; then
  echo "The board did not enter flashing mode. Hold BOOT, tap RESET, release BOOT, then run this again."
  exit 1
fi

echo "Writing firmware to $(port)..."
"$PY" "$ESPTOOL" --chip esp32s3 --port "$(port)" --baud 460800 --before default_reset --after no_reset \
  write_flash -z --flash_mode keep --flash_freq keep --flash_size detect \
  0x0000 "$CORE/variants/$BOARD/bootloader-tinyuf2.bin" \
  0x8000 .pio/build/feather-s3/partitions.bin \
  0xe000 "$CORE/tools/partitions/boot_app0.bin" \
  0x10000 .pio/build/feather-s3/firmware.bin 2>&1 | grep -E 'Wrote|verified|rror|fatal' || { echo "Flashing failed."; exit 1; }

# Start the new firmware. Two things keep the chip in flashing mode otherwise: a "stay in
# flashing mode" flag set by the reset above, and the flashing tool's own restart, which leaves
# the line that selects flashing mode asserted. So: clear the flag, then send a reset pulse
# with that line released.
"$PY" "$ESPTOOL" --chip esp32s3 --port "$(port)" --before no_reset --after no_reset \
  write_mem 0x6000812C 0x0 0x1 >/dev/null 2>&1 || true
"$PY" - "$(port)" <<'PYEOF' || true
import serial, sys, time
s = serial.Serial()
s.port = sys.argv[1]
s.dtr = False
s.rts = False
s.open()
s.rts = True     # hold reset
time.sleep(0.2)
s.rts = False    # release: normal start
time.sleep(0.2)
s.close()
PYEOF

for _ in $(seq 1 20); do
  sleep 0.5
  if [ -n "$(port)" ] && ! in_flashing_mode; then
    echo "Done. The firmware is running. Watch its log with: $PIO device monitor"
    exit 0
  fi
done
echo "Written, but the board is still in flashing mode. Press RESET to start the firmware."
