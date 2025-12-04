#############################################
# MODULE: Host Network – Bridge & VLAN
#############################################

# ------------------------------------------------------------------------------
# FUNCTION: enable_bridge_mode
#
# Purpose:
#   Replace Ethernet mode with a Linux/NM-managed bridge.
#   WIRED_IF becomes a slave inside BRIDGE_IF.
#   HOST_IP is transferred from WIRED_IF to the bridge.
# ------------------------------------------------------------------------------

enable_bridge_mode() {
    initial_bridge_setup_if_needed

    IFS=. read -r o1 o2 o3 o4 <<< "$HOST_IP"
    local default_br_ip="${o1}.${o2}.${o3}.123"

    echo -e "${INFO} Configuring IP for bridge ${BRIDGE_IF}...${RESET}"
    echo -e "Host's current IP: ${WHITE}${HOST_IP}/${HOST_PREFIX}${RESET}"
    echo -e "Suggestion for the bridge: ${WHITE}${default_br_ip}${RESET}"
    read -r -p "Enter the IP for the bridge [${default_br_ip}]: " tmp_ip
    BRIDGE_IP="${tmp_ip:-$default_br_ip}"

    save_state
    log_msg INFO "Activating BRIDGE mode: BRIDGE_IF=${BRIDGE_IF}, BRIDGE_IP=${BRIDGE_IP}"

    echo -e "${CYAN}Activating BRIDGE mode via NetworkManager...${RESET}"

    nmcli connection down "$BRIDGE_SLAVE_NAME" &>/dev/null || true
    nmcli connection down "$BRIDGE_NAME" &>/dev/null || true
    nmcli connection delete "$BRIDGE_SLAVE_NAME" &>/dev/null || true
    nmcli connection delete "$BRIDGE_NAME" &>/dev/null || true

    if [[ -n "$ETH_CONN_ORIG" ]]; then
        nmcli connection down "$ETH_CONN_ORIG" &>/dev/null || true
    fi

    nmcli connection add type bridge ifname "$BRIDGE_IF" con-name "$BRIDGE_NAME" \
        ipv4.method manual \
        ipv4.addresses "${BRIDGE_IP}/${HOST_PREFIX}" \
        ipv4.gateway "$GATEWAY" \
        ipv4.dns "$GATEWAY 1.1.1.1" \
        ipv4.ignore-auto-dns no \
        ipv6.method ignore

    nmcli connection add type bridge-slave ifname "$WIRED_IF" con-name "$BRIDGE_SLAVE_NAME" master "$BRIDGE_NAME"

    nmcli connection up "$BRIDGE_NAME"

    echo -e "${OK} BRIDGE mode activated: host uses ${WHITE}${BRIDGE_IF} = ${BRIDGE_IP}${RESET}"
    log_msg INFO "BRIDGE mode activated successfully."
    
    echo
    read -r -p "Do you want to connect a VM to this bridge (${BRIDGE_IF}) now and optionally start it? (y/N): " ans_vm
    if [[ "$ans_vm" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${INFO} Opening wizard to connect VMs to bridge ${BRIDGE_IF}...${RESET}"
        # Reuse the function you already use in the VM menu
        attach_vms_to_br0
    else
        echo -e "${INFO} You can connect VMs to the bridge later via the 'Manage VM NETWORKS' menu.${RESET}"
    fi

}

# ------------------------------------------------------------------------------
# FUNCTION: enable_eth_mode
#
# Purpose:
#   Revert system back to standard Ethernet mode.
#   Removes bridge interface & NM profiles and restores original NM connection.
# ------------------------------------------------------------------------------

enable_eth_mode() {
    load_state
    echo ""
    echo -e "${CYAN}Reverting to ETHERNET mode...${RESET}"
    echo ""
    log_msg INFO "Reverting to ETHERNET mode."
    
    nmcli connection down "$BRIDGE_SLAVE_NAME" &>/dev/null || true
    nmcli connection down "$BRIDGE_NAME" &>/dev/null || true
    nmcli connection delete "$BRIDGE_SLAVE_NAME" &>/dev/null || true
    nmcli connection delete "$BRIDGE_NAME" &>/dev/null || true

    ip link delete "$BRIDGE_IF" type bridge 2>/dev/null || true
    log_msg INFO "Bridge ${BRIDGE_IF} removed from kernel."

    if [[ -n "$ETH_CONN_ORIG" ]]; then
        if nmcli connection up "$ETH_CONN_ORIG" &>/dev/null; then
            echo -e "${OK} Original connection ${WHITE}${ETH_CONN_ORIG}${RESET} restored.${RESET}"
            log_msg INFO "Original connection ${ETH_CONN_ORIG} restored."
        else
            echo -e "${WARN} Failed to bring up ${ETH_CONN_ORIG}. Check NetworkManager.${RESET}"
            log_msg WARN "Failed to bring up original connection ${ETH_CONN_ORIG}."
        fi
    else
        echo -e "${WARN} No known original connection. Use the NetworkManager applet to reconnect.${RESET}"
        log_msg WARN "No known original connection to restore."
    fi
}

#-----------------------------------------------------------
# Function: create_vlan_on_bridge
# Module: VM Networking
# Purpose:
#   Create a real VLAN sub-interface on top of br0 (or BRIDGE_IF).
# Inputs:
#   - VLAN ID
# Outputs:
#   New interface: br0.<VID> with link-up.
# Notes:
#   - Used for multi-segment lab topologies.
#   - Non-libvirt VLANs (host-level).
#-----------------------------------------------------------

create_vlan_on_bridge() {
    initial_bridge_setup_if_needed
    echo -ne "${CYAN}Enter VLAN ID to create on ${BRIDGE_IF} (e.g., 20): ${RESET}"
    read -r VID
    [[ -z "$VID" ]] && { echo -e "${WARN} No VLAN ID specified.${RESET}"; return; }

    local VLAN_IF="${BRIDGE_IF}.${VID}"
    if ip link add link "${BRIDGE_IF}" name "${VLAN_IF}" type vlan id "${VID}" 2>/dev/null; then
        ip link set "${VLAN_IF}" up
        echo -e "${OK} VLAN ${VID} created as ${VLAN_IF}.${RESET}"
        log_msg INFO "Real VLAN ${VID} created on ${BRIDGE_IF} as ${VLAN_IF}."
    else
        echo -e "${FAIL} Failed to create VLAN ${VID} (maybe it already exists?).${RESET}"
        log_msg ERROR "Failed to create real VLAN ${VID} on ${BRIDGE_IF}."
    fi
}

#-----------------------------------------------------------
# Function: delete_vlan_bridge
# Module: VM Networking
# Purpose:
#   Remove VLAN sub-interfaces previously created on the main bridge.
# Inputs:
#   - User-selected VLAN ID (fzf or manual)
# Outputs:
#   Deleted interface and cleaned bridge layer.
# Notes:
#   - Auto-detects existing VLANs like br0.10 br0.20 etc.
#-----------------------------------------------------------

delete_vlan_bridge() {
    initial_bridge_setup_if_needed
    echo ""
    draw_menu_title "REMOVE VLAN FROM BRIDGE ${BRIDGE_IF}"
    #echo -e "${CYAN}==== REMOVE VLAN FROM BRIDGE ${BRIDGE_IF} ====${RESET}"
    echo ""

    # Discover existing VLAN subinterfaces on BRIDGE_IF (e.g., br0.20, br0.30)
    local RAW_IFS VLAN_LIST=""
    RAW_IFS=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep "^${BRIDGE_IF}\." || true)

    # Build a human-readable VLAN list: "20 (br0.20)" etc.
    if [[ -n "$RAW_IFS" ]]; then
        local ifname vid
        while IFS= read -r ifname; do
            [[ -z "$ifname" ]] && continue
            # Extract VLAN ID (part after BRIDGE_IF.)
            vid="${ifname#${BRIDGE_IF}.}"
            [[ -z "$vid" ]] && continue
            VLAN_LIST+="${vid} (${ifname})"$'\n'
        done <<< "$RAW_IFS"
    fi

    local VID VLAN_IF

    # If we have VLANs, offer arrow-key selection
    if [[ -n "$VLAN_LIST" ]] && ensure_fzf; then
        # Use generic menu selector
        local SELECTION
        SELECTION=$(hnm_select "Select VLAN ID to remove from ${BRIDGE_IF}" "$VLAN_LIST") || {
            echo -e "${WARN} Operation canceled by user.${RESET}"
            return
        }
        # First field is the VID
        VID=$(echo "$SELECTION" | awk '{print $1}')
    fi

    # Fallback: manual input if fzf not used or no VLANs detected
    if [[ -z "$VID" ]]; then
        echo -ne "${CYAN}Enter VLAN ID to remove from ${BRIDGE_IF} (e.g., 20): ${RESET}"
        read -r VID
        VID=$(echo "$VID" | xargs)
    fi

    [[ -z "$VID" ]] && { echo -e "${WARN} No VLAN ID specified. Nothing to remove.${RESET}"; return; }

    VLAN_IF="${BRIDGE_IF}.${VID}"

    echo -e "${INFO} Removing VLAN ${VID} (${VLAN_IF}) from bridge ${BRIDGE_IF}...${RESET}"
    if ip link delete "${VLAN_IF}" 2>/dev/null; then
        echo -e "${OK} VLAN ${VID} removed (${VLAN_IF}).${RESET}"
        log_msg INFO "Real VLAN ${VID} removed (${VLAN_IF})."
    else
        echo -e "${FAIL} Failed to remove VLAN ${VID} (${VLAN_IF}). It may not exist.${RESET}"
        log_msg ERROR "Failed to remove real VLAN ${VID} (${VLAN_IF})."
    fi
}

