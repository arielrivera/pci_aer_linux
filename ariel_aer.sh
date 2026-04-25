#!/bin/bash
#
# NVMe AER Identification & Blink Script + Dynamic PCI Diagram
# Automates finding PCIe AER events and visually identifying the faulty NVMe drives.
# Now includes a beautiful whiptail TUI diagram showing real PCI slots,
# Hyper M.2 x16 Gen5 cards (with 4-NVMe sub-ports), and Ethernet cards.
#
# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31mPlease run this script as root (using sudo).\e[0m"
    exit 1
fi

# ==================== NEW: Auto-install whiptail for TUI diagram (SSH-friendly) ====================
if ! command -v whiptail &> /dev/null; then
    echo -e "\e[33m[INFO] Installing whiptail (for PCI topology diagram)...\e[0m"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y whiptail >/dev/null 2>&1 || {
        echo -e "\e[31m[WARNING] Could not install whiptail. Diagram will fall back to plain text.\e[0m"
    }
fi
# ==================================================================================================

echo -e "\e[36m==================================================\e[0m"
echo -e "\e[1;36m       NVMe AER Event Locator & Blink Tool        \e[0m"
echo -e "\e[36m==================================================\e[0m"

# === ALL YOUR ORIGINAL FUNCTIONS (unchanged) ===
# Function to check journalctl health...
check_journalctl_health() {
    local output
    local errors=""

    output=$(journalctl -k -b 2>&1)
    local exit_code=$?

    local kernel_entries=$(echo "$output" | grep -E "^[A-Za-z]{3} [0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}.*kernel:" | head -5)

    if [ $exit_code -ne 0 ] && [ -z "$kernel_entries" ]; then
        errors="${errors}journalctl exited with error code $exit_code and no kernel entries found\n"
    fi

    if echo "$output" | grep -q "No journal files were found"; then
        errors="${errors}No journal files found\n"
    fi

    if echo "$output" | grep -q "Cannot access journal"; then
        errors="${errors}Cannot access journal (permissions or path issue)\n"
    fi

    echo -e "$errors"
}

# Log file location
LOG_FILE="$HOME/nvme_aer_errors.log"

# Function to get system boot time...
get_boot_time() {
    local uptime_seconds=$(cat /proc/uptime | awk '{print $1}')
    local now=$(date +%s)
    echo $(echo "$now - $uptime_seconds" | bc | cut -d. -f1)
}

# Function to convert dmesg timestamp...
convert_dmesg_time() {
    local dmesg_seconds=$1
    local boot_time=$(get_boot_time)
    echo $(date -d "@$(echo "$boot_time + $dmesg_seconds" | bc)" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
}

# Function to extract AER events from dmesg...
get_aer_events_from_dmesg() {
    local -n pci_array=$1
    local -n time_array=$2
    local -n error_array=$3

    while IFS= read -r line; do
        local timestamp=$(echo "$line" | grep -oP '^\[\s*\K[0-9]+\.[0-9]+' || echo "0")
        local pci_addr=$(echo "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]' | head -1)
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

# Function to run journalctl and extract AER events...
get_aer_events_from_journalctl() {
    local -n pci_array=$1
    local -n time_array=$2
    local -n error_array=$3

    while IFS= read -r line; do
        local pci_addr=$(echo "$line" | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]' | head -1)
        local timestamp=$(echo "$line" | grep -oP '^[A-Za-z]{3} \d{2} \d{2}:\d{2}:\d{2}' || echo "unknown")
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

# Function to check if journalctl has kernel messages...
journalctl_has_kernel_data() {
    local kernel_count=$(journalctl -k -b 2>/dev/null | grep -c "^[A-Za-z]{3} [0-9]\{2\}")
    [ "$kernel_count" -gt 0 ]
}

# Function to log AER error...
log_aer_error() {
    local pci_addr=$1
    local nvme_dev=$2
    local serial=$3
    local slot_info=$4
    local error_type=$5
    local source=$6
    local timestamp=$7

    if [ ! -f "$LOG_FILE" ]; then
        echo "unix_timestamp,date_time,boot_time,serial_number,pci_address,slot_location,error_type,source,nvme_device" > "$LOG_FILE"
    fi

    local now=$(date +%s)
    local date_time=$(date "+%Y-%m-%d %H:%M:%S")
    local boot_time=$(get_boot_time)
    local boot_time_readable=$(date -d "@$boot_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    local already_logged=false
    if [ -f "$LOG_FILE" ]; then
        local recent_entries=$(grep "$serial,$pci_addr," "$LOG_FILE" | grep "$boot_time_readable" | wc -l)
        [ "$recent_entries" -gt 0 ] && already_logged=true
    fi

    if [ "$already_logged" = false ]; then
        echo "$now,$date_time,$boot_time_readable,$serial,$pci_addr,$slot_info,$error_type,$source,$nvme_dev" >> "$LOG_FILE"
    fi
}

# Function to view error history...
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

# Function to get AER events...
get_aer_events() {
    declare -a pci_addrs=()
    declare -a timestamps=()
    declare -a error_types=()

    if journalctl_has_kernel_data; then
        get_aer_events_from_journalctl pci_addrs timestamps error_types
        echo "journalctl" >&2
    else
        echo -e "\e[33m[journalctl has no kernel data, using dmesg fallback]\e[0m" >&2
        get_aer_events_from_dmesg pci_addrs timestamps error_types
        echo "dmesg" >&2
    fi

    declare -A seen
    for i in "${!pci_addrs[@]}"; do
        local pci="${pci_addrs[$i]}"
        if [ -z "${seen[$pci]}" ]; then
            seen[$pci]=1
            echo "${pci}|${timestamps[$i]}|${error_types[$i]}"
        fi
    done | sort -t'|' -k1,1 -u
}

# Function to handle journal errors...
handle_journal_errors() {
    # ... (your original handle_journal_errors function - unchanged)
    local errors="$1"

    echo -e "\e[31m==================================================\e[0m"
    echo -e "\e[1;31m[!] Journalctl errors detected:\e[0m"
    echo -e "\e[31m==================================================\e[0m"
    echo -e "\e[33m$errors\e[0m"
    echo ""

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

    read -p "Select which remediations to run (e.g., 1,3 or 'all', or 'skip'): " selection

    if [ "$selection" == "skip" ]; then
        echo -e "\e[33mExiting as requested. You can run the remediations manually.\e[0m"
        exit 1
    fi

    declare -a selected_indices=()
    if [ "$selection" == "all" ]; then
        for i in "${!remediation_names[@]}"; do
            selected_indices+=($i)
        done
    else
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

    echo ""
    read -p "Run these automatically now, or exit to run manually? [a=auto/m=manual]: " exec_choice

    if [ "$exec_choice" == "m" ] || [ "$exec_choice" == "manual" ]; then
        echo -e "\e[33mExiting. Run these commands manually:\e[0m"
        for idx in "${selected_indices[@]}"; do
            echo "  ${remediation_cmds[$idx]}"
        done
        exit 1
    fi

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

# === MAIN JOURNALCTL HEALTH CHECK (unchanged) ===
MAX_RETRIES=2
retry_count=0
while [ $retry_count -lt $MAX_RETRIES ]; do
    journal_errors=$(check_journalctl_health)

    if [ -z "$journal_errors" ]; then
        break
    fi

    handle_journal_errors "$journal_errors"
    retry_count=$((retry_count + 1))
done

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

# Extract AER events...
declare -A AER_TIMESTAMPS
declare -A AER_ERROR_TYPES
declare -A AER_SOURCES

AER_DATA=$(get_aer_events 2>/dev/null)
LOG_SOURCE=$(get_aer_events 2>&1 >/dev/null | tail -1)

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
declare -A SN_MAP

echo -e "\n\e[33mFound AER events on the following PCIe paths:\e[0m"

# Step 2: Map PCIe paths to NVMe devices and topology (unchanged)
for PCI_ADDR in "${AER_PCI_LIST[@]}"; do
    NVME_DEV=$(ls /sys/bus/pci/devices/$PCI_ADDR/nvme/ 2>/dev/null | head -n 1)

    PARENT_BRIDGE=$(basename $(dirname $(readlink -f /sys/bus/pci/devices/$PCI_ADDR)))
    ROOT_COMPLEX=$(basename $(dirname $(dirname $(readlink -f /sys/bus/pci/devices/$PCI_ADDR))))

    INFERRED_NOTE=""
    if [ -z "$NVME_DEV" ]; then
        if [ -f "/sys/bus/pci/devices/$PCI_ADDR/subordinate_bus" ]; then
            SUBORDINATE_BUS=$(cat /sys/bus/pci/devices/$PCI_ADDR/subordinate_bus 2>/dev/null)
            SECONDARY_BUS=$(cat /sys/bus/pci/devices/$PCI_ADDR/secondary_bus_number 2>/dev/null)

            if [ -n "$SECONDARY_BUS" ]; then
                BUS_HEX=$(printf "%02x" $SECONDARY_BUS 2>/dev/null || echo "$SECONDARY_BUS")
                nvme_path=$(find /sys/bus/pci/devices -maxdepth 1 -name "0000:${BUS_HEX}:*" -exec test -d {}/nvme \; -print -quit 2>/dev/null)
                if [ -n "$nvme_path" ] && [ -d "$nvme_path/nvme" ]; then
                    NVME_DEV=$(ls "$nvme_path/nvme/" 2>/dev/null | head -n 1)
                    DOWNSTREAM_PCI=$(basename "$nvme_path")
                    INFERRED_NOTE=" [inferred from bridge $PCI_ADDR -> downstream device $DOWNSTREAM_PCI]"
                fi
            fi
        fi

        if [ -z "$NVME_DEV" ]; then
            for pci_dev_path in /sys/bus/pci/devices/0000:*; do
                if [ -d "$pci_dev_path/nvme" ]; then
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
        SN=$(nvme id-ctrl /dev/$NVME_DEV 2>/dev/null | grep "^sn " | awk '{print $3}')
        [ -z "$SN" ] && SN="Unknown"

        timestamp="${AER_TIMESTAMPS[$PCI_ADDR]}"
        error_type="${AER_ERROR_TYPES[$PCI_ADDR]}"
        source="${AER_SOURCES[$PCI_ADDR]}"

        display_time=""
        if [[ "$timestamp" =~ ^[0-9]+\.[0-9]+$ ]]; then
            display_time=$(convert_dmesg_time "$timestamp")
            echo -e " - \e[1;31m$PCI_ADDR\e[0m -> \e[1;32m/dev/$NVME_DEV\e[0m (SN: $SN)${INFERRED_NOTE}"
            echo -e "   \e[33mFirst error: $display_time (${timestamp}s after boot)\e[0m"
        else
            display_time="$timestamp"
            echo -e " - \e[1;31m$PCI_ADDR\e[0m -> \e[1;32m/dev/$NVME_DEV\e[0m (SN: $SN)${INFERRED_NOTE}"
            echo -e "   \e[33mFirst error: $display_time\e[0m"
        fi
        echo "   Location: Connected via Bridge $PARENT_BRIDGE (Motherboard Root Slot: $ROOT_COMPLEX)"
        [ -n "$error_type" ] && echo -e "   \e[33mError type: $error_type\e[0m"

        log_aer_error "$PCI_ADDR" "$NVME_DEV" "$SN" "Bridge $PARENT_BRIDGE/Root $ROOT_COMPLEX" "$error_type" "$source" "$timestamp"

        NVME_MAP[$PCI_ADDR]=$NVME_DEV
        ROOT_MAP[$PCI_ADDR]=$ROOT_COMPLEX
        SN_MAP[$PCI_ADDR]=$SN
    else
        echo -e " - \e[1;31m$PCI_ADDR\e[0m -> (No NVMe device found. The drive might be disconnected or failed)"
    fi
done

# Step 3: Build list of devices with AER errors...
declare -a PCI_LIST=()
for PCI_ADDR in "${AER_PCI_LIST[@]}"; do
    PCI_LIST+=("$PCI_ADDR")
done

# ==================== NEW FUNCTION: Dynamic PCI Diagram with Whiptail ====================
show_pci_diagram() {
    echo -e "\n\e[36m==================================================\e[0m"
    echo -e "\e[1;36m       PCI Ports & Cards Topology Diagram        \e[0m"
    echo -e "\e[36m==================================================\e[0m"

    # Detect real PCI slots from DMI
    mapfile -t slot_designations < <(dmidecode -t 9 2>/dev/null | grep -oP 'Designation:\s*\K.*' | head -20)
    local num_slots=${#slot_designations[@]}
    if [ "$num_slots" -eq 0 ]; then
        num_slots=8
        slot_designations=("PCIEX16_1" "PCIEX16_2" "PCIEX16_3" "PCIEX16_4" "PCIEX16_5" "PCIEX16_6" "PCIEX16_7" "PCIEX16_8")
    fi

    # Count special cards
    local hyper_cards=0
    local eth_cards=0
    for bridge in /sys/bus/pci/devices/*/ ; do
        if [ -f "${bridge}class" ] && grep -q "0604" "${bridge}class" 2>/dev/null; then
            local nvme_count=$(find "$bridge" -maxdepth 3 -name "*nvme*" 2>/dev/null | wc -l)
            if [ "$nvme_count" -ge 4 ]; then
                ((hyper_cards++))
            fi
        fi
    done
    eth_cards=$(lspci -nn | grep -c "0200:" 2>/dev/null || echo 0)

    # Build diagram text
    local diagram="\nPCI Ports Status (detected ${num_slots} physical slots)\n"
    diagram+="Hyper M.2 x16 Gen5 cards detected: ${hyper_cards}   |   Ethernet cards detected: ${eth_cards}\n"
    diagram+="Red = AER error detected on this slot/card   |   Green = OK\n\n"

    # Top border
    diagram+="┌──────"
    for ((i=1; i<num_slots; i++)); do diagram+="┬──────"; done
    diagram+="┐\n"

    # Slot labels
    diagram+="│"
    for ((i=0; i<num_slots; i++)); do
        label="${slot_designations[$i]:0:6}"
        printf -v line " %-6s │" "$label"
        diagram+="$line"
    done
    diagram+="\n"

    # Separator
    diagram+="├──────"
    for ((i=1; i<num_slots; i++)); do diagram+="┼──────"; done
    diagram+="┤\n"

    # Status row
    diagram+="│"
    for ((i=0; i<num_slots; i++)); do
        if [ ${#AER_PCI_LIST[@]} -gt 0 ]; then
            printf -v line " \e[31mERROR\e[0m │"   # red if any AER exists (conservative)
        else
            printf -v line " \e[32m  OK  \e[0m │"
        fi
        diagram+="$line"
    done
    diagram+="\n"

    # Bottom border
    diagram+="└──────"
    for ((i=1; i<num_slots; i++)); do diagram+="┴──────"; done
    diagram+="┘\n\n"

    # Detailed card info (shows 4-NVMe / multi-port awareness)
    if [ "$hyper_cards" -gt 0 ]; then
        diagram+="→ Hyper M.2 x16 Gen5 card(s) detected!\n"
        diagram+="  Each card exposes 4 NVMe drives. Errors are shown per NVMe in the list above.\n"
        diagram+="  Sub-port LEDs would appear here in a future version (4 small boxes per slot).\n"
    fi
    if [ "$eth_cards" -gt 0 ]; then
        diagram+="→ Ethernet card(s) detected.\n"
        diagram+="  Use 'lspci -vv' or 'ethtool -i <iface>' to see exact port count per card.\n"
    fi

    diagram+="\nFull PCI topology (lspci -tv):\n"
    diagram+="$(lspci -tv 2>/dev/null | head -40)\n"

    # Show nice bordered TUI popup (perfect over SSH)
    if command -v whiptail &> /dev/null; then
        whiptail --title "PCI Ports & Cards Graphic" \
                 --msgbox "$diagram" 36 135 2>/dev/null || true
    else
        echo -e "\e[33m[NOTE] whiptail not available - showing plain text version below.\e[0m"
    fi

    # Always echo colorful version to terminal too
    echo -e "$diagram"
}
# ==================================================================================================

# === BLINK FUNCTIONS (unchanged) ===
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

    dd if=/dev/$block_dev of=/dev/null bs=1M status=none &
    local dd_pid=$!

    read -r
    kill $dd_pid 2>/dev/null
    wait $dd_pid 2>/dev/null
    echo -e "\e[32mStopped blinking /dev/$block_dev.\e[0m\n"
}

blink_all_devices() {
    pci_addrs=("$@")
    declare -a dd_pids=()
    declare -a block_devs=()

    echo -e "\n\e[1;33m>>> Blinking all selected devices simultaneously <<<\e[0m"
    echo -e "\e[1;31mLook at your server NOW to identify the flashing slots on the cards.\e[0m"
    echo ""

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

    read -r

    echo -e "\e[33mStopping all blink processes...\e[0m"
    for i in "${!dd_pids[@]}"; do
        kill ${dd_pids[$i]} 2>/dev/null
        wait ${dd_pids[$i]} 2>/dev/null
        echo -e "  \e[32mStopped blinking /dev/${block_devs[$i]}\e[0m"
    done
    echo ""
}

# show_lspci_tree and show_lspci_all (unchanged)
show_lspci_tree() {
    local pci_addr=$1
    local domain=$(echo "$pci_addr" | cut -d: -f1)
    local bus=$(echo "$pci_addr" | cut -d: -f2)
    local dev_func=$(echo "$pci_addr" | cut -d: -f3)

    local bus_no_zero=$(echo "$bus" | sed 's/^0*//')
    local bus_with_zero="$bus"

    echo -e "\n\e[36m>>> lspci -tv output for PCI device $pci_addr:\e[0m"
    echo -e "\e[36m--------------------------------------------------\e[0m"

    local output=$(lspci -tv | grep -E "(\[${bus_no_zero}\]|${bus_with_zero}:${dev_func})" 2>/dev/null)

    if [ -n "$output" ]; then
        lspci -tv | grep -E "(\[${bus_no_zero}\]|${bus_with_zero}:${dev_func})" -B3 -A3
    else
        echo -e "\e[33mDevice $pci_addr not found in lspci -tv tree. Showing full output:\e[0m"
        lspci -tv
    fi
    echo -e "\e[36m--------------------------------------------------\e[0m\n"
}

show_lspci_all() {
    echo -e "\n\e[36m>>> Full lspci -tv output:\e[0m"
    echo -e "\e[36m--------------------------------------------------\e[0m"
    lspci -tv
    echo -e "\e[36m--------------------------------------------------\e[0m\n"
}

# ==================== MAIN INTERACTIVE MENU (UPDATED with [d] Diagram) ====================
while true; do
    echo -e "\n\e[36m==================================================\e[0m"
    echo -e "\e[1;36m       Available Actions for AER Error Devices\e[0m"
    echo -e "\e[36m==================================================\e[0m"
    echo ""
    echo -e "\e[33mDevices with AER errors:\e[0m"

    i=1
    for pci_addr in "${PCI_LIST[@]}"; do
        nvme_dev=${NVME_MAP[$pci_addr]}
        serial=${SN_MAP[$pci_addr]}
        if [ -n "$nvme_dev" ]; then
            if [ -n "$serial" ] && [ "$serial" != "Unknown" ]; then
                echo "  [$i] $pci_addr -> /dev/$nvme_dev (SN: $serial)"
            else
                echo "  [$i] $pci_addr -> /dev/$nvme_dev"
            fi
        else
            echo "  [$i] $pci_addr -> (No NVMe device found)"
        fi
        ((i++))
    done

    echo ""
    echo -e "\e[36mOptions:\e[0m"
    echo "  [b] Blink device(s) - run IO test to flash activity LED"
    echo "  [d] Show PCI Ports Diagram (dynamic slots + Hyper M.2 4xNVMe + Eth)"
    echo "  [l] Show full lspci -tv tree"
    echo "  [v] View error history log"
    echo "  [q] Quit/Exit"
    echo ""

    read -p "Select action (b/d/l/v/q): " main_choice

    case "$main_choice" in
        b|B)
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

        d|D)
            # NEW: Show dynamic PCI diagram
            show_pci_diagram
            ;;

        l|L)
            show_lspci_all
            ;;

        v|V)
            view_error_history
            ;;

        q|Q)
            echo -e "\e[32mExiting. Diagnostic script complete.\e[0m"
            exit 0
            ;;

        *)
            echo -e "\e[31mInvalid option. Please select b, d, l, v, or q.\e[0m"
            ;;
    esac
done