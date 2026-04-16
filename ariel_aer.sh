#!/bin/bash
#
# NVMe AER Identification & Blink Script
# Automates finding PCIe AER events and visually identifying the faulty NVMe drives.

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mPlease run this script as root (using sudo).\e[0m"
  exit 1
fi

echo -e "\e[36m==================================================\e[0m"
echo -e "\e[1;36m       NVMe AER Event Locator & Blink Tool        \e[0m"
echo -e "\e[36m==================================================\e[0m"

# Step 1: Find AER events since last boot using journalctl
echo "Scanning kernel logs (since last boot) for PCIe AER events..."

# Extract unique PCIe addresses reporting AER errors
AER_PCI_DEVS=$(journalctl -k -b | grep -i "AER:" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]' | sort -u)

if [ -z "$AER_PCI_DEVS" ]; then
    echo -e "\e[32mNo AER events found since the last boot! The system is currently clean.\e[0m"
    exit 0
fi

declare -A NVME_MAP
declare -A ROOT_MAP

echo -e "\n\e[33mFound AER events on the following PCIe paths:\e[0m"

# Step 2: Map PCIe paths to NVMe devices and topology
for PCI_ADDR in $AER_PCI_DEVS; do
    # 1. Find the NVMe character device (e.g., nvme23)
    NVME_DEV=$(ls /sys/bus/pci/devices/$PCI_ADDR/nvme/ 2>/dev/null | head -n 1)
    
    # 2. Find the Root Complex/Bridge to group by "Card"
    # The parent of the device is the PCIe switch on the motherboard or adapter
    PARENT_BRIDGE=$(basename $(dirname $(readlink -f /sys/bus/pci/devices/$PCI_ADDR)))
    ROOT_COMPLEX=$(basename $(dirname $(dirname $(readlink -f /sys/bus/pci/devices/$PCI_ADDR))))

    if [ -n "$NVME_DEV" ]; then
        # 3. Get Serial Number (suppress errors if nvme-cli fails)
        SN=$(nvme id-ctrl /dev/$NVME_DEV 2>/dev/null | grep "^sn " | awk '{print $3}')
        [ -z "$SN" ] && SN="Unknown"

        echo -e " - \e[1;31m$PCI_ADDR\e[0m -> \e[1;32m/dev/$NVME_DEV\e[0m (SN: $SN)"
        echo "   Location: Connected via Bridge $PARENT_BRIDGE (Motherboard Root Slot: $ROOT_COMPLEX)"
        
        # Save mappings for the interactive blink test
        NVME_MAP[$PCI_ADDR]=$NVME_DEV
        ROOT_MAP[$PCI_ADDR]=$ROOT_COMPLEX
    else
        echo -e " - \e[1;31m$PCI_ADDR\e[0m -> (No NVMe device found. The drive might be disconnected or failed)"
    fi
done

# Step 3: Interactive Blink Prompt
echo -e "\n\e[36m==================================================\e[0m"
echo -e "Ready to perform the 'Blink' test."
echo -e "This will run a safe, heavy read test on the drive to flash its activity LED."
echo -e "\e[36m==================================================\e[0m"

for PCI_ADDR in "${!NVME_MAP[@]}"; do
    NVME_DEV=${NVME_MAP[$PCI_ADDR]}
    BLOCK_DEV="${NVME_DEV}n1" # Target the namespace block device, e.g., nvme23n1

    read -p "Do you want to blink $BLOCK_DEV (PCI: $PCI_ADDR)? [y/N]: " RUN_BLINK
    
    if [[ "$RUN_BLINK" =~ ^[Yy]$ ]]; then
        if [ -b "/dev/$BLOCK_DEV" ]; then
            echo -e "\n\e[1;33m>>> Blinking /dev/$BLOCK_DEV <<<\e[0m"
            echo -e "Look at your server \e[1;31mNOW\e[0m to identify the flashing slot on the card."
            echo -e "Press \e[1;32m[ENTER]\e[0m to stop blinking and continue..."
            
            # Run dd in the background, directing output to /dev/null
            dd if=/dev/$BLOCK_DEV of=/dev/null bs=1M status=none &
            DD_PID=$!
            
            # Wait for the user to press Enter
            read -r
            
            # Kill the background dd process gracefully
            kill $DD_PID 2>/dev/null
            wait $DD_PID 2>/dev/null
            echo -e "\e[32mStopped blinking /dev/$BLOCK_DEV.\e[0m\n"
        else
            echo -e "\e[31mError: Block device /dev/$BLOCK_DEV not found. Skipping.\e[0m\n"
        fi
    fi
done

echo -e "\e[32mDiagnostic script complete.\e[0m"