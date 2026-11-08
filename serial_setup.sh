#!/bin/bash

set -e

GRUB_FILE="/etc/default/grub"

echo "=== AlmaLinux Serial Console Setup ==="

# 1. Backup
echo "[1/6] Backing up GRUB configuration..."
cp -a "$GRUB_FILE" "${GRUB_FILE}.bak"

# 2. Configure GRUB serial terminal
echo "[2/6] Configuring GRUB terminal..."

if grep -q '^GRUB_TERMINAL=' "$GRUB_FILE"; then
    sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL="console serial"/' "$GRUB_FILE"
else
    echo 'GRUB_TERMINAL="console serial"' >> "$GRUB_FILE"
fi

# 3. Configure serial parameters
echo "[3/6] Configuring serial port parameters..."

if grep -q '^GRUB_SERIAL_COMMAND=' "$GRUB_FILE"; then
    sed -i 's/^GRUB_SERIAL_COMMAND=.*/GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"/' "$GRUB_FILE"
else
    echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >> "$GRUB_FILE"
fi

# 4. Add serial console to all installed kernels
echo "[4/6] Adding kernel console parameters..."

grubby --update-kernel=ALL \
    --args="console=tty0 console=ttyS0,115200n8"

# 5. Enable serial login console
echo "[5/6] Enabling serial-getty..."

systemctl enable serial-getty@ttyS0.service

# 6. Regenerate GRUB configuration
echo "[6/6] Regenerating GRUB configuration..."

grub2-mkconfig -o /boot/grub2/grub.cfg

echo
echo "Serial console configuration completed."
echo
echo "After reboot verify with:"
echo "  cat /proc/cmdline"
echo "  systemctl status serial-getty@ttyS0.service"
echo
echo "Expected serial settings:"
echo "  ttyS0"
echo "  115200 baud"
echo "  8 data bits"
echo "  no parity"
echo "  1 stop bit"
echo
echo "Reboot with:"
echo "  sudo reboot"
