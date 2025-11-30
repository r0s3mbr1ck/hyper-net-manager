#############################################
# MODULE: Host Network – Detection
#############################################

# ------------------------------------------------------------------------------
# FUNCTION: detect_wired_auto
#
# Purpose:
#   Automatically identify the wired NIC managed by NetworkManager.
#   If multiple interfaces are detected or confirmation fails, ask user manually.
#
# Inputs (globals):
#   WIRED_IF   - may be empty before detection
#
# Outputs (globals):
#   WIRED_IF   - selected wired NIC (ex: enp3s0)
#
# External Commands:
#   nmcli, awk, read
#
# Notes:
#   This must be the very first step of host network initialization.
# ------------------------------------------------------------------------------

detect_wired_auto() {
    echo -e "${INFO} Detecting Ethernet interface managed by NetworkManager...${RESET}"

    local cand
    cand=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="ethernet"{print $1}' | head -n1)

    if [[ -z "$cand" ]]; then
        echo -e "${WARN} No ethernet interface detected automatically.${RESET}"
        nmcli device status
        read -r -p "Please enter the ethernet interface name manually (e.g., enp3s0f1): " WIRED_IF
    else
        echo -e "${YELLOW} Detected interface: ${WHITE}${cand}${RESET}"
        read -r -p "Confirm this interface? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            WIRED_IF="$cand"
        else
            nmcli device status
            read -r -p "Please enter the ethernet interface name manually: " WIRED_IF
        fi
    fi

    echo -e "${OK} Ethernet interface set to: ${WHITE}${WIRED_IF}${RESET}"
    log_msg INFO "Ethernet interface set: ${WIRED_IF}"
}

# ------------------------------------------------------------------------------
# FUNCTION: detect_network_auto
#
# Purpose:
#   Detect IPv4 configuration from WIRED_IF (IP, prefix, gateway, network).
#   If auto-detection fails, prompt user for manual values.
#
# Inputs (globals):
#   WIRED_IF
#
# Outputs (globals):
#   HOST_IP
#   HOST_PREFIX
#   GATEWAY
#   LAN_NET (calculated CIDR)
#
# External Commands:
#   ip, nmcli, awk, sleep
#
# Notes:
#   Calculates LAN_NET for /24, /16 and /8; other prefixes fallback gracefully.
# ------------------------------------------------------------------------------

detect_network_auto() {
    echo -e "${INFO} Detecting host network on interface ${WIRED_IF}...${RESET}"
    log_msg INFO "Detecting network on interface ${WIRED_IF}."

    nmcli device connect "$WIRED_IF" &>/dev/null || true
    sleep 1

    HOST_IP=$(ip -4 addr show "$WIRED_IF" | awk '/inet /{print $2}' | cut -d/ -f1)
    HOST_PREFIX=$(ip -4 addr show "$WIRED_IF" | awk '/inet /{print $2}' | cut -d/ -f2)
    GATEWAY=$(ip route | awk '/default/ && $5=="'"$WIRED_IF"'" {print $3}' | head -n1)

    if [[ -z "$HOST_IP" ]]; then
        echo -e "${WARN} No IPv4 IP on ${WIRED_IF}. Attempting to reapply config...${RESET}"
        nmcli device reapply "$WIRED_IF" &>/dev/null || true
        sleep 2
        HOST_IP=$(ip -4 addr show "$WIRED_IF" | awk '/inet /{print $2}' | cut -d/ -f1)
        HOST_PREFIX=$(ip -4 addr show "$WIRED_IF" | awk '/inet /{print $2}' | cut -d/ -f2)
    fi

    if [[ -z "$HOST_IP" ]]; then
        echo -e "${FAIL} Could not detect IP on ${WIRED_IF}.${RESET}"
        read -r -p "Enter IP manually (e.g., 192.168.15.141): " HOST_IP
        read -r -p "Prefix (e.g., 24): " HOST_PREFIX
        read -r -p "Gateway (e.g., 192.168.15.1): " GATEWAY
    fi

    if [[ -z "$GATEWAY" ]]; then
        GATEWAY=$(ip route | awk '/default/ {print $3}' | head -n1)
    fi

    IFS=. read -r o1 o2 o3 o4 <<< "$HOST_IP"
    case "$HOST_PREFIX" in
        24) LAN_NET="${o1}.${o2}.${o3}.0/24" ;;
        16) LAN_NET="${o1}.${o2}.0.0/16" ;;
        8 ) LAN_NET="${o1}.0.0.0/8" ;;
        *)  LAN_NET="(prefix ${HOST_PREFIX}, not calculated)" ;;
    esac

    echo -e "${GREEN} Network detected:${RESET}"
    echo -e "  Interface: ${WHITE}${WIRED_IF}${RESET}"
    echo -e "  Current IP: ${WHITE}${HOST_IP}/${HOST_PREFIX}${RESET}"
    echo -e "  Gateway:    ${WHITE}${GATEWAY}${RESET}"
    echo -e "  Network:    ${WHITE}${LAN_NET}${RESET}"
    log_msg INFO "Network detected: IF=${WIRED_IF} IP=${HOST_IP}/${HOST_PREFIX} GW=${GATEWAY} NET=${LAN_NET}"
}

# ------------------------------------------------------------------------------
# FUNCTION: configure_bridge_name
#
# Purpose:
#   Configure or rename the bridge interface (BRIDGE_IF) and NM profile (BRIDGE_NAME).
#   Also generates BRIDGE_SLAVE_NAME to enslave the wired NIC.
#
# Outputs (globals):
#   BRIDGE_IF
#   BRIDGE_NAME
#   BRIDGE_SLAVE_NAME
#
# Notes:
#   Called before enabling bridge mode.
# ------------------------------------------------------------------------------

configure_bridge_name() {
    echo -e "${INFO} Configuring bridge name...${RESET}"
    echo -e "${YELLOW} Current bridge interface name:${RESET} ${WHITE}${BRIDGE_IF}${RESET}"
    read -r -p "Do you want to change it? (y/N to keep): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        read -r -p "New bridge interface name (e.g., lab-br0): " tmp
        [[ -n "$tmp" ]] && BRIDGE_IF="$tmp"
    fi

    echo -e "${YELLOW} Current NM connection name for the bridge (appears in KDE):${RESET} ${WHITE}${BRIDGE_NAME}${RESET}"
    read -r -p "Do you want to change the connection name? (y/N to keep): " ans2
    if [[ "$ans2" =~ ^[Yy]$ ]]; then
        read -r -p "New NM connection name (e.g., 'Bridge Lab'): " tmp2
        [[ -n "$tmp2" ]] && BRIDGE_NAME="$tmp2"
    fi

    BRIDGE_SLAVE_NAME="${BRIDGE_NAME}-slave"

    echo -e "${OK} Bridge configured as interface ${WHITE}${BRIDGE_IF}${RESET}, NM connection ${WHITE}${BRIDGE_NAME}${RESET}"
    log_msg INFO "Bridge configured: IF=${BRIDGE_IF}, CONN=${BRIDGE_NAME}, SLAVE=${BRIDGE_SLAVE_NAME}"
}

# ------------------------------------------------------------------------------
# FUNCTION: detect_original_connection
#
# Purpose:
#   Identify the original NetworkManager connection associated with WIRED_IF
#   before switching to bridge mode.
#
# Outputs (globals):
#   ETH_CONN_ORIG
# ------------------------------------------------------------------------------

detect_original_connection() {
    echo -e "${INFO} Detecting original connection for interface ${WIRED_IF}...${RESET}"
    ETH_CONN_ORIG=$(nmcli -t -f NAME,DEVICE connection show --active \
        | awk -F: -v dev="$WIRED_IF" '$2==dev && $1 !~ /^hnm-|^Bridge / {print $1; exit}')

    if [[ -z "$ETH_CONN_ORIG" ]]; then
        echo -e "${WARN} No original connection found for ${WIRED_IF}.${RESET}"
        log_msg WARN "No original connection found for ${WIRED_IF}."
    else
        echo -e "${OK} Original connection: ${WHITE}${ETH_CONN_ORIG}${RESET}"
        log_msg INFO "Original connection detected for ${WIRED_IF}: ${ETH_CONN_ORIG}"
    fi
}

# ------------------------------------------------------------------------------
# FUNCTION: initial_bridge_setup_if_needed
#
# Purpose:
#   Perform all initial detection steps required before creating a bridge:
#     - determine WIRED_IF
#     - detect network parameters
#     - configure names
#     - detect original NM connection
#     - save state
# ------------------------------------------------------------------------------

initial_bridge_setup_if_needed() {
    load_state
    [[ -z "$WIRED_IF" ]]  && detect_wired_auto
    [[ -z "$HOST_IP" ]]   && detect_network_auto
    configure_bridge_name
    [[ -z "$ETH_CONN_ORIG" ]] && detect_original_connection
    save_state
}

