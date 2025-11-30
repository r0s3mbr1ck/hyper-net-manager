#############################################
# MODULE: VM Networking (libvirt networks)
# - internal, host-only, DMZ, br0, VLAN-aware attach
#############################################

#-----------------------------------------------------------
# Function: select_vm_network_for_vm
# Module:   VM Networking
# Purpose:
#   Allow the user to select which libvirt network a VM
#   should be attached to, using an interactive list of
#   existing networks.
#
# Inputs:
#   - VM name (either passed as parameter or selected inside).
#   - Available networks from 'virsh net-list --all'.
#
# Outputs:
#   - Echoes the chosen network name on stdout.
#
# Side effects:
#   - None directly; caller is responsible for changing
#     the VM XML and redefining the domain.
#
# Notes:
#   - Typically used in VM creation or when changing the
#     primary network of an existing VM.
#-----------------------------------------------------------

select_vm_network_for_vm() {
    # Default values in case something goes wrong
    NET_MODE="network"
    NET_NAME="default"

    echo
    echo -e "${CYAN} Select the network to connect the new VM:${RESET}"

    # Libvirt networks
    mapfile -t LV_NETS < <(virsh net-list --all 2>/dev/null | awk 'NR>2 && NF {print $1}')

    # Host bridges (Linux bridge – e.g.: br0, br_test, etc.)
    mapfile -t BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}')

    if [[ ${#LV_NETS[@]} -eq 0 && ${#BRIDGES[@]} -eq 0 ]]; then
        echo -e "${WARN} No libvirt networks or host bridges found; using libvirt 'default'.${RESET}"
        NET_MODE="network"
        NET_NAME="default"
        return
    fi

    local i=1
    declare -gA NET_OPT_MODE NET_OPT_NAME

    # Show libvirt networks
    for n in "${LV_NETS[@]}"; do
        echo -e "${WHITE}${i})${GREEN} libvirt network: ${n}${RESET}"
        NET_OPT_MODE[$i]="network"
        NET_OPT_NAME[$i]="$n"
        ((i++))
    done

    # Show host bridges
    for b in "${BRIDGES[@]}"; do
        echo -e "${WHITE}${i})${GREEN} host bridge: ${b}${RESET}"
        NET_OPT_MODE[$i]="bridge"
        NET_OPT_NAME[$i]="$b"
        ((i++))
    done

    echo -e "${WHITE}${i})${GREEN} Use default (libvirt 'default')${RESET}"
    NET_OPT_MODE[$i]="network"
    NET_OPT_NAME[$i]="default"

    flush_stdin
    read -r -p "Choice: " sel

    if [[ -n "${NET_OPT_NAME[$sel]}" ]]; then
        NET_MODE="${NET_OPT_MODE[$sel]}"
        NET_NAME="${NET_OPT_NAME[$sel]}"
    else
        echo -e "${WARN} Invalid option, using libvirt network 'default'.${RESET}"
        NET_MODE="network"
        NET_NAME="default"
    fi

    echo -e "${INFO} Network chosen for VM: mode=${NET_MODE}, name=${NET_NAME}.${RESET}"
}

#-----------------------------------------------------------
# Function: list_internal_networks
# Module:   VM Networking
# Purpose:
#   List all libvirt networks that are considered "internal"
#   or lab-related (host-only, DMZ, AD-lab, etc.), with
#   details like active state and forwarding mode.
#
# Inputs:
#   - None (reads libvirt networks from qemu:///system).
#
# Outputs:
#   - Prints a table of networks (name, active?, autostart?,
#     forward mode, bridge name).
#
# Side effects:
#   - None (purely informational).
#
# Notes:
#   - Used by other functions as a helper for inspection
#     and also as a basis for interactive selection menus.
#-----------------------------------------------------------

list_internal_networks() {
    echo -e "${BLUE}=== Internal Networks (libvirt) ===${RESET}"
    virsh net-list --all
}

#-----------------------------------------------------------
# Function: create_internal_network
# Module:   VM Networking
# Purpose:
#   Create a generic internal libvirt network with a custom
#   name, address space and forward mode (e.g. NAT, routed
#   or isolated).
#
# Inputs:
#   - Prompted from user:
#       * Network name (e.g. int-net-10)
#       * IPv4 base address (e.g. 192.168.100.0/24)
#       * Forward mode (nat / route / none)
#       * Optional bridge name
#
# Outputs:
#   - A new libvirt network defined from an XML template
#     and started automatically.
#
# Side effects:
#   - Creates and starts a new network in libvirt.
#   - May create a Linux bridge depending on XML structure.
#
# Notes:
#   - Forms the basis for more specific networks like
#     AD lab, DMZ, pivot segments, etc.
#-----------------------------------------------------------

create_internal_network() {
    echo -ne "${CYAN} Internal network name (e.g., vlan_vm12): ${RESET}"
    read -r NET_NAME
    echo -ne "${CYAN} Network prefix (e.g., 192.168.50 for 192.168.50.0/24): ${RESET}"
    read -r BASE

    local XML="/tmp/${NET_NAME}.xml"
    cat > "$XML" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='virbr_${NET_NAME}' stp='on' delay='0'/>
  <ip address='${BASE}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${BASE}.50' end='${BASE}.200'/>
    </dhcp>
  </ip>
</network>
EOF

    if virsh net-define "$XML" && virsh net-start "$NET_NAME" && virsh net-autostart "$NET_NAME"; then
        echo -e "${OK} Internal network ${WHITE}${NET_NAME}${RESET} created (NAT).${RESET}"
        log_msg INFO "Internal network created: ${NET_NAME}, base ${BASE}.0/24"
    else
        echo -e "${FAIL} Failed to create network ${NET_NAME}.${RESET}"
        log_msg ERROR "Failed to create internal network ${NET_NAME}."
    fi
}

#-----------------------------------------------------------
# Function: duplicate_internal_network
# Module:   VM Networking
# Purpose:
#   Clone an existing libvirt network definition into a
#   new network with a different name and address space.
#
# Inputs:
#   - Source network selected via list/fzf.
#   - New network name.
#   - Optional new IPv4 subnet to replace the old one.
#
# Outputs:
#   - A new libvirt network created and optionally started.
#
# Side effects:
#   - Reads existing network XML via 'virsh net-dumpxml'.
#   - Writes a modified XML and defines it as a new network.
#
# Notes:
#   - Useful for quickly creating multiple similar lab
#     segments with different subnets (e.g. int-net-10,
#     int-net-20, etc.).
#-----------------------------------------------------------

duplicate_internal_network() {
    echo ""
    echo -e "${CYAN}==== DUPLICATE INTERNAL LIBVIRT NETWORK ====${RESET}"
    echo ""

    # Show networks (informational)
    virsh net-list --all 2>/dev/null || true
    echo ""

    # Select source network using arrow-key menu
    local SRC
    SRC=$(hnm_select_network) || { echo -e "${WARN} No source network selected. Operation canceled.${RESET}"; return; }

    echo -e "${INFO} Source network (template): ${SRC}${RESET}"
    echo ""

    # New network name
    echo -ne "${CYAN} New network name (clone): ${RESET}"
    read -r DST
    DST=$(echo "$DST" | xargs)

    if [[ -z "$DST" ]]; then
        echo -e "${FAIL} New network name cannot be empty.${RESET}"
        return
    fi

    # New prefix
    echo -ne "${CYAN} New network prefix (e.g., 192.168.60): ${RESET}"
    read -r BASE
    BASE=$(echo "$BASE" | xargs)

    if [[ -z "$BASE" ]]; then
        echo -e "${FAIL} Network prefix cannot be empty.${RESET}"
        return
    fi

    local XML="/tmp/${DST}.xml"
    cat > "$XML" <<EOF
<network>
  <name>${DST}</name>
  <forward mode='nat'/>
  <bridge name='virbr_${DST}' stp='on' delay='0'/>
  <ip address='${BASE}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${BASE}.50' end='${BASE}.200'/>
    </dhcp>
  </ip>
</network>
EOF

    echo -e "${INFO} Defining and starting new network '${DST}' on ${BASE}.0/24...${RESET}"
    if virsh net-define "$XML" >/dev/null 2>&1 && \
       virsh net-start "$DST" >/dev/null 2>&1 && \
       virsh net-autostart "$DST" >/dev/null 2>&1; then
        echo -e "${OK} Network ${WHITE}${DST}${RESET} created based on template ${SRC}.${RESET}"
        log_msg INFO "Network ${DST} created (clone of ${SRC}), base ${BASE}.0/24"
    else
        echo -e "${FAIL} Failed to duplicate network.${RESET}"
        log_msg ERROR "Failed to duplicate network ${SRC} to ${DST}."
    fi
}

#-----------------------------------------------------------
# Function: remove_internal_network
# Module:   VM Networking
# Purpose:
#   Remove an existing internal/libvirt network from the
#   hypervisor, including optional destruction if active.
#
# Inputs:
#   - Target network selected via list (fzf/manual).
#   - User confirmation to destroy and undefine network.
#
# Outputs:
#   - Success/failure messages.
#
# Side effects:
#   - May stop the network:
#       virsh net-destroy <name>
#   - Undefines it:
#       virsh net-undefine <name>
#
# Notes:
#   - Does not modify VM XML directly; VMs attached to this
#     network may fail to start until reconfigured.
#-----------------------------------------------------------

remove_internal_network() {
    echo ""
    echo -e "${CYAN}==== REMOVE INTERNAL LIBVIRT NETWORK ====${RESET}"
    echo ""

    # Show networks (informational)
    virsh net-list --all 2>/dev/null || true
    echo ""

    # Select network via arrow-key menu
    local NET_NAME
    NET_NAME=$(hnm_select_network) || { echo -e "${WARN} No network selected. Operation canceled.${RESET}"; return; }

    # Optional: protect "default" if you quiser evitar apagar
    if [[ "$NET_NAME" == "default" ]]; then
        echo -e "${WARN} Network 'default' is usually the main NAT network. Removing it may break other labs.${RESET}"
        read -rp "Do you really want to remove 'default'? (yes/NO): " CONFIRM_DEF
        [[ ! "$CONFIRM_DEF" =~ ^[Yy][Ee][Ss]$ ]] && {
            echo -e "${INFO} Aborting removal of 'default'.${RESET}"
            return
        }
    fi

    echo -e "${INFO} Searching for VMs using network '${NET_NAME}'...${RESET}"
    log_msg INFO "Removing network ${NET_NAME}: searching for associated VMs."

    local USED_VMS=()
    while read -r dom; do
        [[ -z "$dom" ]] && continue
        if virsh dumpxml "$dom" 2>/dev/null | grep -q "source network='${NET_NAME}'"; then
            USED_VMS+=("$dom")
        fi
    done < <(virsh list --all --name 2>/dev/null)

    if [[ ${#USED_VMS[@]} -gt 0 ]]; then
        echo -e "${WARN} The following VMs are connected to network '${NET_NAME}':${RESET}"
        printf '  - %s\n' "${USED_VMS[@]}"
        echo
        echo -e "${CYAN} Action for these VMs before removing the network:${RESET}"
        echo -e "  1) Do nothing"
        echo -e "  2) Send shutdown (virsh shutdown)"
        echo -e "  3) Send reboot (virsh reboot/start)"
        read -r -p "Choice [1/2/3]: " act
	echo ""
        case "$act" in
            2)
                log_msg INFO "Sending shutdown to VMs connected to network ${NET_NAME}."
                for dom in "${USED_VMS[@]}"; do
                    local state
                    state=$(virsh domstate "$dom" 2>/dev/null)
                    if [[ "$state" == "shut off" ]]; then
                        echo -e "${INFO} VM ${dom} is already off.${RESET}"
                        continue
                    fi
                    echo -e "${INFO} Sending shutdown to VM ${dom}...${RESET}"
                    if virsh shutdown "$dom" >/dev/null 2>&1; then
                        echo -e "${OK} Shutdown requested for ${dom}.${RESET}"
                        log_msg INFO "Shutdown requested for VM ${dom}."
                    else
                        echo -e "${FAIL} Failed to send shutdown to ${dom}.${RESET}"
                        log_msg ERROR "Failed to send shutdown to VM ${dom}."
                    fi
                done
                echo -e "${INFO} Please wait a few seconds for the VMs to shut down, if necessary.${RESET}"
                ;;
            3)
                log_msg INFO "Sending reboot to VMs connected to network ${NET_NAME}."
                for dom in "${USED_VMS[@]}"; do
                    local state
                    state=$(virsh domstate "$dom" 2>/dev/null)
                    if [[ "$state" == "shut off" ]]; then
                        echo -e "${INFO} VM ${dom} is off; starting instead of rebooting...${RESET}"
                        if virsh start "$dom" >/dev/null 2>&1; then
                            echo -e "${OK} VM ${dom} started.${RESET}"
                            log_msg INFO "VM ${dom} started (was shut off)."
                        else
                            echo -e "${FAIL} Failed to start VM ${dom}.${RESET}"
                            log_msg ERROR "Failed to start VM ${dom} during 'reboot'."
                        fi
                        continue
                    fi
                    echo -e "${INFO} Sending reboot to VM ${dom}...${RESET}"
                    if virsh reboot "$dom" >/dev/null 2>&1; then
                        echo -e "${OK} Reboot requested for ${dom}.${RESET}"
                        log_msg INFO "Reboot requested for VM ${dom}."
                    else
                        echo -e "${FAIL} Failed to send reboot to ${dom}.${RESET}"
                        log_msg ERROR "Failed to send reboot to VM ${dom}."
                    fi
                done
                ;;
            *)
                echo -e "${WARN} No action will be taken on the VMs before network removal.${RESET}"
                log_msg WARN "Removing network ${NET_NAME} without previous action on associated VMs."
                ;;
        esac
    else
        echo -e "${INFO} No VMs found using network '${NET_NAME}'.${RESET}"
        log_msg INFO "No VMs found using network ${NET_NAME}."
    fi

    echo -e "${INFO} Destroying and undefining network '${NET_NAME}'...${RESET}"
    virsh net-destroy "$NET_NAME" &>/dev/null || true
    if virsh net-undefine "$NET_NAME" >/dev/null 2>&1; then
        echo -e "${OK} Network ${WHITE}${NET_NAME}${RESET} removed.${RESET}"
        log_msg INFO "Network ${NET_NAME} removed."
    else
        echo -e "${FAIL} Failed to remove network ${NET_NAME}.${RESET}"
        log_msg ERROR "Failed to remove network ${NET_NAME}."
    fi
}

#-----------------------------------------------------------
# Function: create_hostonly_network
# Module: VM Networking
# Purpose:
#   Create an isolated host-only libvirt network (host <-> VM only).
# Inputs:
#   User input for:
#       - Network name
#       - Base prefix (e.g. 192.168.70)
# Outputs:
#   A new libvirt network XML file and a defined/started network.
# Notes:
#   - No NAT, no external connectivity.
#   - DHCP automatically configured inside the XML.
#-----------------------------------------------------------

create_hostonly_network() {
    echo -ne "${CYAN} Host-only network name (no NAT, just host <-> VMs): ${RESET}"
    read -r NET_NAME
    echo -ne "${CYAN} Prefix (e.g., 192.168.70): ${RESET}"
    read -r BASE

    local XML="/tmp/hostonly-${NET_NAME}.xml"
    cat > "$XML" <<EOF
<network>
  <name>${NET_NAME}</name>
  <bridge name='virbr_${NET_NAME}' stp='on' delay='0'/>
  <ip address='${BASE}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${BASE}.50' end='${BASE}.200'/>
    </dhcp>
  </ip>
</network>
EOF

    if virsh net-define "$XML" && virsh net-start "$NET_NAME" && virsh net-autostart "$NET_NAME"; then
        echo -e "${OK} Host-only network ${WHITE}${NET_NAME}${RESET} created (no NAT).${RESET}"
        log_msg INFO "Host-only network created: ${NET_NAME}, base ${BASE}.0/24"
    else
        echo -e "${FAIL} Failed to create host-only network.${RESET}"
        log_msg ERROR "Failed to create host-only network ${NET_NAME}."
    fi
}

#-----------------------------------------------------------
# Function: create_dmz_network
# Module: VM Networking
# Purpose:
#   Create a routed/NAT DMZ libvirt network using the host's bridge
#   as outbound interface.
# Inputs:
#   User input for:
#       - DMZ name
#       - Prefix (e.g. 192.168.80)
# Outputs:
#   DMZ network with NAT + DHCP + auto bridge creation.
# Notes:
#   - Automatically attaches to BRIDGE_IF.
#   - Supports DMZ labs, pivoting, web servers, etc.
#-----------------------------------------------------------

create_dmz_network() {
    initial_bridge_setup_if_needed

    echo -e "${CYAN} Create DMZ network routed between VLAN and bridge ${BRIDGE_IF}.${RESET}"
    echo
    echo -ne "${CYAN} DMZ network name (e.g., dmz_lab): ${RESET}"
    read -r NET_NAME
    echo -ne "${CYAN} DMZ network prefix (e.g., 192.168.80): ${RESET}"
    read -r BASE

    local NET="${BASE}.0/24"
    local XML="/tmp/dmz-${NET_NAME}.xml"

    cat > "$XML" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'>
    <interface dev='${BRIDGE_IF}'/>
  </forward>
  <bridge name='virbr_${NET_NAME}' stp='on' delay='0'/>
  <ip address='${BASE}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${BASE}.50' end='${BASE}.200'/>
    </dhcp>
  </ip>
</network>
EOF

    if virsh net-define "$XML" && virsh net-start "$NET_NAME" && virsh net-autostart "$NET_NAME"; then
        echo -e "${OK} DMZ network ${WHITE}${NET_NAME}${RESET} created.${RESET}"
        log_msg INFO "DMZ network created: ${NET_NAME}, base ${NET}, bridge=${BRIDGE_IF}"
    else
        echo -e "${FAIL} Failed to create DMZ network.${RESET}"
        log_msg ERROR "Failed to create DMZ network ${NET_NAME}."
        return
    fi

    echo -e "${INFO} Adding iptables rules for DMZ NAT via ${BRIDGE_IF}...${RESET}"
    iptables -t nat -A POSTROUTING -s "${NET}" -o "${BRIDGE_IF}" -j MASQUERADE
    iptables -A FORWARD -s "${NET}" -o "${BRIDGE_IF}" -j ACCEPT
    iptables -A FORWARD -d "${NET}" -m state --state ESTABLISHED,RELATED -j ACCEPT
    echo -e "${OK} Basic NAT/routing rules for DMZ added (current session).${RESET}"
    log_msg INFO "iptables rules added for DMZ ${NET_NAME} (${NET}) via ${BRIDGE_IF}."
}


#-----------------------------------------------------------
# Function: attach_vms_to_network
# Module: VM Networking
# Purpose:
#   Interactive menu to attach one or more VMs to a selected
#   libvirt network using fzf or manual input.
# Inputs:
#   - User selection of target network (via hnm_select_network)
#   - User selection of one or more VMs
# Outputs:
#   VMs redefined with new NIC configuration.
# Notes:
#   - VM XML backup is performed via backup_vm_xml.
#   - Handles VMs powered on or off.
#-----------------------------------------------------------

attach_vms_to_network() {
    echo ""
    echo -e "${CYAN}==== ATTACH VMs TO LIBVIRT NETWORK ====${RESET}"
    echo ""

    # 1) Select target network using arrow keys
    local NET_NAME
    NET_NAME=$(hnm_select_network) || { echo -e "${WARN} Operation canceled.${RESET}"; return; }

    echo -e "${INFO} Target network: ${NET_NAME}${RESET}"
    echo ""

    # 2) Build VM list
    local ALL_VMS VM_SELECTION VM_LIST
    ALL_VMS=$(virsh list --all --name 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d')

    if [[ -z "$ALL_VMS" ]]; then
        echo -e "${FAIL} No VMs found in libvirt.${RESET}"
        log_msg WARN "attach_vms_to_network: no VMs available"
        return 1
    fi

    # 3) Select one or more VMs with fzf (arrow keys + multi-select)
    if ensure_fzf; then
        echo -e "${YELLOW} Select one or more VMs (TAB/SPACE to mark, Enter to confirm):${RESET}"
        echo ""
        VM_SELECTION=$(printf "%s\n" "$ALL_VMS" \
            | fzf --multi --prompt="VMs > " --height=15 --border --ansi)
        echo ""
        VM_LIST=$(echo "$VM_SELECTION" | xargs -n1)
    fi

    # Fallback to manual input if fzf not available or user canceled
    if [[ -z "$VM_LIST" ]]; then
        echo -e "${YELLOW} Available VMs:${RESET}"
        virsh list --all 2>/dev/null | sed '1,2d'
        echo ""
        echo -e "${CYAN} List of VMs (space-separated names, Enter to cancel):${RESET}"
        read -r -r VM_LIST
        VM_LIST=$(echo "$VM_LIST" | xargs)
    fi

    if [[ -z "$VM_LIST" ]]; then
        echo -e "${WARN} No VMs specified. Operation canceled.${RESET}"
        return 0
    fi

    local ATTACHED_VMS=()

    # 4) Loop over selected VMs
    for dom in $VM_LIST; do
        [[ -z "$dom" ]] && continue

        if ! virsh dominfo "$dom" >/dev/null 2>&1; then
            echo -e "${FAIL} VM '${dom}' not found in libvirt.${RESET}"
            log_msg ERROR "attach_vms_to_network: VM ${dom} does not exist."
            continue
        fi

        local state
        state=$(virsh domstate "$dom" 2>/dev/null)

        echo -e "${INFO} Adjusting VM '${dom}' for network '${NET_NAME}' (state: ${state})...${RESET}"
        log_msg INFO "Connecting VM ${dom} to network ${NET_NAME} (state: ${state})."

        # Discover the first interface of type 'network' for the VM
        # domiflist: Interface  Type  Source  Model  MAC
        # We want: iface mac current_net
        local line iface mac current_net
        line="$(virsh domiflist "$dom" 2>/dev/null | awk 'NR>2 && $2=="network" {print $1" "$5" "$3; exit}')"

        if [[ -n "$line" ]]; then
            read -r iface mac current_net <<<"$line"

            # If already on the right network, just inform
            if [[ "$current_net" == "$NET_NAME" ]]; then
                echo -e "${WARN} VM '${dom}' is already attached to network '${NET_NAME}'.${RESET}"
            else
                echo -e "${INFO} Detaching current interface (${iface}, MAC ${mac}, network ${current_net})...${RESET}"
                if [[ "$state" == "running" ]]; then
                    virsh detach-interface "$dom" \
                        --type network --mac "$mac" --config --live \
                        >/dev/null 2>&1 || true
                else
                    virsh detach-interface "$dom" \
                        --type network --mac "$mac" --config \
                        >/dev/null 2>&1 || true
                fi
            fi
        fi

        echo -e "${INFO} Attaching new interface on network '${NET_NAME}'...${RESET}"
        local ATTACH_OK=1
        if [[ "$state" == "running" ]]; then
            if virsh attach-interface "$dom" \
                --type network --source "$NET_NAME" \
                --model virtio --config --live >/dev/null 2>&1; then
                ATTACH_OK=0
            fi
        else
            if virsh attach-interface "$dom" \
                --type network --source "$NET_NAME" \
                --model virtio --config >/dev/null 2>&1; then
                ATTACH_OK=0
            fi
        fi

        if [[ $ATTACH_OK -eq 0 ]]; then
            echo -e "${OK} VM '${dom}' is now attached to network '${NET_NAME}'.${RESET}"
            log_msg INFO "VM ${dom} connected to network ${NET_NAME} (attach-interface)."
            ATTACHED_VMS+=("$dom")
        else
            echo -e "${FAIL} Failed to connect VM '${dom}' to network '${NET_NAME}'.${RESET}"
            log_msg ERROR "Failed to connect ${dom} to network ${NET_NAME} via attach-interface."
        fi
    done

    if ((${#ATTACHED_VMS[@]} > 0)); then
        echo
        echo -e "${CYAN} VM(s) successfully connected to network '${NET_NAME}':${RESET}"
        printf '  - %s\n' "${ATTACHED_VMS[@]}"
        echo ""
    fi
}

#-----------------------------------------------------------
# Function: attach_vms_to_br0
# Module: VM Networking
# Purpose:
#   Reconfigure VM(s) NIC to use the main system bridge (br0)
#   for full L2 connectivity to LAN/Wi-Fi depending on host config.
# Inputs:
#   - VM name(s) (interactive)
# Outputs:
#   VMs updated to use <interface type='bridge' source bridge='br0'>
# Notes:
#   - Requires that br0 is already created.
#   - Used for Pivoting, AD labs, and real-traffic simulations.
#-----------------------------------------------------------

attach_vms_to_br0() {
    echo
    echo -ne "${CYAN} Target bridge interface name (default: ${BRIDGE_IF}): ${RESET}"
    read -r BR_IF
    [[ -z "$BR_IF" ]] && BR_IF="$BRIDGE_IF"

    echo -e "${CYAN} Select the VMs you want to connect to bridge ${BR_IF}:${RESET}"
    VM_LIST=$(select_vms_fzf)

    if [[ -z "$VM_LIST" ]]; then
        echo -e "${WARN} No VMs selected.${RESET}"
        log_msg WARN "attach_vms_to_br0 with no VM selection (fzf)."
        return
    fi

    local ATTACHED_VMS=()

    for dom in $VM_LIST; do
        [[ -z "$dom" ]] && continue

        echo -e "${INFO} Adjusting VM ${dom} to use bridge ${BR_IF}...${RESET}"
        log_msg INFO "Adjusting VM ${dom} for bridge ${BR_IF}."

        backup_vm_xml "$dom"

        virsh dumpxml "$dom" \
        | sed \
            -e "0,/<interface type='bridge'>/ s//<interface type='bridge'>/" \
            -e "0,/<source bridge='[^']*'\/>/ s//<source bridge='${BR_IF}'\/>/" \
        > /tmp/${dom}-net.xml

        if ! grep -q "source bridge='${BR_IF}'" /tmp/${dom}-net.xml; then
            virsh dumpxml "$dom" \
            | sed \
                -e "0,/<interface type='network'>/ s//<interface type='bridge'>/" \
                -e "0,/<source network='[^']*'\/>/ s//<source bridge='${BR_IF}'\/>/" \
            > /tmp/${dom}-net.xml
        fi

        if virsh define /tmp/${dom}-net.xml >/dev/null 2>&1; then
            echo -e "${OK} VM ${dom} is now configured to use bridge ${BR_IF}.${RESET}"
            log_msg INFO "VM ${dom} connected to bridge ${BR_IF}."
            ATTACHED_VMS+=("$dom")
        else
            echo -e "${FAIL} Failed to redefine XML for VM ${dom}.${RESET}"
            log_msg ERROR "Failed to redefine XML for VM ${dom} for bridge."
        fi
    done

    if [[ ${#ATTACHED_VMS[@]} -eq 0 ]]; then
        echo -e "${WARN} No VMs connected to the bridge.${RESET}"
        return
    fi

    echo
    echo -e "${CYAN} Connected VM(s):${RESET}"
    printf '  - %s\n' "${ATTACHED_VMS[@]}"
    echo

    echo -e "${CYAN} Post-configuration actions:${RESET}"
    echo -e "  1) Nothing"
    echo -e "  2) Start VMs"
    echo -e "  3) Reboot VMs"
    read -r -p "Choice [1/2/3]: " act
    echo ""
    case "$act" in
        2)
            for dom in "${ATTACHED_VMS[@]}"; do
                state=$(virsh domstate "$dom")
                if [[ "$state" != "running" ]]; then
                    virsh start "$dom"
                    echo -e "${OK} VM ${dom} started.${RESET}"
                else
                    echo -e "${WARN} VM ${dom} was already running.${RESET}"
                fi
            done
            ;;
        3)
            for dom in "${ATTACHED_VMS[@]}"; do
                state=$(virsh domstate "$dom")
                if [[ "$state" == "running" ]]; then
                    virsh reboot "$dom"
                    echo -e "${OK} Reboot sent to ${dom}.${RESET}"
                else
                    virsh start "$dom"
                    echo -e "${OK} VM ${dom} started.${RESET}"
                fi
            done
            ;;
        *)
            echo -e "${INFO} No extra action.${RESET}"
            ;;
    esac
}

#-----------------------------------------------------------
# Function: move_vms_from_br0
# Module: VM Networking
# Purpose:
#   Move one or multiple VMs **back to NAT (default)** when they
#   are currently attached to br0.
# Inputs:
#   - VM selection (fzf or manual)
# Outputs:
#   Updated VM XMLs returning to 'network default'.
# Notes:
#   - Ensures correct cleanup for labs that temporarily push VMs to br0.
#-----------------------------------------------------------

move_vms_from_br0() {
    echo ""
    echo -e "${CYAN}==== MOVE VMs FROM BRIDGE/br0 TO 'default' (NAT) ====${RESET}"
    echo ""

    # Build list of all VMs
    local ALL_VMS VM_SELECTION VM_LIST
    ALL_VMS=$(virsh list --all --name 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d')

    if [[ -z "$ALL_VMS" ]]; then
        echo -e "${FAIL} No VMs found in libvirt.${RESET}"
        log_msg WARN "move_vms_from_br0: no VMs available"
        return 1
    fi

    # Multi-select VMs with fzf (arrow keys + TAB/SPACE)
    if ensure_fzf; then
        echo -e "${YELLOW} Select one or more VMs to move to network 'default' (NAT).${RESET}"
        echo -e "${YELLOW} Use TAB/SPACE to mark and Enter to confirm.${RESET}"
        echo ""
        VM_SELECTION=$(printf "%s\n" "$ALL_VMS" \
            | fzf --multi --prompt="VMs > " --height=15 --border --ansi)
        echo ""
        VM_LIST=$(echo "$VM_SELECTION" | xargs -n1)
    fi

    # Fallback: manual input if fzf not available or user canceled
    if [[ -z "$VM_LIST" ]]; then
        echo -e "${YELLOW} Available VMs:${RESET}"
        virsh list --all 2>/dev/null | sed '1,2d'
        echo ""
        echo -e "${CYAN} List of VMs to revert to NAT (network 'default') (space-separated names, Enter to cancel):${RESET}"
        read -r VM_LIST
        VM_LIST=$(echo "$VM_LIST" | xargs)
    fi

    if [[ -z "$VM_LIST" ]]; then
        echo -e "${WARN} No VMs specified. Operation canceled.${RESET}"
        return 0
    fi

    # Optional: ensure 'default' network exists
    if ! virsh net-info default >/dev/null 2>&1; then
        echo -e "${FAIL} Libvirt network 'default' not found. Aborting.${RESET}"
        log_msg ERROR "move_vms_from_br0: network 'default' does not exist."
        return 1
    fi

    local MOVED_VMS=()

    for dom in $VM_LIST; do
        [[ -z "$dom" ]] && continue

        if ! virsh dominfo "$dom" >/dev/null 2>&1; then
            echo -e "${FAIL} VM '${dom}' not found in libvirt.${RESET}"
            log_msg ERROR "move_vms_from_br0: VM ${dom} not found."
            continue
        fi

        echo -e "${INFO} Adjusting VM '${dom}' to network 'default' (NAT)...${RESET}"
        log_msg INFO "Moving VM ${dom} from bridge/br0 to 'default' (NAT) via XML redefine."

        # Backup original XML
        backup_vm_xml "$dom"

        # Dump current XML and replace the first <source network='...'/>
        virsh dumpxml "$dom" \
        | sed \
            -e "0,/<interface type='network'>/ s//<interface type='network'>/" \
            -e "0,/<source network='[^']*'\/>/ s//<source network='default'\/>/" \
        > "/tmp/${dom}-net.xml"

        if virsh define "/tmp/${dom}-net.xml" >/dev/null 2>&1; then
            echo -e "${OK}VM '${dom}' is now configured to use network 'default' (NAT).${RESET}"
            log_msg INFO "VM ${dom} moved to 'default' (NAT) network via XML redefine."
            MOVED_VMS+=("$dom")
        else
            echo -e "${FAIL}Failed to redefine XML for VM '${dom}'.${RESET}"
            log_msg ERROR "Failed to redefine XML for VM ${dom} in move_vms_from_br0."
        fi
    done

    if ((${#MOVED_VMS[@]} > 0)); then
        echo ""
        echo -e "${CYAN} VM(s) successfully moved to network 'default' (NAT):${RESET}"
        printf '  - %s\n' "${MOVED_VMS[@]}"
        echo ""
    fi
}

    for dom in $VM_LIST; do
        [[ -z "$dom" ]] && continue
        echo -e "${INFO} Reverting VM ${dom} to NAT (default)...${RESET}"
        log_msg INFO "Reverting VM ${dom} to default network (NAT)."
        backup_vm_xml "$dom"

        virsh dumpxml "$dom" \
        | sed \
            -e "0,/<interface type='bridge'>/ s//<interface type='network'>/" \
            -e "0,/<source bridge='[^']*'\/>/ s//<source network='default'\/>/" \
        > /tmp/${dom}-nat.xml

        if virsh define /tmp/${dom}-nat.xml >/dev/null 2>&1; then
            echo -e "${OK} VM ${dom} reverted to using NAT (default).${RESET}"
            log_msg INFO "VM ${dom} reverted to default network (NAT)."
        else
            echo -e "${FAIL} Failed to redefine VM ${dom}.${RESET}"
            log_msg ERROR "Failed to redefine XML for VM ${dom} to default network."
        fi
    done

#-----------------------------------------------------------
# Function: remove_vms_from_br0
# Module: VM Networking
# Purpose:
#   Helper that specifically removes VMs currently attached to the
#   physical bridge interface, redirecting them back to NAT.
# Inputs:
#   - Automatically detects VMs using <source bridge="br0">
# Outputs:
#   VM network reverted to default NAT.
# Notes:
#   - Called internally by lab cleanup functions.
#-----------------------------------------------------------

remove_vms_from_br0() {
    #echo "==== REVERT VMs ON BRIDGE TO DEFAULT NAT ===="
    draw_menu_title "REVERT VMs ON BRIDGE TO DEFAULT NAT"
    local TARGET_BRIDGE="${BRIDGE_IF:-br0}"

    # Garante que a rede default existe e está ativa
    if ! ensure_libvirt_net default; then
        echo -e "${FAIL} Could not ensure libvirt network 'default'.${RESET}"
        return 1
    fi

    # Descobrir VMs conectadas à bridge
    local ALL_VMS CANDIDATES vm
    ALL_VMS=$(virsh list --all --name 2>/dev/null | sed '/^$/d')
    if [[ -z "$ALL_VMS" ]]; then
        echo -e "${WARN} No VMs found in libvirt.${RESET}"
        return 0
    fi

    CANDIDATES=""
    for vm in $ALL_VMS; do
        # Verifica se alguma interface dessa VM usa a bridge alvo
        if virsh domiflist "$vm" 2>/dev/null \
            | awk -v br="$TARGET_BRIDGE" 'NR>2 && $2=="bridge" && $3==br {found=1} END{exit !found}'; then
            CANDIDATES+="$vm"$'\n'
        fi
    done

    if [[ -z "$CANDIDATES" ]]; then
        echo -e "${INFO} No VMs currently attached to bridge ${TARGET_BRIDGE}.${RESET}"
        return 0
    fi

    # Seleção de VMs
    local SELECTION VM_LIST
    if ensure_fzf; then
        echo -e "${YELLOW} Select one or more VMs to revert to NAT 'default' (TAB/SPACE, Enter to confirm):${RESET}"
        SELECTION=$(printf "%s\n" "$CANDIDATES" \
            | fzf --multi --prompt="VMs > " --height=15 --border --ansi)
        VM_LIST=$(echo "$SELECTION" | xargs -n1)
    else
        echo -e "${YELLOW} VMs attached to bridge ${TARGET_BRIDGE}:${RESET}"
        printf '%s\n' "$CANDIDATES"
        read -r -p "Enter VMs to revert (space-separated, Enter to cancel): " VM_LIST
        VM_LIST=$(echo "$VM_LIST" | xargs)
    fi

    [[ -z "$VM_LIST" ]] && {
        echo -e "${WARN} No VMs selected. Operation canceled.${RESET}"
        return 1
    }

    # Processar cada VM
    for vm in $VM_LIST; do
        [[ -z "$vm" ]] && continue

        if ! virsh dominfo "$vm" >/dev/null 2>&1; then
            echo -e "${FAIL} VM '${vm}' not found in libvirt.${RESET}"
            continue
        fi

        local state live_flag
        state=$(virsh domstate "$vm" 2>/dev/null | tr -d '\r')
        live_flag=""
        [[ "$state" == "running" ]] && live_flag="--live"

        echo -e "${INFO} Reverting VM '${vm}' from bridge ${TARGET_BRIDGE} to NAT 'default'...${RESET}"

        # Lista interfaces bridge dessa VM
        # virsh domiflist columns: Interface  Type  Source  Model  MAC
        while read -r iface type source model mac _; do
            [[ "$type" != "bridge" ]] && continue
            [[ "$source" != "$TARGET_BRIDGE" ]] && continue

            echo -e "${INFO} Detaching bridge iface $iface (MAC $mac) from VM ${vm}...${RESET}"
            if virsh detach-interface "$vm" --type bridge --mac "$mac" --config $live_flag >/dev/null 2>&1; then
                echo -e "${OK} Detached bridge interface from ${vm}.${RESET}"
            else
                echo -e "${FAIL} Failed to detach bridge interface from ${vm}.${RESET}"
                continue
            fi

            echo -e "${INFO} Attaching NAT 'default' network to VM ${vm}...${RESET}"
            # Model virtio por padrão; sem target deixa o libvirt escolher
            if virsh attach-interface "$vm" --type network --source default \
                    --model virtio --config $live_flag >/dev/null 2>&1; then
                echo -e "${OK} VM ${vm} now uses NAT network 'default'.${RESET}"
                log_msg INFO "remove_vms_from_br0: VM=${vm} reverted from bridge=${TARGET_BRIDGE} to network=default."
            else
                echo -e "${FAIL} Failed to attach NAT network 'default' to ${vm}.${RESET}"
            fi
        done < <(virsh domiflist "$vm" 2>/dev/null | sed '1,2d')
    done

    echo ""
    echo -e "${CYAN}Done reverting selected VMs from ${TARGET_BRIDGE} to NAT 'default'.${RESET}"
    echo ""
}

#-----------------------------------------------------------
# Function: attach_vms_to_network_wrapper
# Module: VM Networking
# Purpose:
#   Wrapper to attach VM(s) to a specific network without prompting
#   the user for which network to use.
# Inputs:
#   $1 = target libvirt network name
# Outputs:
#   VMs reconfigured to use that network.
# Notes:
#   - Used by DMZ and Lab templates.
#-----------------------------------------------------------

attach_vms_to_network_wrapper() {
    local NET_NAME="$1"
    echo -e "${CYAN} List of VMs (space-separated names) to use network ${NET_NAME}:${RESET}"
    read -r VM_LIST

    # Reuse existing logic from your attach_vms_to_network,
    # but without asking for the network name again
    local ATTACHED_VMS=()

    for dom in $VM_LIST; do
        [[ -z "$dom" ]] && continue
        echo -e "${INFO} Adjusting VM ${dom} to network ${NET_NAME}...${RESET}"
        log_msg INFO "Connecting VM ${dom} to network ${NET_NAME}."
        backup_vm_xml "$dom"

        virsh dumpxml "$dom" \
        | sed \
            -e "0,/<interface type='network'>/ s//<interface type='network'>/" \
            -e "0,/<source network='[^']*'\/>/ s//<source network='${NET_NAME}'\/>/" \
        > /tmp/${dom}-net.xml

        if ! grep -q "source network='${NET_NAME}'" /tmp/${dom}-net.xml; then
            virsh dumpxml "$dom" \
            | sed \
                -e "0,/<interface type='bridge'>/ s//<interface type='network'>/" \
                -e "0,/<source bridge='[^']*'\/>/ s//<source network='${NET_NAME}'\/>/" \
            > /tmp/${dom}-net.xml
        fi

        if virsh define /tmp/${dom}-net.xml >/dev/null 2>&1; then
            echo -e "${OK} VM ${dom} is now on network ${NET_NAME}.${RESET}"
            ATTACHED_VMS+=("$dom")
        else
            echo -e "${FAIL} Failed to redefine VM ${dom}.${RESET}"
        fi
    done

    if [[ ${#ATTACHED_VMS[@]} -eq 0 ]]; then
        echo -e "${WARN} No VM was connected to network ${NET_NAME}.${RESET}"
        return
    fi

    echo
    echo -e "${CYAN} VM(s) connected to network ${NET_NAME}:${RESET}"
    printf '  - %s\n' "${ATTACHED_VMS[@]}"
    echo
}
