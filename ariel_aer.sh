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

# Step 1: Check journalctl health and find AER events since last boot
echo "Scanning kernel logs (since last boot) for PCIe AER events..."

# Function to check journalctl health and return error messages if any
# Only reports errors if journalctl fails to return usable kernel log data
check_journalctl_health() {
    local output
    local errors=""
    
    # Capture both stdout and stderr
    output=$(journalctl -k -b 2>&1)
    local exit_code=$?
    
    # Check if we can actually get kernel log entries (the important part)
    local kernel_entries=$(echo "$output" | grep -E "^[A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*kernel:" | head -5)
    
    # Only report errors if:
    # 1. Exit code is non-zero AND no kernel entries found (fatal error)
    # 2. Explicit "No journal files were found" error
    # 3. Explicit "Cannot access journal" error
    
    if [ $exit_code -ne 0 ] && [ -z "$kernel_entries" ]; then
        errors="${errors}journalctl exited with error code $exit_code and no kernel entries found\n"
    fi
    
    if echo "$output" | grep -q "No journal files were found"; then
        errors="${errors}No journal files found\n"
    fi
    
    if echo "$output" | grep -q "Cannot access journal"; then
        errors="${errors}Cannot access journal (permissions or path issue)\n"
    fi
    
    # Note: "Journal file uses a different" is just a warning about user journal format
    # differences and doesn't prevent reading system kernel logs. We ignore it.
    
    # Return errors if any, empty string if healthy
    echo -e "$errors"
}

# Log file location
LOG_FILE="$HOME/nvme_aer_errors.log"

# Function to get system boot time (Unix timestamp)
get_boot_time() {
    # Get boot time from /proc/stat or uptime calculation
    local uptime_seconds=$(cat /proc/uptime | awk '{print $1}')
    local now=$(date +%s)
    echo $(echo "$now - $uptime_seconds" | bc | cut -d. -f1)
}

# Function to convert dmesg timestamp to actual date/time
convert_dmesg_time() {
    local dmesg_seconds=$1
    local boot_time=$(get_boot_time)
    # Add seconds since boot to boot time
    echo $(date -d "@$(echo "$boot_time + $dmesg_seconds" | bc)" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
}

# Function to extract AER events with timestamps from dmesg
get_aer_events_from_dmesg() {
    local -n pci_array=$1
    local -n time_array=$2
    local -n error_array=$3
    
    while IFS= read -r line; do
        # Extract timestamp [   7.223321]
        local timestamp=$(echo "$line" | grep -oP '^\[\s*\K[0-9]+\.[0-9]+' || echo "0")
        # Extract PCI address
        local pci_addr=$(echo "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]' | head -1)
        # Extract error type
        local error_type=$(echo "$line" | grep -oE 'aer_status:.*$' | sed 's/aer_status: //' | cut -d',' -f1)
        if [ -z "$error_type" ]; then
            error_type=$(echo "$line" | grep -oE '\[\s*[0-9]+\]\s*\K[^\(]+' | sed 's/ *$//' || echo "unknown")
        fi
        
        if [ -n "$pci_addr" ]; then
            pci_array+=("$pci_addr")
            time_array+=("$timestamp")
            error_array+=("$error_type")
        fi
    done < <(dmesg | grep -i "AER:" | head -20)
}

# Function to run journalctl and extract AER events
get_aer_events_from_journalctl() {
    local -n pci_array=$1
    local -n time_array=$2
    local -n error_array=$3
    
    while IFS= read -r line; do
        # Extract PCI address
        local pci_addr=$(echo "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]' | head -1)
        # Extract timestamp from journalctl format
        local timestamp=$(echo "$line" | grep -oP '^[A-Za-z]{3} \d{2} \d{2}:\d{2}:\d{2}' || echo "unknown")
        # Extract error type
        local error_type=$(echo "$line" | grep -oE 'aer_status:.*$' | sed 's/aer_status: //' | cut -d',' -f1)
        if [ -z "$error_type" ]; then
            error_type=$(echo "$line" | grep -oE '\[\s*[0-9]+\]\s*\K[^\(]+' | sed 's/ *$//' || echo "unknown")
        fi
        
        if [ -n "$pci_addr" ]; then
            pci_array+=("$pci_addr")
            time_array+=("$timestamp")
            error_array+=("$error_type")
        fi
    done < <(journalctl -k -b 2>/dev/null | grep -i "AER:" | head -20)
}

# Function to check if journalctl has kernel messages
journalctl_has_kernel_data() {
    local kernel_count=$(journalctl -k -b 2>/dev/null | grep -c "^[A-Za-z]{3} [0-9]\{2\}")
    [ "$kernel_count" -gt 0 ]
}

# Function to log AER error to file
log_aer_error() {
    local pci_addr=$1
    local nvme_dev=$2
    local serial=$3
    local slot_info=$4
    local error_type=$5
    local source=$6
    local timestamp=$7
    
    # Create log file with header if it doesn't exist
    if [ ! -f "$LOG_FILE" ]; then
        echo "unix_timestamp,date_time,boot_time,serial_number,pci_address,slot_location,error_type,source,nvme_device" > "$LOG_FILE"
    fi
    
    local now=$(date +%s)
    local date_time=$(date "+%Y-%m-%d %H:%M:%S")
    local boot_time=$(get_boot_time)
    local boot_time_readable=$(date -d "@$boot_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
    
    # Check if this error is already logged for this boot
    local already_logged=false
    if [ -f "$LOG_FILE" ]; then
        # Check for same serial + PCI + boot_time in last 24 hours
        local recent_entries=$(grep "$serial,$pci_addr," "$LOG_FILE" | grep "$boot_time_readable" | wc -l)
        [ "$recent_entries" -gt 0 ] && already_logged=true
    fi
    
    if [ "$already_logged" = false ]; then
        echo "$now,$date_time,$boot_time_readable,$serial,$pci_addr,$slot_info,$error_type,$source,$nvme_dev" >> "$LOG_FILE"
    fi
}

# Function to view error history
view_error_history() {
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "\e[33mNo error log file found at $LOG_FILE\e[0m"
        return
    fi
    
    echo -e "\n\e[36m==================================================\e[0m"
    echo -e "\e[1;36m       NVMe AER Error History Log\e[0m"
    echo -e "\e[36m==================================================\e[0m"
    echo ""
    echo -e "\e[33mRecent errors (last 20 entries):\e[0m"
    echo ""
    
    # Read and display log (skip header, show last 20)
    tail -n 21 "$LOG_FILE" | while IFS=',' read -r unix_ts date_time boot_time serial pci slot error source nvme; do
        [ "$unix_ts" = "unix_timestamp" ] && continue
        echo -e "  \e[1;31m$date_time\e[0m - SN: \e[32m$serial\e[0m"
        echo -e "    \e[1;31m$pci\e[0m -> \e[1;32m/dev/$nvme\e[0m"
        echo -e "    Slot: $slot"
        echo -e "    Error: \e[33m$error\e[0m | Source: $source"
        echo -e "    Boot time: $boot_time"
        echo ""
    done
    
    echo -e "\e[36mLog file: $LOG_FILE\e[0m"
    echo -e "\e[36mTotal entries: $(tail -n +2 "$LOG_FILE" | wc -l)\e[0m"
    echo ""
}

# Function to get AER events (tries journalctl first, falls back to dmesg)
get_aer_events() {
    declare -a pci_addrs=()
    declare -a timestamps=()
    declare -a error_types=()
    
    if journalctl_has_kernel_data; then
        # Use journalctl
        get_aer_events_from_journalctl pci_addrs timestamps error_types
        echo "journalctl" >&2
    else
        # Fall back to dmesg
        echo -e "\e[33m[journalctl has no kernel data, using dmesg fallback]\e[0m" >&2
        get_aer_events_from_dmesg pci_addrs timestamps error_types
        echo "dmesg" >&2
    fi
    
    # Output unique PCI addresses with their first timestamp
    declare -A seen
    for i in "${!pci_addrs[@]}"; do
        local pci="${pci_addrs[$i]}"
        if [ -z "${seen[$pci]}" ]; then
            seen[$pci]=1
            # Output format: PCI_ADDR|TIMESTAMP|ERROR_TYPE
            echo "${pci}|${timestamps[$i]}|${error_types[$i]}"
        fi
    done | sort -t'|' -k1,1 -u
}

# Function to display remediation menu and handle user choices
handle_journal_errors() {
    local errors="$1"
    
    echo -e "\e[31m==================================================\e[0m"
    echo -e "\e[1;31m[!] Journalctl errors detected:\e[0m"
    echo -e "\e[31m==================================================\e[0m"
    echo -e "\e[33m$errors\e[0m"
    echo ""
    
    # Define available remediations
    declare -a remediation_names=(
        "journalctl --rotate (rotate journal files - recommended)"
        "journalctl --vacuum-time=1d (remove entries older than 1 day)"
        "journalctl --vacuum-size=100M (limit journal size to 100MB)"
        "systemctl restart systemd-journald (restart journal service)"
        "Check disk space on /var/log/journal"
    )
    
    declare -a remediation_cmds=(
        "journalctl --rotate"
        "journalctl --vacuum-time=1d"
        "journalctl --vacuum-size=100M"
        "systemctl restart systemd-journald"
        "df -h /var/log/journal"
    )
    
    echo -e "\e[36mAvailable remediation options:\e[0m"
    for i in "${!remediation_names[@]}"; do
        num=$((i + 1))
        echo "  [$num] ${remediation_names[$i]}"
    done
    echo "  [all] Run all remediations in sequence"
    echo "  [skip] Skip remediation and exit"
    echo ""
    
    # Get user selection
    read -p "Select which remediations to run (e.g., 1,3 or 'all', or 'skip'): " selection
    
    if [ "$selection" == "skip" ]; then
        echo -e "\e[33mExiting as requested. You can run the remediations manually.\e[0m"
        exit 1
    fi
    
    # Parse selection
    declare -a selected_indices=()
    if [ "$selection" == "all" ]; then
        for i in "${!remediation_names[@]}"; do
            selected_indices+=($i)
        done
    else
        # Parse comma-separated numbers
        IFS=',' read -ra nums <<< "$selection"
        for num in "${nums[@]}"; do
            idx=$((num - 1))
            if [ $idx -ge 0 ] && [ $idx -lt ${#remediation_names[@]} ]; then
                selected_indices+=($idx)
            else
                echo -e "\e[31mInvalid option: $num\e[0m"
            fi
        done
    fi
    
    if [ ${#selected_indices[@]} -eq 0 ]; then
        echo -e "\e[31mNo valid selections made. Exiting.\e[0m"
        exit 1
    fi
    
    # Ask execution preference
    echo ""
    read -p "Run these automatically now, or exit to run manually? [a=auto/m=manual]: " exec_choice
    
    if [ "$exec_choice" == "m" ] || [ "$exec_choice" == "manual" ]; then
        echo -e "\e[33mExiting. Run these commands manually:\e[0m"
        for idx in "${selected_indices[@]}"; do
            echo "  ${remediation_cmds[$idx]}"
        done
        exit 1
    fi
    
    # Execute selected remediations
    echo -e "\e[36mExecuting selected remediations...\e[0m"
    for idx in "${selected_indices[@]}"; do
        echo -e "\n\e[33m>>> Running: ${remediation_names[$idx]}\e[0m"
        eval "${remediation_cmds[$idx]}"
        if [ $? -eq 0 ]; then
            echo -e "\e[32m[OK] Completed successfully\e[0m"
        else
            echo -e "\e[31m[ERROR] Command failed\e[0m"
        fi
        sleep 1
    done
    
    echo -e "\n\e[36mRemediation complete. Re-checking journalctl health...\e[0m"
}

# Main journalctl health check loop
MAX_RETRIES=2
retry_count=0

while [ $retry_count -lt $MAX_RETRIES ]; do
    journal_errors=$(check_journalctl_health)
    
    if [ -z "$journal_errors" ]; then
        # Journalctl is healthy, proceed
        break
    fi
    
    # Errors detected, handle them
    handle_journal_errors "$journal_errors"
    retry_count=$((retry_count + 1))
done

# Final check after remediations
journal_errors=$(check_journalctl_health)
if [ -n "$journal_errors" ]; then
    echo -e "\e[31m==================================================\e[0m"
    echo -e "\e[1;31m[!] Journalctl still has issues after remediation:\e[0m"
    echo -e "\e[31m==================================================\e[0m"
    echo -e "\e[33m$journal_errors\e[0m"
    echo ""
    echo -e "\e[31mCannot proceed with AER detection. Please fix journalctl manually.\e[0m"
    exit 1
fi

# Extract AER events with metadata
declare -A AER_TIMESTAMPS
declare -A AER_ERROR_TYPES
declare -A AER_SOURCES

# Get AER data and source
AER_DATA=$(get_aer_events 2>/dev/null)
LOG_SOURCE=$(get_aer_events 2>&1 >/dev/null | tail -1)

# Parse the output
declare -a AER_PCI_LIST=()
while IFS='|' read -r pci_addr timestamp error_type; do
    [ -z "$pci_addr" ] && continue
    AER_PCI_LIST+=("$pci_addr")
    AER_TIMESTAMPS[$pci_addr]="$timestamp"
    AER_ERROR_TYPES[$pci_addr]="$error_type"
    AER_SOURCES[$pci_addr]="$LOG_SOURCE"
done <<< "$AER_DATA"

if [ ${#AER_PCI_LIST[@]} -eq 0 ]; then
    echo -e "\e[32mNo AER events found since the last boot! The system is currently clean.\e[0m"
    exit 0
fi

declare -A NVME_MAP
declare -A ROOT_MAP

echo -e "\n\e[33mFound AER events on the following PCIe paths:\e[0m"

# Step 2: Map PCIe paths to NVMe devices and topology
for PCI_ADDR in "${AER_PCI_LIST[@]}"; do
    # 1. Find the NVMe character device (e.g., nvme23)
    NVME_DEV=$(ls /sys/bus/pci/devices/$PCI_ADDR/nvme/ 2>/dev/null | head -n 1)
    
    # 2. Find the Root Complex/Bridge to group by "Card"
    # The parent of the device is the PCIe switch on the motherboard or adapter
    PARENT_BRIDGE=$(basename $(dirname $(readlink -f /sys/bus/pci/devices/$PCI_ADDR)))
    ROOT_COMPLEX=$(basename $(dirname $(dirname $(readlink -f /sys/bus/pci/devices/$PCI_ADDR))))
    
    INFERRED_NOTE=""

    if [ -n "$NVME_DEV" ]; then
        # Direct NVMe device found
        :
    else
        # Check if this is a bridge with NVMe devices downstream
        # Look for subordinate bus information
        if [ -f "/sys/bus/pci/devices/$PCI_ADDR/subordinate_bus" ]; then
            SUBORDINATE_BUS=$(cat /sys/bus/pci/devices/$PCI_ADDR/subordinate_bus 2>/dev/null)
            SECONDARY_BUS=$(cat /sys/bus/pci/devices/$PCI_ADDR/secondary_bus_number 2>/dev/null)
            
            if [ -n "$SECONDARY_BUS" ]; then
                # Search for NVMe devices on the secondary bus (downstream)
                # Format: 0000:XX:YY.Z where XX is the bus number
                BUS_HEX=$(printf "%02x" $SECONDARY_BUS 2>/dev/null || echo "$SECONDARY_BUS")
                # Use find to search for NVMe devices on the secondary bus
                nvme_path=$(find /sys/bus/pci/devices -maxdepth 1 -name "0000:${BUS_HEX}:*" -exec test -d {}/nvme \; -print -quit 2>/dev/null)
                if [ -n "$nvme_path" ] && [ -d "$nvme_path/nvme" ]; then
                    # Found an NVMe device downstream of this bridge
                    NVME_DEV=$(ls "$nvme_path/nvme/" 2>/dev/null | head -n 1)
                    DOWNSTREAM_PCI=$(basename "$nvme_path")
                    INFERRED_NOTE=" [inferred from bridge $PCI_ADDR -> downstream device $DOWNSTREAM_PCI]"
                fi
            fi
        fi
        
        # Alternative: try to find by looking at all PCI devices and checking their parent
        if [ -z "$NVME_DEV" ]; then
            for pci_dev_path in /sys/bus/pci/devices/0000:*; do
                if [ -d "$pci_dev_path/nvme" ]; then
                    # Check if this NVMe device's parent is the bridge we're looking at
                    parent=$(basename $(dirname $(readlink -f "$pci_dev_path")))
                    if [ "$parent" = "$PCI_ADDR" ]; then
                        NVME_DEV=$(ls "$pci_dev_path/nvme/" 2>/dev/null | head -n 1)
                        DOWNSTREAM_PCI=$(basename "$pci_dev_path")
                        INFERRED_NOTE=" [inferred from bridge $PCI_ADDR -> downstream device $DOWNSTREAM_PCI]"
                        break
                    fi
                fi
            done
        fi
    fi

    if [ -n "$NVME_DEV" ]; then
        # 3. Get Serial Number (suppress errors if nvme-cli fails)
        SN=$(nvme id-ctrl /dev/$NVME_DEV 2>/dev/null | grep "^sn " | awk '{print $3}')
        [ -z "$SN" ] && SN="Unknown"

        # Get timestamp and error info
        timestamp="${AER_TIMESTAMPS[$PCI_ADDR]}"
        error_type="${AER_ERROR_TYPES[$PCI_ADDR]}"
        source="${AER_SOURCES[$PCI_ADDR]}"
        
        # Convert timestamp if from dmesg (numeric seconds)
        display_time=""
        if [[ "$timestamp" =~ ^[0-9]+\.[0-9]+$ ]]; then
            # It's dmesg format (seconds since boot)
            display_time=$(convert_dmesg_time "$timestamp")
            echo -e " - \e[1;31m$PCI_ADDR\e[0m -> \e[1;32m/dev/$NVME_DEV\e[0m (SN: $SN)${INFERRED_NOTE}"
            echo -e "   \e[33mFirst error: $display_time (${timestamp}s after boot)\e[0m"
        else
            # It's journalctl format (already readable)
            display_time="$timestamp"
            echo -e " - \e[1;31m$PCI_ADDR\e[0m -> \e[1;32m/dev/$NVME_DEV\e[0m (SN: $SN)${INFERRED_NOTE}"
            echo -e "   \e[33mFirst error: $display_time\e[0m"
        fi
        echo "   Location: Connected via Bridge $PARENT_BRIDGE (Motherboard Root Slot: $ROOT_COMPLEX)"
        [ -n "$error_type" ] && echo -e "   \e[33mError type: $error_type\e[0m"
        
        # Log the error
        log_aer_error "$PCI_ADDR" "$NVME_DEV" "$SN" "Bridge $PARENT_BRIDGE/Root $ROOT_COMPLEX" "$error_type" "$source" "$timestamp"
        
        # Save mappings for the interactive blink test
        NVME_MAP[$PCI_ADDR]=$NVME_DEV
        ROOT_MAP[$PCI_ADDR]=$ROOT_COMPLEX
    else
        echo -e " - \e[1;31m$PCI_ADDR\e[0m -> (No NVMe device found. The drive might be disconnected or failed)"
    fi
done

# Step 3: Build list of devices with AER errors for menu
declare -a PCI_LIST=()
for PCI_ADDR in "${AER_PCI_LIST[@]}"; do
    PCI_LIST+=("$PCI_ADDR")
done

# Function to blink a specific device
blink_device() {
    local pci_addr=$1
    local nvme_dev=${NVME_MAP[$pci_addr]}
    local block_dev="${nvme_dev}n1"
    
    if [ -z "$nvme_dev" ]; then
        echo -e "\e[31mError: No NVMe device found for $pci_addr\e[0m"
        return 1
    fi
    
    if [ ! -b "/dev/$block_dev" ]; then
        echo -e "\e[31mError: Block device /dev/$block_dev not found.\e[0m"
        return 1
    fi
    
    echo -e "\n\e[1;33m>>> Blinking /dev/$block_dev (PCI: $pci_addr) <<<\e[0m"
    echo -e "Look at your server \e[1;31mNOW\e[0m to identify the flashing slot on the card."
    echo -e "Press \e[1;32m[ENTER]\e[0m to stop blinking..."
    
    # Run dd in the background
    dd if=/dev/$block_dev of=/dev/null bs=1M status=none &
    local dd_pid=$!
    
    # Wait for user to press Enter
    read -r
    
    # Kill the background dd process
    kill $dd_pid 2>/dev/null
    wait $dd_pid 2>/dev/null
    echo -e "\e[32mStopped blinking /dev/$block_dev.\e[0m\n"
}

# Function to blink multiple devices simultaneously
blink_all_devices() {
    pci_addrs=("$@")
    declare -a dd_pids=()
    declare -a block_devs=()
    
    echo -e "\n\e[1;33m>>> Blinking all selected devices simultaneously <<<\e[0m"
    echo -e "\e[1;31mLook at your server NOW to identify the flashing slots on the cards.\e[0m"
    echo ""
    
    # Start all dd processes
    for pci_addr in "${pci_addrs[@]}"; do
        nvme_dev=${NVME_MAP[$pci_addr]}
        block_dev="${nvme_dev}n1"
        
        if [ -z "$nvme_dev" ]; then
            echo -e "\e[31mSkipping $pci_addr: No NVMe device found\e[0m"
            continue
        fi
        
        if [ ! -b "/dev/$block_dev" ]; then
            echo -e "\e[31mSkipping $pci_addr: Block device /dev/$block_dev not found\e[0m"
            continue
        fi
        
        echo -e "  \e[36mStarting blink on /dev/$block_dev (PCI: $pci_addr)\e[0m"
        dd if=/dev/$block_dev of=/dev/null bs=1M status=none &
        dd_pids+=($!)
        block_devs+=("$block_dev")
    done
    
    if [ ${#dd_pids[@]} -eq 0 ]; then
        echo -e "\e[31mNo devices available to blink.\e[0m\n"
        return 1
    fi
    
    echo ""
    echo -e "Press \e[1;32m[ENTER]\e[0m to stop blinking all devices..."
    
    # Wait for user to press Enter
    read -r
    
    # Kill all background dd processes
    echo -e "\e[33mStopping all blink processes...\e[0m"
    for i in "${!dd_pids[@]}"; do
        kill ${dd_pids[$i]} 2>/dev/null
        wait ${dd_pids[$i]} 2>/dev/null
        echo -e "  \e[32mStopped blinking /dev/${block_devs[$i]}\e[0m"
    done
    echo ""
}

# Function to show lspci -tv for a device
show_lspci_tree() {
    local pci_addr=$1
    # Convert 0000:20:01.3 format to search patterns for lspci -tv output
    # lspci -tv shows: [20] for bus, and 01.3 for device.function
    local domain=$(echo "$pci_addr" | cut -d: -f1)
    local bus=$(echo "$pci_addr" | cut -d: -f2)
    local dev_func=$(echo "$pci_addr" | cut -d: -f3)
    
    # Remove leading zeros from bus for bracket notation [xx]
    local bus_no_zero=$(echo "$bus" | sed 's/^0*//')
    # Keep original format for xx:xx.x notation
    local bus_with_zero="$bus"
    
    echo -e "\n\e[36m>>> lspci -tv output for PCI device $pci_addr:\e[0m"
    echo -e "\e[36m--------------------------------------------------\e[0m"
    
    # Try multiple patterns: [bus] or bus:dev.func format
    local output=""
    output=$(lspci -tv | grep -E "(\[${bus_no_zero}\]|${bus_with_zero}:${dev_func})" 2>/dev/null)
    
    if [ -n "$output" ]; then
        # Show context around the match
        lspci -tv | grep -E "(\[${bus_no_zero}\]|${bus_with_zero}:${dev_func})" -B3 -A3
    else
        echo -e "\e[33mDevice $pci_addr not found in lspci -tv tree. Showing full output:\e[0m"
        lspci -tv
    fi
    
    echo -e "\e[36m--------------------------------------------------\e[0m\n"
}

# Function to show lspci -tv for all devices
show_lspci_all() {
    echo -e "\n\e[36m>>> Full lspci -tv output:\e[0m"
    echo -e "\e[36m--------------------------------------------------\e[0m"
    lspci -tv
    echo -e "\e[36m--------------------------------------------------\e[0m\n"
}

# Main interactive menu loop
while true; do
    echo -e "\n\e[36m==================================================\e[0m"
    echo -e "\e[1;36m       Available Actions for AER Error Devices\e[0m"
    echo -e "\e[36m==================================================\e[0m"
    echo ""
    echo -e "\e[33mDevices with AER errors:\e[0m"
    
    # Display numbered list of devices
    i=1
    for pci_addr in "${PCI_LIST[@]}"; do
        nvme_dev=${NVME_MAP[$pci_addr]}
        if [ -n "$nvme_dev" ]; then
            echo "  [$i] $pci_addr -> /dev/$nvme_dev"
        else
            echo "  [$i] $pci_addr -> (No NVMe device found)"
        fi
        ((i++))
    done
    
    echo ""
    echo -e "\e[36mOptions:\e[0m"
    echo "  [b] Blink device(s) - run IO test to flash activity LED"
    echo "  [l] Show full lspci -tv tree"
    echo "  [v] View error history log"
    echo "  [q] Quit/Exit"
    echo ""
    
    read -p "Select action (b/l/v/q): " main_choice
    
    case "$main_choice" in
        b|B)
            # Blink devices
            echo ""
            read -p "Enter device number(s) to blink (e.g., 1,2,3 or 'all'): " blink_selection
            echo ""
            read -p "Blink sequentially (one by one) or all at once? [s/a]: " blink_mode
            
            if [ "$blink_selection" == "all" ]; then
                if [ "$blink_mode" == "a" ] || [ "$blink_mode" == "all" ]; then
                    blink_all_devices "${PCI_LIST[@]}"
                else
                    for pci_addr in "${PCI_LIST[@]}"; do
                        blink_device "$pci_addr"
                    done
                fi
            else
                IFS=',' read -ra blink_nums <<< "$blink_selection"
                declare -a selected_pci=()
                for num in "${blink_nums[@]}"; do
                    idx=$((num - 1))
                    if [ $idx -ge 0 ] && [ $idx -lt ${#PCI_LIST[@]} ]; then
                        selected_pci+=("${PCI_LIST[$idx]}")
                    else
                        echo -e "\e[31mInvalid device number: $num\e[0m"
                    fi
                done
                
                if [ ${#selected_pci[@]} -gt 0 ]; then
                    if [ "$blink_mode" == "a" ] || [ "$blink_mode" == "all" ]; then
                        blink_all_devices "${selected_pci[@]}"
                    else
                        for pci_addr in "${selected_pci[@]}"; do
                            blink_device "$pci_addr"
                        done
                    fi
                fi
            fi
            ;;
            
        l|L)
            # Show full lspci -tv
            show_lspci_all
            ;;
            
        v|V)
            # View error history
            view_error_history
            ;;
            
        q|Q)
            echo -e "\e[32mExiting. Diagnostic script complete.\e[0m"
            exit 0
            ;;
            
        *)
            echo -e "\e[31mInvalid option. Please select b, l, v, or q.\e[0m"
            ;;
    esac
done
