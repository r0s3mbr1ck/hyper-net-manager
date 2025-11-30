#############################################
# MODULE: Labs (Prebuilt Scenarios)
# - AD, DMZ, Pivot, Traffic, Misconfigs, etc.
#############################################

#-----------------------------------------------------------
# Function: labs_menu
# Module:   Labs
# Purpose:
#   Central menu for all prebuilt lab scenarios. Provides
#   shortcuts to create AD labs, DMZ web labs, pivot setups,
#   traffic labs, and run bulk operations on lab VMs
#   (snapshots, rollback, misconfig injection, etc.).
#
# Inputs:
#   - User selection via interactive menu (fzf or numeric).
#
# Outputs:
#   - Routes control to the appropriate lab_* function, or
#     returns to main menu.
#
# Notes:
#   - Entry point for all "Lab" features in HNM.
#-----------------------------------------------------------

labs_menu() {
    while true; do
        local MENU_LIST MENU_SEL op_lab
	echo
        draw_menu_title " PENTEST / STUDY LABS MENU"

        MENU_LIST=$(
        cat <<EOF
1) Create corporate AD LAB (AD + client + attacker)
2) Isolate VM in SANDBOX network (no internet)
3) Create PIVOTING LAB (internal vlan + dmz + internet)
4) Create corporate DMZ (web server in exposed network)
5) Sniff traffic from a bridge/VLAN (tcpdump pcap)
6) Test network performance (speedtest/iperf3)
7) Block internet for all VMs (intranet mode)
8) Allow internet only for selected VMs
9) Create security SNAPSHOT of all LAB VMs
10) Revert SNAPSHOT of all LAB VMs
11) Inject misconfigurations for training
12) Show current LABs and network topology
13) Generate test traffic between host/VMs
14) Connectivity tests (ping/port/http/dns)
0) Back to main menu
EOF
        )

        if ensure_fzf; then
            MENU_SEL=$(hnm_select "Select option" "$MENU_LIST") || continue
            op_lab=$(echo "$MENU_SEL" | awk '{print $1}' | tr -d ')')
        else
            echo -e "${WHITE}1)${GREEN} Create corporate AD LAB (AD + client + attacker)${RESET}"
            echo -e "${WHITE}2)${GREEN} Isolate VM in SANDBOX network (no internet)${RESET}"
            echo -e "${WHITE}3)${GREEN} Create PIVOTING LAB (internal vlan + dmz + internet)${RESET}"
            echo -e "${WHITE}4)${GREEN} Create corporate DMZ (web server in exposed network)${RESET}"
            echo -e "${WHITE}5)${GREEN} Sniff traffic from a bridge/VLAN (tcpdump pcap)${RESET}"
            echo -e "${WHITE}6)${GREEN} Test network performance (speedtest/iperf3)${RESET}"
            echo -e "${WHITE}7)${GREEN} Block internet for all VMs (intranet mode)${RESET}"
            echo -e "${WHITE}8)${GREEN} Allow internet only for selected VMs${RESET}"
            echo -e "${WHITE}9)${GREEN} Create security SNAPSHOT of all LAB VMs${RESET}"
            echo -e "${WHITE}10)${GREEN} Revert SNAPSHOT of all LAB VMs${RESET}"
            echo -e "${WHITE}11)${GREEN} Inject misconfigurations for training${RESET}"
            echo -e "${WHITE}12)${GREEN} Show current LABs and network topology${RESET}"
            echo -e "${WHITE}13)${GREEN} Generate test traffic between host/VMs !####! UNDER CONSTRUCTION !####!${RESET}"
            echo -e "${WHITE}14)${GREEN} Connectivity tests (ping/port/http/dns) !####! UNDER CONSTRUCTION !####!${RESET}"
            echo -e "${WHITE}0)${RED} Back to main menu${RESET}"
            flush_stdin
            read -r -p "Choice: " op_lab
        fi

        echo ""

        case "$op_lab" in
            1)  lab_create_ad_corp ;;
            2)  lab_isolar_vm_sandbox ;;
            3)  lab_create_pivot ;;
            4)  lab_create_dmz_web ;;
            5)  lab_sniff_interface ;;
            6)  lab_network_perf ;;
            7)  lab_block_internet_all ;;
            8)  lab_allow_internet_some ;;
            9)  lab_snapshot_all ;;
            10) lab_rollback_all ;;
            11) lab_inject_misconfigs ;;
            12) lab_show_topology ;;
            13) lab_traffic_menu ;;
            14) lab_connectivity_tests ;;
            0)  break ;;
            *)  echo -e "${FAIL} Invalid option.${RESET}" ;;
        esac
    done
}

#-----------------------------------------------------------
# Function: create_lab_net_generic
# Module:   Labs
# Purpose:
#   Generic helper to create one or more internal lab networks
#   (e.g. "ad-net", "dmz-net", "mgmt-net") using libvirt
#   network definitions with specific CIDR ranges and types.
#
# Inputs:
#   - Lab profile / role (AD, DMZ, pivot, etc.).
#   - User-provided base network and name suffixes.
#
# Outputs:
#   - One or more libvirt networks defined and started.
#
# Notes:
#   - Used internally by create_ad_net, lab_create_dmz_web
#     and other lab initializers.
#-----------------------------------------------------------

create_lab_net_generic() {
    local NET_NAME="$1"
    local BR_NAME="$2"
    local GW_IP="$3"
    local FWD_MODE="$4"   # "nat" or "none"

    if [[ -z "$NET_NAME" || -z "$BR_NAME" || -z "$GW_IP" ]]; then
        echo -e "${FAIL} create_lab_net_generic: insufficient parameters.${RESET}"
        log_msg ERROR "create_lab_net_generic: insufficient parameters NET=${NET_NAME} BR=${BR_NAME} GW=${GW_IP}."
        return 1
    fi

    # If the network already exists and is active, don't recreate
    if virsh net-info "$NET_NAME" &>/dev/null; then
        local state
        state=$(virsh net-info "$NET_NAME" | awk -F': *' '/Active/ {print $2}')
        if [[ "$state" == "yes" ]]; then
            echo -e "${WARN} Network '${NET_NAME}' already exists and is active. Will not be recreated.${RESET}"
            log_msg WARN "LAB net '${NET_NAME}' already active; skipping creation."
            return 0
        fi
        echo -e "${INFO} Network '${NET_NAME}' already exists. Attempting to start...${RESET}"
        if virsh net-start "$NET_NAME" >/dev/null 2>&1; then
            echo -e "${OK} Network '${NET_NAME}' started.${RESET}"
            return 0
        else
            echo -e "${WARN} Could not start network '${NET_NAME}'. Attempting to redefine...${RESET}"
        fi
    fi

    local XML_FILE="/tmp/${NET_NAME}.xml"
    local PREFIX="${GW_IP%.*}"

    # Build XML (with or without NAT)
    {
        echo "<network>"
        echo "  <name>${NET_NAME}</name>"
        if [[ "$FWD_MODE" == "nat" ]]; then
            echo "  <forward mode='nat'/>"
        fi
        echo "  <bridge name='${BR_NAME}' stp='on' delay='0'/>"
        echo "  <ip address='${GW_IP}' netmask='255.255.255.0'>"
        echo "    <dhcp>"
        echo "      <range start='${PREFIX}.100' end='${PREFIX}.254'/>"
        echo "    </dhcp>"
        echo "  </ip>"
        echo "</network>"
    } > "$XML_FILE"

    echo -e "${INFO} Creating libvirt network '${NET_NAME}' (${GW_IP}/24) with bridge ${BR_NAME} (mode=${FWD_MODE}).${RESET}"
    log_msg INFO "Creating LAB net '${NET_NAME}' (${GW_IP}/24) bridge=${BR_NAME} mode=${FWD_MODE}."

    # Clean up any old remnants
    virsh net-destroy  "$NET_NAME" &>/dev/null || true
    virsh net-undefine "$NET_NAME" &>/dev/null || true

    if ! virsh net-define "$XML_FILE" >/dev/null 2>&1; then
        echo -e "${FAIL} Failed to define network '${NET_NAME}'.${RESET}"
        log_msg ERROR "Failed to define network '${NET_NAME}' with XML ${XML_FILE}."
        return 1
    fi

    if ! virsh net-start "$NET_NAME" >/dev/null 2>&1; then
        echo -e "${FAIL} Failed to start network '${NET_NAME}'.${RESET}"
        log_msg ERROR "Failed to start network '${NET_NAME}'."
        return 1
    fi

    virsh net-autostart "$NET_NAME" >/dev/null 2>&1 || true

    echo -e "${OK} Network '${NET_NAME}' created/started and marked for autostart.${RESET}"
    log_msg INFO "LAB Network '${NET_NAME}' ready (autostart)."
}

#-----------------------------------------------------------
# Function: create_ad_net
# Module:   Labs
# Purpose:
#   Create the core network topology for an Active Directory
#   lab: typically includes an internal AD segment, optional
#   DMZ, and a management or client VLAN/network.
#
# Inputs:
#   - User choices for network names and CIDR ranges.
#
# Outputs:
#   - One or more libvirt networks dedicated to AD testing.
#
# Notes:
#   - Often combined with lab_create_ad_corp to assemble
#     full AD lab (DC, member servers, clients).
#-----------------------------------------------------------

create_ad_net() {
    # $1 = libvirt network name (e.g.: ad_corp_dc)
    # $2 = bridge name        (e.g.: br_ad_dc)
    # $3 = base IP            (e.g.: 10.10.1.1)
    local NET_NAME="$1"
    local BR_NAME="$2"
    local NET_ADDR="$3"

    # valida parâmetros
    if [[ -z "$NET_NAME" || -z "$BR_NAME" || -z "$NET_ADDR" ]]; then
        echo -e "${FAIL} create_ad_net: insufficient parameters.${RESET}"
        return 1
    fi

    # checagem simples de IPv4
    if ! [[ "$NET_ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${FAIL} create_ad_net: invalid IPv4 address '${NET_ADDR}'.${RESET}"
        return 1
    fi

    # extrai base da rede (10.10.1.1 -> 10.10.1)
    local NET_BASE="${NET_ADDR%.*}"

    # se já existe
    if virsh -c qemu:///system net-info "$NET_NAME" &>/dev/null; then
        local state
        state=$(virsh -c qemu:///system net-info "$NET_NAME" | awk -F': *' '/Active/ {print $2}')
        if [[ "$state" == "yes" ]]; then
            echo -e "${WARN} Network '${NET_NAME}' already exists and is active. Will not be recreated.${RESET}"
            log_msg WARN "create_ad_net: network '${NET_NAME}' already active; skipping creation."
            return 0
        fi
        echo -e "${INFO} Network '${NET_NAME}' already exists. Attempting to start...${RESET}"
        if virsh -c qemu:///system net-start "$NET_NAME" >/dev/null 2>&1; then
            echo -e "${OK} Network '${NET_NAME}' started.${RESET}"
            return 0
        else
            echo -e "${WARN} Could not start network '${NET_NAME}'. Attempting to redefine...${RESET}"
        fi
    fi

    # monta XML em /tmp
    local XML_FILE="/tmp/${NET_NAME}.xml"

    cat > "$XML_FILE" <<EOF
<network>
  <name>${NET_NAME}</name>
  <forward mode='nat'/>
  <bridge name='${BR_NAME}' stp='on' delay='0'/>
  <ip address='${NET_ADDR}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${NET_BASE}.100' end='${NET_BASE}.254'/>
    </dhcp>
  </ip>
</network>
EOF

    echo -e "${INFO} Creating AD network '${NET_NAME}' (${NET_ADDR}/24) bridge=${BR_NAME}.${RESET}"
    log_msg INFO "Creating AD network '${NET_NAME}' (${NET_ADDR}/24) bridge=${BR_NAME}."

    # limpa definição antiga, se existir
    virsh -c qemu:///system net-destroy  "$NET_NAME" &>/dev/null || true
    virsh -c qemu:///system net-undefine "$NET_NAME" &>/dev/null || true

    # NÃO esconde o erro aqui, pra você ver se ainda der ruim
    if ! virsh -c qemu:///system net-define "$XML_FILE"; then
        echo -e "${FAIL} Failed to define network '${NET_NAME}' with XML ${XML_FILE}.${RESET}"
        log_msg ERROR "Failed to define network '${NET_NAME}' with XML ${XML_FILE}."
        return 1
    fi

    if ! virsh -c qemu:///system net-start "$NET_NAME" >/dev/null 2>&1; then
        echo -e "${FAIL} Failed to start network '${NET_NAME}'.${RESET}"
        log_msg ERROR "Failed to start network '${NET_NAME}'."
        return 1
    fi

    virsh -c qemu:///system net-autostart "$NET_NAME" >/dev/null 2>&1 || true
    echo -e "${OK} Network '${NET_NAME}' created/started and marked for autostart.${RESET}"
    log_msg INFO "Network '${NET_NAME}' ready (autostart)."
}

#-----------------------------------------------------------
# Function: lab_create_pivot
# Module:   Labs
# Purpose:
#   Build a pivoting lab where one or more VMs act as
#   pivot hosts between internal segments and the external
#   / DMZ networks.
#
# Inputs:
#   - Selection of pivot VM(s).
#   - Choice of networks for "external" and "internal" legs.
#
# Outputs:
#   - Updated VM NICs attached to multiple networks.
#
# Notes:
#   - Used to simulate compromised hosts used for lateral
#     movement and multi-hop access.
#-----------------------------------------------------------

lab_create_pivot() {
    echo
    draw_menu_title "LAB: PIVOTING (internal vlan + dmz + internet)"
    #echo -e "${GREEN_TITLE}==== LAB: PIVOTING (internal vlan + dmz + internet) ====${RESET}"

    echo -ne "${CYAN} INTERNAL network name (default: pivot_int): ${RESET}"
    read -r NET_INT
    [[ -z "$NET_INT" ]] && NET_INT="pivot_int"

    echo -ne "${CYAN} INTERNAL network gateway (default: 10.30.10.1): ${RESET}"
    read -r GW_INT
    [[ -z "$GW_INT" ]] && GW_INT="10.30.10.1"

    echo -ne "${CYAN} DMZ network name (default: pivot_dmz): ${RESET}"
    read -r NET_DMZ
    [[ -z "$NET_DMZ" ]] && NET_DMZ="pivot_dmz"

    echo -ne "${CYAN} DMZ network gateway (default: 10.30.20.1): ${RESET}"
    read -r GW_DMZ
    [[ -z "$GW_DMZ" ]] && GW_DMZ="10.30.20.1"

    local BR_INT="br_${NET_INT}"
    local BR_DMZ="br_${NET_DMZ}"

    # Internal network: isolated (no internet, only internal pivot)
    if ! create_lab_net_generic "$NET_INT" "$BR_INT" "$GW_INT" "none"; then
        echo -e "${FAIL} Failed to create internal network for pivot LAB.${RESET}"
        return
    fi

    # DMZ network: with NAT to get out (can pivot later)
    if ! create_lab_net_generic "$NET_DMZ" "$BR_DMZ" "$GW_DMZ" "nat"; then
        echo -e "${FAIL} Failed to create DMZ network for pivot LAB.${RESET}"
        return
    fi

    echo
    echo -e "${INFO} Pivot LAB networks created:${RESET}"
    echo -e "  - Internal: ${NET_INT} (bridge ${BR_INT}, GW=${GW_INT}, no NAT)"
    echo -e "  - DMZ:      ${NET_DMZ} (bridge ${BR_DMZ}, GW=${GW_DMZ}, NAT enabled)"
    echo

    echo -ne "${CYAN} Do you want to connect any VM to the INTERNAL network (${NET_INT}) now (y/N)? ${RESET}"
    read -r ans_int
    if [[ "$ans_int" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${INFO} Selecting VMs for INTERNAL network '${NET_INT}'...${RESET}"
        # Wrapper should handle list + fzf/multi-select and call attach_vms_to_network
        attach_vms_to_network_wrapper "$NET_INT"
    fi

    echo -ne "${CYAN} Do you want to connect any VM to the DMZ network (${NET_DMZ}) now (y/N)?  ${RESET}"
    read -r ans_dmz
    if [[ "$ans_dmz" =~ ^[Yy]$ ]]; then
        echo
        echo -e "${INFO} Selecting VMs for DMZ network '${NET_DMZ}'...${RESET}"
        attach_vms_to_network_wrapper "$NET_DMZ"
    fi
}

#-----------------------------------------------------------
# Function: lab_isolar_vm_sandbox
# Module:   Labs
# Purpose:
#   Temporarily isolate a VM into a sandboxed network with
#   no direct Internet access (malware analysis, unsafe
#   testing, etc.).
#
# Inputs:
#   - VM selected by user.
#
# Outputs:
#   - VM reassigned to an isolated libvirt network.
#
# Notes:
#   - Typically reverts to original network after tests,
#     via other lab management functions.
#-----------------------------------------------------------

lab_isolar_vm_sandbox() {
    echo
    draw_menu_title "LAB: Isolate VM in SANDBOX (no internet)"
    #echo -e "${GREEN_TITLE}==== LAB: Isolate VM in SANDBOX (no internet) ====${RESET}"

    echo -ne "${CYAN} Libvirt network name (default: lab_sandbox): ${RESET}"
    read -r NET_NAME
    [[ -z "$NET_NAME" ]] && NET_NAME="lab_sandbox"

    echo -ne "${CYAN} Network gateway/host (default: 10.99.0.1): ${RESET}"
    read -r GW_IP
    [[ -z "$GW_IP" ]] && GW_IP="10.99.0.1"

    # Corresponding bridge name
    local BR_NAME="br_${NET_NAME}"

    # Create ISOLATED network (no NAT)
    if ! create_lab_net_generic "$NET_NAME" "$BR_NAME" "$GW_IP" "none"; then
        echo -e "${FAIL} Could not create the sandbox network.${RESET}"
        return
    fi

    echo
    echo -e "${INFO} Sandbox network '${NET_NAME}' is ready. VMs connected to it will NOT have internet.${RESET}"
    echo

    echo -e "${CYAN} Do you want to connect an existing VM to this sandbox network now? (y/N)${RESET}"
    read -r ans_vm
    if [[ "$ans_vm" =~ ^[Yy]$ ]]; then
        echo -e "${INFO} Available VMs (virsh list --all):${RESET}"
        virsh list --all
        echo
        echo -e "${CYAN} Target libvirt network for VMs:${RESET} ${NET_NAME}"
        # Reuse generic attach function (already existing)
        # It will ask for the VM names.
        attach_vms_to_network_wrapper "$NET_NAME"
    fi
}

#-----------------------------------------------------------
# Function: lab_create_dmz_web
# Module:   Labs
# Purpose:
#   Create a DMZ web lab with one or more web servers
#   placed in a DMZ network that is reachable from an
#   "external" side but segregated from internal segments.
#
# Inputs:
#   - Target VM(s) to act as web servers.
#   - DMZ network selection or creation via VM Networking.
#
# Outputs:
#   - DMZ network topology ready for web exposure tests.
#
# Notes:
#   - Often used in combination with traffic labs and
#     firewall/misconfiguration injections.
#-----------------------------------------------------------

lab_create_dmz_web() {
    echo ""
    echo -e "${CYAN}[ INFO ] Creating DMZ Web Lab using an existing VM...${RESET}"
    log_msg INFO "Creating DMZ Web Lab with existing VM (switch NIC network to dmz_web)"

    local NET_NAME="dmz_web"

    # 1) Ensure DMZ libvirt network exists (create if missing)
    if ! virsh net-info "$NET_NAME" &>/dev/null; then
        echo -e "${INFO} DMZ network '${NET_NAME}' does not exist. Creating...${RESET}"
        log_msg INFO "DMZ network '${NET_NAME}' does not exist, creating."

        cat > /tmp/dmz_web.xml <<EOF
<network>
  <name>${NET_NAME}</name>
  <bridge name="virbr-dmz-web"/>
  <forward mode="nat"/>
  <ip address="10.50.0.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.50.0.50" end="10.50.0.200"/>
    </dhcp>
  </ip>
</network>
EOF
        virsh net-define /tmp/dmz_web.xml >/dev/null 2>&1
        virsh net-autostart "$NET_NAME" >/dev/null 2>&1
        virsh net-start "$NET_NAME" >/dev/null 2>&1
        rm -f /tmp/dmz_web.xml
    else
        echo -e "${OK} DMZ network '${NET_NAME}' already exists.${RESET}"
    fi

    # Extra safety: make sure it's active
    ensure_libvirt_net "$NET_NAME"

    echo ""
    echo -e "${YELLOW}Available VMs (libvirt domains):${RESET}"
    echo ""

    local VM_LIST
    VM_LIST=$(virsh list --all --name | sed '/^$/d')

    if [[ -z "$VM_LIST" ]]; then
        echo -e "${FAIL} No VMs found in libvirt. Create a VM first using the VM management menu.${RESET}"
        log_msg WARN "No VMs available when trying to create DMZ Web Lab"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 1
    fi

    local VM_NAME=""

    # Try arrow-key selection with fzf
    if ensure_fzf; then
        VM_NAME=$(echo "$VM_LIST" | fzf --prompt="Select VM for DMZ Web Lab > " --height=12 --border --ansi)
        echo ""
    fi

    # Fallback: numeric selection / manual typing
    if [[ -z "$VM_NAME" ]]; then
        echo "$VM_LIST" | nl -w2 -s'. '
        echo ""
        read -rp "Enter the name of the VM to use as DMZ web server: " VM_NAME
    fi

    if [[ -z "$VM_NAME" ]]; then
        echo -e "${FAIL} No VM name provided.${RESET}"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 1
    fi

    # Validate VM
    if ! virsh dominfo "$VM_NAME" &>/dev/null; then
        echo -e "${FAIL} VM '${VM_NAME}' does not exist in libvirt.${RESET}"
        log_msg ERROR "VM ${VM_NAME} not found in lab_create_dmz_web"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 1
    fi

    # VM must be shut off to safely change NIC network
    local STATE
    STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$STATE" != "shut off" ]]; then
        echo -e "${FAIL} VM '${VM_NAME}' must be SHUT OFF to switch its NIC to the DMZ network.${RESET}"
        echo -e "${INFO} Power off the VM and run this option again.${RESET}"
        log_msg WARN "VM ${VM_NAME} not shut off when calling lab_create_dmz_web (state: ${STATE})"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 1
    fi

    echo ""
    echo -e "${INFO} Current interfaces for '${VM_NAME}':${RESET}"
    virsh domiflist "$VM_NAME" 2>/dev/null || {
        echo -e "${FAIL} Could not list interfaces for this VM.${RESET}"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 1
    }
    echo ""

    # Get the first NIC (main interface)
    local MAIN_MAC MAIN_SRC MAIN_IF
    MAIN_MAC=$(virsh domiflist "$VM_NAME" | awk 'NR==3 {print $5}')
    MAIN_SRC=$(virsh domiflist "$VM_NAME" | awk 'NR==3 {print $3}')
    MAIN_IF=$(virsh domiflist "$VM_NAME" | awk 'NR==3 {print $1}')

    if [[ -z "$MAIN_MAC" || -z "$MAIN_SRC" ]]; then
        echo -e "${FAIL} Could not detect main NIC for '${VM_NAME}'.${RESET}"
        log_msg ERROR "Failed to detect main NIC for ${VM_NAME} in lab_create_dmz_web"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 1
    fi

    if [[ "$MAIN_SRC" == "$NET_NAME" ]]; then
        echo -e "${WARN} Main NIC of VM '${VM_NAME}' is already attached to '${NET_NAME}'.${RESET}"
        log_msg WARN "Main NIC of ${VM_NAME} already on ${NET_NAME}"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 0
    fi

    echo -e "${INFO} Main NIC: interface=${MAIN_IF}, MAC=${MAIN_MAC}, current network=${MAIN_SRC}${RESET}"
    echo -e "${YELLOW} This operation will move the main NIC from '${MAIN_SRC}' to '${NET_NAME}'.${RESET}"
    read -rp "Continue? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${WARN} Operation canceled by user.${RESET}"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 0
    fi

    # Detach NIC from old network
    echo -e "${INFO} Detaching main NIC from network '${MAIN_SRC}'...${RESET}"
    log_msg INFO "Detaching NIC MAC=${MAIN_MAC} from network ${MAIN_SRC} (VM=${VM_NAME})"

    if ! virsh detach-interface \
        --domain "$VM_NAME" \
        --type network \
        --mac "$MAIN_MAC" \
        --config \
        >/dev/null 2>&1
    then
        echo -e "${FAIL} Failed to detach NIC from old network.${RESET}"
        log_msg ERROR "Failed to detach NIC MAC=${MAIN_MAC} from ${VM_NAME}"
        read -n1 -s -r -p "Press any key to return to the labs menu..."
        echo ""
        return 1
    fi

    # Attach NIC with same MAC to dmz_web
    echo -e "${INFO} Attaching main NIC to DMZ network '${NET_NAME}'...${RESET}"
    log_msg INFO "Attaching NIC MAC=${MAIN_MAC} of VM=${VM_NAME} to network ${NET_NAME}"

    if virsh attach-interface \
        --domain "$VM_NAME" \
        --type network \
        --source "$NET_NAME" \
        --model virtio \
        --mac "$MAIN_MAC" \
        --config \
        >/dev/null 2>&1
    then
        echo -e "${OK} Main NIC successfully moved to DMZ network '${NET_NAME}'.${RESET}"
        echo -e "${YELLOW}Start the VM to see the DMZ NIC in Virt-Manager with the new network.${RESET}"
        log_msg INFO "Successfully switched NIC MAC=${MAIN_MAC} of VM=${VM_NAME} to ${NET_NAME}"
    else
        echo -e "${FAIL} Failed to attach NIC to DMZ network. VM might be left without a NIC.${RESET}"
        log_msg ERROR "Failed to attach NIC MAC=${MAIN_MAC} of VM=${VM_NAME} to ${NET_NAME}"
        echo -e "${WARN} You may need to manually re-add a NIC via Virt-Manager or XML.${RESET}"
    fi

    echo ""
    echo -e "${INFO} Updated interfaces for '${VM_NAME}':${RESET}"
    virsh domiflist "$VM_NAME" 2>/dev/null || true
    echo ""

    echo -e "${OK} DMZ Web Lab is ready. VM '${VM_NAME}' now uses the DMZ network as its main NIC.${RESET}"
    echo ""
    read -n1 -s -r -p "Press any key to return to the labs menu..."
    echo ""
}

#-----------------------------------------------------------
# Function: lab_sniff_interface
# Module:   Labs
# Purpose:
#   Launch sniffing tools (tcpdump, Wireshark, tshark, etc.)
#   on a specific interface or bridge connected to lab
#   networks to capture traffic for analysis.
#
# Inputs:
#   - Interface selected by user (e.g. br0, vnetX, virbrX).
#
# Outputs:
#   - Runs a live capture or starts a background pcap.
#
# Notes:
#   - Might require root and presence of sniff tools.
#-----------------------------------------------------------

lab_sniff_interface() {
    echo ""
    echo -e "${CYAN}[ INFO ] Network Sniffer Module${RESET}"
    echo ""

    # Build interface list
    local IF_LIST
    IF_LIST=$(ip -o link show | awk -F': ' '{print $2}' | sed '/^$/d')

    if [[ -z "$IF_LIST" ]]; then
        echo -e "${FAIL} No network interfaces found.${RESET}"
        return 1
    fi

    local SNIFF_IF=""

    # Try arrow-key selection with fzf
    if ensure_fzf; then
        echo -e "${YELLOW} Select interface using arrow keys and press Enter:${RESET}"
        echo ""
        SNIFF_IF=$(echo "$IF_LIST" | fzf --prompt="Interface > " --height=12 --border --ansi)
        echo ""
    fi

    # Fallback if user did not install fzf or selection failed
    if [[ -z "$SNIFF_IF" ]]; then
        echo -e "${YELLOW} Available interfaces:${RESET}"
        echo "$IF_LIST" | nl -w2 -s'. '
        echo ""
        read -rp "Enter interface to sniff: " SNIFF_IF
    fi

    if [[ -z "$SNIFF_IF" ]]; then
        echo -e "${FAIL} No interface provided.${RESET}"
        return 1
    fi

    # Validate interface
    if ! ip link show "$SNIFF_IF" &>/dev/null; then
        echo -e "${FAIL} Interface '$SNIFF_IF' does not exist.${RESET}"
        return 1
    fi

    # Check if tcpdump is installed
    if ! command -v tcpdump >/dev/null 2>&1; then
        echo -e "${WARN} 'tcpdump' is not installed on this system.${RESET}"

        if command -v apt-get >/dev/null 2>&1; then
            read -rp "Install tcpdump now using apt-get? [Y/n]: " INSTALL_TCPDUMP
            INSTALL_TCPDUMP=${INSTALL_TCPDUMP:-Y}

            if [[ "$INSTALL_TCPDUMP" =~ ^[Yy]$ ]]; then
                echo -e "${INFO} Installing tcpdump...${RESET}"
                log_msg INFO "Installing tcpdump package from lab_sniff_interface"

                apt-get update -y >/dev/null 2>&1
                apt-get install -y tcpdump >/dev/null 2>&1

                if ! command -v tcpdump >/dev/null 2>&1; then
                    echo -e "${FAIL} tcpdump installation failed. Aborting sniffer module.${RESET}"
                    log_msg ERROR "tcpdump installation failed in lab_sniff_interface"
                    read -n1 -s -r -p "Press any key to return to the labs menu..."
                    echo ""
                    return 1
                fi
            else
                echo -e "${WARN} User chose not to install tcpdump. Aborting sniffer module.${RESET}"
                read -n1 -s -r -p "Press any key to return to the labs menu..."
                echo ""
                return 1
            fi
        else
            echo -e "${FAIL} Package manager 'apt-get' not found. Please install tcpdump manually.${RESET}"
            read -n1 -s -r -p "Press any key to return to the labs menu..."
            echo ""
            return 1
        fi
    fi

    echo ""
    echo -e "${YELLOW}Optional tcpdump extra options / filter:${RESET}"
    echo -e "Examples:"
    echo -e "  port 80"
    echo -e "  host 10.0.0.5"
    echo -e "  port 53 and udp"
    echo -e "  -A port 80      (show HTTP payload in ASCII)"
    echo -e "Leave empty for default: -nn -vv (all traffic on interface)"
    echo ""
    read -rp "Enter extra options/filter (or press Enter for default): " TCPDUMP_EXTRA

    echo ""
    echo -e "${INFO} Starting sniffing on '${SNIFF_IF}'... (press Ctrl+C to stop)${RESET}"
    log_msg INFO "Sniffing interface '${SNIFF_IF}' with tcpdump (extra: ${TCPDUMP_EXTRA})"

    if [[ -n "$TCPDUMP_EXTRA" ]]; then
        tcpdump -i "$SNIFF_IF" -nn -vv ${TCPDUMP_EXTRA}
    else
        tcpdump -i "$SNIFF_IF" -nn -vv
    fi

    echo ""
    read -n1 -s -r -p "Press any key to return to the labs menu..."
    echo ""
}

#-----------------------------------------------------------
# Function: lab_network_perf
# Module:   Labs
# Purpose:
#   Perform network performance tests (throughput, latency)
#   between lab VMs using tools such as iperf/iperf3.
#
# Inputs:
#   - Source and target VMs.
#   - Optional parameters (port, protocol, duration).
#
# Outputs:
#   - Displayed test results in the terminal.
#
# Notes:
#   - Useful to validate lab topology and performance
#     tuning (MTU, offloading, etc.).
#-----------------------------------------------------------

lab_network_perf() {
    echo ""
    draw_menu_title "LAB: NETWORK PERFORMANCE TEST (iperf3) "
    #echo -e "${GREEN_TITLE}==== LAB: NETWORK PERFORMANCE TEST (iperf3) ====${RESET}"
    echo ""

    # Check for iperf3
    if ! command -v iperf3 >/dev/null 2>&1; then
        echo -e "${WARN} iperf3 is not installed on the host.${RESET}"
        read -r -p "Do you want to install iperf3 now? (y/N): " inst_ipf
        if [[ "$inst_ipf" =~ ^[Yy]$ ]]; then
            echo -e "${INFO} Installing iperf3...${RESET}"
            if apt-get update -y >/dev/null 2>&1 && apt-get install -y iperf3 >/dev/null 2>&1; then
                echo -e "${OK} iperf3 installed successfully.${RESET}"
            else
                echo -e "${FAIL} Failed to install iperf3. Aborting lab_network_perf.${RESET}"
                return 1
            fi
        else
            echo -e "${FAIL} iperf3 is required for this lab. Aborting.${RESET}"
            return 1
        fi
    fi

    # Select target VM
    echo -e "${CYAN} Select the target VM for the performance test:${RESET}"
    local VM_NAME
    VM_NAME=$(hnm_select_vm) || { echo -e "${WARN}Operation canceled.${RESET}"; return 1; }

    # Detect or ask for IP
    echo -e "${INFO} Attempting to detect IP address for VM ${VM_NAME}...${RESET}"
    local VM_IP
    VM_IP="$(vm_guess_ip "$VM_NAME")"

    if [[ -n "$VM_IP" ]]; then
        echo -e "${OK}Detected IP: ${VM_IP}${RESET}"
    else
        echo -e "${WARN} Could not detect IP automatically.${RESET}"
        read -r -p "Enter VM IP manually (or Enter to cancel): " VM_IP
        VM_IP=$(echo "$VM_IP" | xargs)
        [[ -z "$VM_IP" ]] && { echo -e "${WARN} No IP provided. Aborting.${RESET}"; return 1; }
    fi

    # Basic iperf3 settings
    echo -e "${CYAN} Test duration in seconds (default: 10):${RESET}"
    read -r IPERF_TIME
    [[ -z "$IPERF_TIME" ]] && IPERF_TIME=10

    echo -e "${CYAN} Number of parallel streams (default: 1):${RESET}"
    read -r IPERF_PAR
    [[ -z "$IPERF_PAR" ]] && IPERF_PAR=1

    local MODE_MENU MODE_SEL MODE_OPT
    MODE_MENU=$(
        cat <<EOF
1) Start iperf3 server on VM via SSH, then run client on host
2) Assume iperf3 server is already running on VM (port 5201)
0) Cancel
EOF
    )

    if ensure_fzf; then
        MODE_SEL=$(hnm_select "Select iperf3 mode" "$MODE_MENU") || {
            echo -e "${WARN}Operation canceled.${RESET}"
            return 1
        }
        MODE_OPT=$(echo "$MODE_SEL" | awk '{print $1}' | tr -d ')')
    else
        echo -e "${CYAN} Select iperf3 mode:${RESET}"
        echo "1) Start iperf3 server on VM via SSH, then run client on host"
        echo "2) Assume iperf3 server is already running on VM (port 5201)"
        echo "0) Cancel"
        flush_stdin
        read -r -p "Choice: " MODE_OPT
    fi

    case "$MODE_OPT" in
        1)
            echo -e "${CYAN} SSH user to start iperf3 server on VM (default: ${USER}):${RESET}"
            read -r SSH_USER
            [[ -z "$SSH_USER" ]] && SSH_USER="$USER"
            local SSH_TARGET="${SSH_USER}@${VM_IP}"

            echo -e "${INFO} Starting iperf3 server on VM (${SSH_TARGET})...${RESET}"
            ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" \
                "nohup iperf3 -s >/dev/null 2>&1 &" \
                >/dev/null 2>&1

            echo -e "${INFO} Running iperf3 client from host to ${VM_IP}...${RESET}"
            echo ""
            iperf3 -c "$VM_IP" -t "$IPERF_TIME" -P "$IPERF_PAR"
            local rc=$?

            if [[ $rc -ne 0 ]]; then
                echo -e "${FAIL} iperf3 client exited with error code ${rc}.${RESET}"
            else
                echo -e "${OK} iperf3 test completed successfully.${RESET}"
            fi
            ;;
        2)
            echo -e "${INFO} Assuming iperf3 server is already running on ${VM_IP}:5201...${RESET}"
            echo -e "${INFO} Running iperf3 client from host...${RESET}"
            echo ""
            iperf3 -c "$VM_IP" -t "$IPERF_TIME" -P "$IPERF_PAR"
            local rc2=$?
            if [[ $rc2 -ne 0 ]]; then
                echo -e "${FAIL} iperf3 client exited with error code ${rc2}.${RESET}"
            else
                echo -e "${OK} iperf3 test completed successfully.${RESET}"
            fi
            ;;
        0|"")
            echo -e "${INFO} Operation canceled.${RESET}"
            return 0
            ;;
        *)
            echo -e "${FAIL} Invalid option. Aborting.${RESET}"
            return 1
            ;;
    esac

    log_msg INFO "lab_network_perf executed for VM=${VM_NAME}, IP=${VM_IP}, time=${IPERF_TIME}s, parallel=${IPERF_PAR}, mode=${MODE_OPT}"
}

#-----------------------------------------------------------
# Function: lab_block_internet_all
# Module:   Labs
# Purpose:
#   Apply firewall or routing rules to globally block
#   Internet access for all lab networks or a subset
#   of them.
#
# Inputs:
#   - Target networks or default "all lab networks".
#
# Outputs:
#   - Enforcement of iptables/nftables rules on host.
#
# Notes:
#   - Typically reversible using lab_allow_internet_some
#     or dedicated cleanup functions.
#-----------------------------------------------------------

lab_block_internet_all() {
    echo ""
    #echo -e "${GREEN_TITLE}==== LAB: BLOCK / UNBLOCK INTERNET FOR ALL VMs ====${RESET}"
    echo ""
    draw_menu_title "LAB: BLOCK / UNBLOCK INTERNET FOR ALL VMs"
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${FAIL} iptables command not found. This lab requires iptables.${RESET}"
        echo -e "${WARN} If you are using nftables only, this function must be adapted manually.${RESET}"
        return 1
    fi

    # Build WAN interface list (interfaces with global IPv4, excluding lo)
    local IF_LIST IF_MENU IF_SEL WAN_IF
    IF_LIST=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | sort -u | grep -v '^lo$' || true)

    if [[ -z "$IF_LIST" ]]; then
        echo -e "${FAIL} Could not detect any global IPv4 interfaces (WAN candidates).${RESET}"
        return 1
    fi

    IF_MENU=""
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local addr
        addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}')
        IF_MENU+="${iface}  (${addr})"$'\n'
    done <<< "$IF_LIST"

    echo -e "${CYAN} Select the WAN interface that provides Internet for your VMs:${RESET}"
    if ensure_fzf; then
        IF_SEL=$(hnm_select "WAN interface for Internet blocking" "$IF_MENU") || {
            echo -e "${WARN} Operation canceled.${RESET}"
            return 1
        }
        WAN_IF=$(echo "$IF_SEL" | awk '{print $1}')
    else
        echo "$IF_MENU"
        read -r -p "Type the WAN interface name (or Enter to cancel): " WAN_IF
        WAN_IF=$(echo "$WAN_IF" | xargs)
        [[ -z "$WAN_IF" ]] && { echo -e "${WARN} Operation canceled.${RESET}"; return 1; }
    fi

    echo ""
    echo -e "${INFO} Selected WAN interface: ${WAN_IF}${RESET}"
    echo ""

    # Menu: block or unblock
    local ACTION_MENU ACTION_SEL ACTION_OPT
    ACTION_MENU=$(
        cat <<EOF
1) Enable Internet block for all VM traffic (FORWARD via ${WAN_IF})
2) Disable Internet block (remove rules)
0) Cancel
EOF
    )

    if ensure_fzf; then
        ACTION_SEL=$(hnm_select "Select action for Internet blocking" "$ACTION_MENU") || {
            echo -e "${WARN} Operation canceled.${RESET}"
            return 1
        }
        ACTION_OPT=$(echo "$ACTION_SEL" | awk '{print $1}' | tr -d ')')
    else
        echo -e "${CYAN} Select action:${RESET}"
        echo "1) Enable Internet block for all VM traffic"
        echo "2) Disable Internet block"
        echo "0) Cancel"
        flush_stdin
        read -r -p "Choice: " ACTION_OPT
    fi

    case "$ACTION_OPT" in
        1)
            # Add FORWARD drop rule with comment, if not present
            if iptables -C FORWARD -o "$WAN_IF" -m comment --comment "HNM_LAB_BLOCK_INTERNET" -j DROP 2>/dev/null; then
                echo -e "${WARN} Internet block rule is already active for interface ${WAN_IF}.${RESET}"
            else
                echo -e "${INFO} Adding Internet block rule on FORWARD via ${WAN_IF}...${RESET}"
                if iptables -I FORWARD 1 -o "$WAN_IF" -m comment --comment "HNM_LAB_BLOCK_INTERNET" -j DROP; then
                    echo -e "${OK} Internet access for VMs (forwarded via ${WAN_IF}) is now BLOCKED.${RESET}"
                    log_msg WARN "lab_block_internet_all: Internet blocked for VMs via ${WAN_IF}."
                else
                    echo -e "${FAIL} Failed to add block rule on FORWARD via ${WAN_IF}.${RESET}"
                fi
            fi
            ;;
        2)
            echo -e "${INFO} Removing Internet block rules (if present) on FORWARD via ${WAN_IF}...${RESET}"
            # Try to delete until no more rules match
            while iptables -C FORWARD -o "$WAN_IF" -m comment --comment "HNM_LAB_BLOCK_INTERNET" -j DROP 2>/dev/null; do
                iptables -D FORWARD -o "$WAN_IF" -m comment --comment "HNM_LAB_BLOCK_INTERNET" -j DROP 2>/dev/null || break
            done
            echo -e "${OK} Internet block rules removed (if any existed).${RESET}"
            log_msg INFO "lab_block_internet_all: Internet unblocked for VMs via ${WAN_IF}."
            ;;
        0|"")
            echo -e "${INFO} Operation canceled.${RESET}"
            ;;
        *)
            echo -e "${FAIL} Invalid option. No changes applied.${RESET}"
            ;;
    esac
}

#-----------------------------------------------------------
# Function: lab_allow_internet_some
# Module:   Labs
# Purpose:
#   Allow Internet access only to a subset of lab networks
#   while keeping others isolated, by adjusting firewall
#   or forwarding rules.
#
# Inputs:
#   - Networks selected as "allowed to go out".
#
# Outputs:
#   - Updated firewall rules.
#
# Notes:
#   - Complements lab_block_internet_all. Used to emulate
#     segmented environments with partial Internet access.
#-----------------------------------------------------------

lab_allow_internet_some() {
    echo ""
    draw_menu_title "LAB: ALLOW INTERNET FOR SELECTED VMs (EXCEPTIONS)"
    #echo -e "${GREEN_TITLE}==== LAB: ALLOW INTERNET FOR SELECTED VMs (EXCEPTIONS) ====${RESET}"
    echo ""

    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${FAIL} iptables command not found. This lab requires iptables.${RESET}"
        echo -e "${WARN} If you are using nftables only, this function must be adapted manually.${RESET}"
        return 1
    fi

    # Build WAN interface list (interfaces with global IPv4, excluding lo)
    local IF_LIST IF_MENU IF_SEL WAN_IF
    IF_LIST=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $2}' | sort -u | grep -v '^lo$' || true)

    if [[ -z "$IF_LIST" ]]; then
        echo -e "${FAIL} Could not detect any global IPv4 interfaces (WAN candidates).${RESET}"
        return 1
    fi

    IF_MENU=""
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local addr
        addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}')
        IF_MENU+="${iface}  (${addr})"$'\n'
    done <<< "$IF_LIST"

    echo -e "${CYAN} Select the WAN interface used for Internet (same used in lab_block_internet_all):${RESET}"
    if ensure_fzf; then
        IF_SEL=$(hnm_select "WAN interface for Internet exceptions" "$IF_MENU") || {
            echo -e "${WARN} Operation canceled.${RESET}"
            return 1
        }
        WAN_IF=$(echo "$IF_SEL" | awk '{print $1}')
    else
        echo "$IF_MENU"
        read -r -p "Type the WAN interface name (or Enter to cancel): " WAN_IF
        WAN_IF=$(echo "$WAN_IF" | xargs)
        [[ -z "$WAN_IF" ]] && { echo -e "${WARN} Operation canceled.${RESET}"; return 1; }
    fi

    echo ""
    echo -e "${INFO} Selected WAN interface: ${WAN_IF}${RESET}"
    echo ""

    # Menu: add or remove exceptions
    local ACTION_MENU ACTION_SEL ACTION_OPT
    ACTION_MENU=$(
        cat <<EOF
1) Add Internet allow exceptions for selected VMs
2) Remove existing Internet allow exceptions
0) Cancel
EOF
    )

    if ensure_fzf; then
        ACTION_SEL=$(hnm_select "Select action for Internet exceptions" "$ACTION_MENU") || {
            echo -e "${WARN} Operation canceled.${RESET}"
            return 1
        }
        ACTION_OPT=$(echo "$ACTION_SEL" | awk '{print $1}' | tr -d ')')
    else
        echo -e "${CYAN} Select action:${RESET}"
        echo "1) Add Internet allow exceptions for selected VMs"
        echo "2) Remove existing Internet allow exceptions"
        echo "0) Cancel"
        flush_stdin
        read -r -p "Choice: " ACTION_OPT
    fi

    case "$ACTION_OPT" in
        1)
            # Build VM list
            local ALL_VMS VM_SELECTION VM_LIST
            ALL_VMS=$(virsh list --all --name 2>/dev/null \
                | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | sed '/^$/d')

            if [[ -z "$ALL_VMS" ]]; then
                echo -e "${FAIL}No VMs found in libvirt.${RESET}"
                return 1
            fi

            if ensure_fzf; then
                echo -e "${YELLOW} Select one or more VMs to ALLOW Internet (TAB/SPACE to mark, Enter to confirm):${RESET}"
                echo ""
                VM_SELECTION=$(printf "%s\n" "$ALL_VMS" \
                    | fzf --multi --prompt="VMs > " --height=15 --border --ansi)
                echo ""
                VM_LIST=$(echo "$VM_SELECTION" | xargs -n1)
            fi

            if [[ -z "$VM_LIST" ]]; then
                echo -e "${YELLOW} Available VMs:${RESET}"
                virsh list --all 2>/dev/null | sed '1,2d'
                echo ""
                read -r -p "Enter VMs to allow Internet (space-separated, Enter to cancel): " VM_LIST
                VM_LIST=$(echo "$VM_LIST" | xargs)
            fi

            [[ -z "$VM_LIST" ]] && { echo -e "${WARN} No VMs specified. Aborting.${RESET}"; return 1; }

            local ALLOWED=()
            for vm in $VM_LIST; do
                [[ -z "$vm" ]] && continue

                if ! virsh dominfo "$vm" >/dev/null 2>&1; then
                    echo -e "${FAIL} VM '${vm}' not found in libvirt.${RESET}"
                    continue
                fi

                echo -e "${INFO} Resolving IP for VM '${vm}'...${RESET}"
                local ip
                ip="$(vm_guess_ip "$vm")"
                if [[ -z "$ip" ]]; then
                    echo -e "${WARN} Could not auto-detect IP for ${vm}.${RESET}"
                    read -r -p "Enter IP manually for ${vm} (or Enter to skip): " ip
                    ip=$(echo "$ip" | xargs)
                    [[ -z "$ip" ]] && { echo -e "${WARN} Skipping VM ${vm} (no IP).${RESET}"; continue; }
                fi

                local COMMENT="HNM_LAB_ALLOW_INTERNET_${vm}"
                # Add ACCEPT rule before DROP
                if iptables -C FORWARD -s "$ip" -o "$WAN_IF" -m comment --comment "$COMMENT" -j ACCEPT 2>/dev/null; then
                    echo -e "${WARN} Allow rule already exists for ${vm} (${ip}).${RESET}"
                else
                    echo -e "${INFO} Adding allow rule for VM ${vm} (${ip}) via ${WAN_IF}...${RESET}"
                    if iptables -I FORWARD 1 -s "$ip" -o "$WAN_IF" -m comment --comment "$COMMENT" -j ACCEPT; then
                        echo -e "${OK} Internet allowed for VM ${vm} (${ip}).${RESET}"
                        log_msg INFO "lab_allow_internet_some: allow Internet for VM=${vm} IP=${ip} via ${WAN_IF}."
                        ALLOWED+=("${vm}:${ip}")
                    else
                        echo -e "${FAIL} Failed to add allow rule for VM ${vm} (${ip}).${RESET}"
                    fi
                fi
            done

            if ((${#ALLOWED[@]} > 0)); then
                echo ""
                echo -e "${CYAN} Internet allowed for the following VM(s):${RESET}"
                printf '  - %s\n' "${ALLOWED[@]}"
                echo ""
            fi
            ;;
        2)
            echo -e "${INFO} Searching for existing allow rules (HNM_LAB_ALLOW_INTERNET_*) on FORWARD via ${WAN_IF}...${RESET}"

            # Show current rules with line numbers
            local CURRENT
            CURRENT=$(iptables -L FORWARD --line-numbers 2>/dev/null | sed '1,2d' | grep "HNM_LAB_ALLOW_INTERNET_" || true)

            if [[ -z "$CURRENT" ]]; then
                echo -e "${WARN} No allow exception rules found for Internet.${RESET}"
                return 0
            fi

            echo ""
            echo -e "${INFO} Current Internet allow rules:${RESET}"
            echo "$CURRENT"
            echo ""
            read -r -p "Remove ALL allow rules? (y/N): " rm_all

            if [[ "$rm_all" =~ ^[Yy]$ ]]; then
                # Loop removing one rule at a time by line number
                while true; do
                    local NUM
                    NUM=$(iptables -L FORWARD --line-numbers 2>/dev/null \
                        | sed '1,2d' \
                        | grep "HNM_LAB_ALLOW_INTERNET_" \
                        | head -n1 \
                        | awk '{print $1}')
                    [[ -z "$NUM" ]] && break
                    iptables -D FORWARD "$NUM" 2>/dev/null || break
                done
                echo -e "${OK} All Internet allow exception rules removed (best-effort).${RESET}"
                log_msg INFO "lab_allow_internet_some: all allow rules removed."
            else
                echo -e "${INFO} No changes applied to allow rules.${RESET}"
            fi
            ;;
        0|"")
            echo -e "${INFO} Operation canceled.${RESET}"
            ;;
        *)
            echo -e "${FAIL} 
            Invalid option. No changes applied.${RESET}"
            ;;
    esac
}

#-----------------------------------------------------------
# Function: lab_snapshot_all
# Module:   Labs
# Purpose:
#   Take a consistent snapshot across a group of lab VMs
#   so that the whole lab can be rolled back later.
#
# Inputs:
#   - Group of VMs (selected by naming pattern, tags, or
#     explicit list).
#   - Snapshot name or auto-generated one.
#
# Outputs:
#   - A snapshot for each VM in the lab set.
#
# Notes:
#   - Uses virsh snapshot-* operations.
#   - Often paired with lab_rollback_all.
#-----------------------------------------------------------

lab_snapshot_all() {
    echo ""
    draw_menu_title "LAB: SNAPSHOT MULTIPLE VMs"
    #echo -e "${GREEN_TITLE}==== LAB: SNAPSHOT MULTIPLE VMs ====${RESET}"
    echo ""

    local ALL_VMS VM_SELECTION VM_LIST
    ALL_VMS=$(virsh list --all --name 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d')

    if [[ -z "$ALL_VMS" ]]; then
        echo -e "${FAIL} No VMs found in libvirt.${RESET}"
        return 1
    fi

    # Multi-select using fzf if available
    if ensure_fzf; then
        echo -e "${YELLOW} Select one or more VMs to snapshot (TAB/SPACE to mark, Enter to confirm).${RESET}"
        echo -e "${YELLOW} Leave selection empty to cancel.${RESET}"
        echo ""
        VM_SELECTION=$(printf "%s\n" "$ALL_VMS" \
            | fzf --multi --prompt="VMs > " --height=15 --border --ansi)
        echo ""
        VM_LIST=$(echo "$VM_SELECTION" | xargs -n1)
    fi

    # Fallback: ask if wants all or manual list
    if [[ -z "$VM_LIST" ]]; then
        echo -e "${YELLOW} No VMs selected via menu.${RESET}"
        echo -e "${CYAN} Use ALL VMs listed by libvirt? (y/N):${RESET}"
        read -r use_all
        if [[ "$use_all" =~ ^[Yy]$ ]]; then
            VM_LIST="$ALL_VMS"
        else
            echo -e "${CYAN} Enter VMs to snapshot (space-separated, Enter to cancel):${RESET}"
            read -r VM_LIST
            VM_LIST=$(echo "$VM_LIST" | xargs)
        fi
    fi

    [[ -z "$VM_LIST" ]] && { echo -e "${WARN} No VMs specified. Aborting lab_snapshot_all.${RESET}"; return 1; }

    # Snapshot base name
    local BASE_NAME
    echo -e "${CYAN} Snapshot base name prefix (default: lab_all):${RESET}"
    read -r BASE_NAME
    [[ -z "$BASE_NAME" ]] && BASE_NAME="lab_all"

    local TS
    TS="$(date +%Y%m%d_%H%M%S)"

    local SNAPSHOTS_CREATED=()

    for vm in $VM_LIST; do
        [[ -z "$vm" ]] && continue

        if ! virsh dominfo "$vm" >/dev/null 2>&1; then
            echo -e "${FAIL} VM '${vm}' not found in libvirt. Skipping.${RESET}"
            continue
        fi

        local SNAP_NAME="${BASE_NAME}_${vm}_${TS}"
        echo -e "${INFO} Creating snapshot '${SNAP_NAME}' for VM '${vm}'...${RESET}"
        if virsh snapshot-create-as "$vm" "$SNAP_NAME" >/dev/null 2>&1; then
            echo -e "${OK} Snapshot '${SNAP_NAME}' created for VM '${vm}'.${RESET}"
            log_msg INFO "lab_snapshot_all: snapshot ${SNAP_NAME} created for VM=${vm}."
            SNAPSHOTS_CREATED+=("${vm}:${SNAP_NAME}")
        else
            echo -e "${FAIL} Failed to create snapshot for VM '${vm}'.${RESET}"
            log_msg ERROR "lab_snapshot_all: failed to create snapshot for VM=${vm}."
        fi
    done

    if ((${#SNAPSHOTS_CREATED[@]} > 0)); then
        echo ""
        echo -e "${CYAN} Snapshots created:${RESET}"
        printf '  - %s\n' "${SNAPSHOTS_CREATED[@]}"
        echo ""
    else
        echo -e "${WARN} No snapshots were created.${RESET}"
    fi
}

#-----------------------------------------------------------
# Function: lab_rollback_all
# Module:   Labs
# Purpose:
#   Revert all VMs in a lab set to a previously created
#   snapshot, restoring the full lab state (AD, DMZ,
#   clients, pivot hosts, etc.).
#
# Inputs:
#   - Snapshot name (or list) to roll back to.
#
# Outputs:
#   - VMs reverted to previous state.
#
# Notes:
#   - WARNING: Discards all changes made after snapshot.
#   - Must be used with care in long-running labs.
#-----------------------------------------------------------

lab_rollback_all() {
    echo ""
    draw_menu_title "LAB: ROLLBACK MULTIPLE VMs (SNAPSHOT REVERT)"
    #echo -e "${GREEN_TITLE}==== LAB: ROLLBACK MULTIPLE VMs (SNAPSHOT REVERT) ====${RESET}"
    echo ""

    local ALL_VMS VM_SELECTION VM_LIST
    ALL_VMS=$(virsh list --all --name 2>/dev/null \
        | sed 's/^[[:space:]]//;s/[[:space:]]$//' \
        | sed '/^$/d')

    if [[ -z "$ALL_VMS" ]]; then
        echo -e "${FAIL} No VMs found in libvirt.${RESET}"
        return 1
    fi

    # Multi-select using fzf if available
    if ensure_fzf; then
        echo -e "${YELLOW} Select one or more VMs to ROLLBACK (TAB/SPACE to mark, Enter to confirm).${RESET}"
        echo -e "${YELLOW} Leave selection empty to cancel.${RESET}"
        echo ""
        VM_SELECTION=$(printf "%s\n" "$ALL_VMS" \
            | fzf --multi --prompt="VMs > " --height=15 --border --ansi)
        echo ""
        VM_LIST=$(echo "$VM_SELECTION" | xargs -n1)
    fi

    # Fallback: ask if wants all or manual list
    if [[ -z "$VM_LIST" ]]; then
        echo -e "${YELLOW} No VMs selected via menu.${RESET}"
        echo -e "${CYAN} Use ALL VMs listed by libvirt? (y/N):${RESET}"
        read -r use_all
        if [[ "$use_all" =~ ^[Yy]$ ]]; then
            VM_LIST="$ALL_VMS"
        else
            echo -e "${CYAN} Enter VMs to rollback (space-separated, Enter to cancel):${RESET}"
            read -r VM_LIST
            VM_LIST=$(echo "$VM_LIST" | xargs)
        fi
    fi

    [[ -z "$VM_LIST" ]] && { echo -e "${WARN} No VMs specified. Aborting lab_rollback_all.${RESET}"; return 1; }

    # Optional snapshot name prefix filter
    local PREFIX
    echo -e "${CYAN} Snapshot name prefix filter (optional, Enter for no filter):${RESET}"
    read -r PREFIX
    PREFIX=$(echo "$PREFIX" | xargs)

    local ROLLED_BACK=()

    for vm in $VM_LIST; do
        [[ -z "$vm" ]] && continue

        if ! virsh dominfo "$vm" >/dev/null 2>&1; then
            echo -e "${FAIL} VM '${vm}' not found in libvirt. Skipping.${RESET}"
            continue
        fi

        echo ""
        echo -e "${INFO} Listing snapshots for VM '${vm}'...${RESET}"

        # Get list of snapshots (name + creation time)
        local SNAP_LIST
        SNAP_LIST=$(virsh snapshot-list "$vm" 2>/dev/null | sed '1,2d' | sed '/^$/d') # header removed

        if [[ -z "$SNAP_LIST" ]]; then
            echo -e "${WARN} No snapshots found for VM '${vm}'. Skipping.${RESET}"
            continue
        fi

        # Build filtered list of snapshot names
        local SNAP_NAMES
        SNAP_NAMES=$(echo "$SNAP_LIST" | awk '{print $1}')
        if [[ -n "$PREFIX" ]]; then
            SNAP_NAMES=$(echo "$SNAP_NAMES" | grep "^${PREFIX}" || true)
            if [[ -z "$SNAP_NAMES" ]]; then
                echo -e "${WARN} No snapshots for VM '${vm}' match prefix '${PREFIX}'. Skipping.${RESET}"
                continue
            fi
        fi

        # If multiple snapshots, let user pick one
        local SNAP_NAME
        if echo "$SNAP_NAMES" | grep -q $'\n'; then
            # Build menu with name + rest of line
            local MENU_LINES SEL
            MENU_LINES=""
            while read -r sname; do
                [[ -z "$sname" ]] && continue
                local full_line
                full_line=$(echo "$SNAP_LIST" | awk -v n="$sname" '$1==n {print}')
                MENU_LINES+="${full_line}"$'\n'
            done <<< "$SNAP_NAMES"

            if ensure_fzf; then
                echo -e "${CYAN} Select snapshot to rollback for VM '${vm}':${RESET}"
                SEL=$(hnm_select "Snapshot for VM ${vm}" "$MENU_LINES") || {
                    echo -e "${WARN} No snapshot selected for VM '${vm}'. Skipping.${RESET}"
                    continue
                }
                SNAP_NAME=$(echo "$SEL" | awk '{print $1}')
            else
                echo -e "${CYAN} Available snapshots for VM '${vm}':${RESET}"
                echo "$SNAP_LIST"
                read -r -p "Snapshot name to rollback to (Enter to skip VM): " SNAP_NAME
                SNAP_NAME=$(echo "$SNAP_NAME" | xargs)
                [[ -z "$SNAP_NAME" ]] && { echo -e "${WARN} No snapshot chosen for '${vm}'. Skipping.${RESET}"; continue; }
            fi
        else
            # Only one snapshot
            SNAP_NAME="$SNAP_NAMES"
            echo -e "${INFO} Using only snapshot found for '${vm}': ${SNAP_NAME}.${RESET}"
        fi

        echo -e "${WARN} Reverting VM '${vm}' to snapshot '${SNAP_NAME}' is DESTRUCTIVE (state & disk).${RESET}"
        read -r -p "Confirm rollback for VM '${vm}'? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${INFO} Rollback canceled for VM '${vm}'.${RESET}"
            continue
        fi

        if virsh snapshot-revert "$vm" "$SNAP_NAME" >/dev/null 2>&1; then
            echo -e "${OK} VM '${vm}' reverted to snapshot '${SNAP_NAME}'.${RESET}"
            log_msg WARN "lab_rollback_all: VM=${vm} reverted to snapshot ${SNAP_NAME}."
            ROLLED_BACK+=("${vm}:${SNAP_NAME}")
        else
            echo -e "${FAIL} Failed to revert VM '${vm}' to snapshot '${SNAP_NAME}'.${RESET}"
            log_msg ERROR "lab_rollback_all: failed to revert VM=${vm} to snapshot ${SNAP_NAME}."
        fi
    done

    if ((${#ROLLED_BACK[@]} > 0)); then
        echo ""
        echo -e "${CYAN} Rollback completed for the following VM(s):${RESET}"
        printf '  - %s\n' "${ROLLED_BACK[@]}"
        echo ""
    else
        echo -e "${WARN} No VMs were reverted.${RESET}"
    fi
}

#-----------------------------------------------------------
# Function: lab_inject_misconfigs
# Module:   Labs
# Purpose:
#   Intentionally inject network or system misconfigurations
#   into lab VMs or lab networks to simulate real-world
#   issues (wrong DNS, bad gateway, missing routes, etc.).
#
# Inputs:
#   - Type of misconfiguration (menu selection).
#   - Target VMs or networks.
#
# Outputs:
#   - Applied misconfigurations reported to user.
#
# Notes:
#   - Often used together with lab_connectivity_tests to
#     demonstrate troubleshooting workflows.
#-----------------------------------------------------------

lab_inject_misconfigs() {
    echo ""
    draw_menu_title "LAB: INJECT NETWORK MISCONFIGURATIONS"
    #echo -e "${GREEN_TITLE}==== LAB: INJECT NETWORK MISCONFIGURATIONS ====${RESET}"
    echo ""

    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${FAIL} iptables command not found. This lab requires iptables.${RESET}"
        echo -e "${WARN} If you are using nftables only, this function must be adapted manually.${RESET}"
        return 1
    fi

    # High-level menu
    local ACTION_MENU ACTION_SEL ACTION_OPT
    ACTION_MENU=$(
        cat <<EOF
1) Break DNS for selected VMs (block port 53 to Internet)
2) Break Web for selected VMs (block ports 80/443 to Internet)
3) Remove all injected misconfiguration rules
0) Cancel
EOF
    )

    if ensure_fzf; then
        ACTION_SEL=$(hnm_select "Select misconfiguration to inject" "$ACTION_MENU") || {
            echo -e "${WARN} Operation canceled.${RESET}"
            return 1
        }
        ACTION_OPT=$(echo "$ACTION_SEL" | awk '{print $1}' | tr -d ')')
    else
        echo -e "${CYAN} Select action:${RESET}"
        echo "1) Break DNS for selected VMs"
        echo "2) Break Web for selected VMs"
        echo "3) Remove all injected misconfig rules"
        echo "0) Cancel"
        flush_stdin
        read -r -p "Choice: " ACTION_OPT
    fi
}

#-----------------------------------------------------------
# Function: lab_show_topology
# Module:   Labs
# Purpose:
#   Display an overview of the current lab topology: which
#   VMs are connected to which networks, and how those
#   networks relate to host interfaces/bridges.
#
# Inputs:
#   - None (reads from libvirt and ip / nmcli).
#
# Outputs:
#   - ASCII diagram or tabular summary.
#
# Notes:
#   - Purely informational; no configuration changes.
#-----------------------------------------------------------

lab_show_topology() {
    echo ""
    draw_menu_title "LAB: SHOW VIRTUAL NETWORK TOPOLOGY"
    #echo -e "${GREEN_TITLE}==== LAB: SHOW VIRTUAL NETWORK TOPOLOGY ====${RESET}"
    echo ""

    local MODE_MENU MODE_SEL MODE_OPT
    MODE_MENU=$(
        cat <<EOF
1) Show topology by libvirt network
2) Show topology by VM
0) Back
EOF
    )

    if ensure_fzf; then
        MODE_SEL=$(hnm_select "Select topology view mode" "$MODE_MENU") || {
            echo -e "${WARN} Operation canceled.${RESET}"
            return 0
        }
        MODE_OPT=$(echo "$MODE_SEL" | awk '{print $1}' | tr -d ')')
    else
        echo -e "${CYAN} Select mode:${RESET}"
        echo "1) By libvirt network"
        echo "2) By VM"
        echo "0) Back"
        flush_stdin
        read -r -p "Choice: " MODE_OPT
    fi

    case "$MODE_OPT" in
        1)
            # List networks with basic info and let user pick one
            local NETS NET_MENU NET_SEL NET_NAME
            NETS=$(virsh net-list --all --name 2>/dev/null | sed '/^$/d') || true
            if [[ -z "$NETS" ]]; then
                echo -e "${FAIL} No libvirt networks found.${RESET}"
                return 1
            fi

            NET_MENU=""
            while IFS= read -r n; do
                [[ -z "$n" ]] && continue
                local state bridge gw mode
                state=$(virsh net-info "$n" 2>/dev/null | awk -F': *' '/Active/ {print $2}')
                bridge=$(virsh net-dumpxml "$n" 2>/dev/null | awk -F"'" '/<bridge /{print $2; exit}')
                gw=$(virsh net-dumpxml "$n" 2>/dev/null | awk -F"'" '/<ip address=/{print $2; exit}')
                mode=$(virsh net-dumpxml "$n" 2>/dev/null | awk -F"'" '/<forward /{print $2; exit}')
                [[ -z "$mode" ]] && mode="isolated"
                NET_MENU+="${n}  [state:${state:-unknown}]  bridge:${bridge:-?}  gw:${gw:-?}  mode:${mode}"$'\n'
            done <<< "$NETS"

            echo -e "${CYAN} Select a libvirt network to inspect:${RESET}"
            if ensure_fzf; then
                NET_SEL=$(hnm_select "Libvirt network" "$NET_MENU") || {
                    echo -e "${WARN} Operation canceled.${RESET}"
                    return 0
                }
                NET_NAME=$(echo "$NET_SEL" | awk '{print $1}')
            else
                echo "$NET_MENU"
                read -r -p "Network name (or Enter to cancel): " NET_NAME
                NET_NAME=$(echo "$NET_NAME" | xargs)
                [[ -z "$NET_NAME" ]] && { echo -e "${WARN} Operation canceled.${RESET}"; return 0; }
            fi

            local state bridge gw mode
            state=$(virsh net-info "$NET_NAME" 2>/dev/null | awk -F': *' '/Active/ {print $2}')
            bridge=$(virsh net-dumpxml "$NET_NAME" 2>/dev/null | awk -F"'" '/<bridge /{print $2; exit}')
            gw=$(virsh net-dumpxml "$NET_NAME" 2>/dev/null | awk -F"'" '/<ip address=/{print $2; exit}')
            mode=$(virsh net-dumpxml "$NET_NAME" 2>/dev/null | awk -F"'" '/<forward /{print $2; exit}')
            [[ -z "$mode" ]] && mode="isolated"

            echo ""
            echo -e "${CYAN} Network: ${NET_NAME}${RESET}"
            echo -e "  State : ${state:-unknown}"
            echo -e "  Bridge: ${bridge:-?}"
            echo -e "  GW    : ${gw:-?}"
            echo -e "  Mode  : ${mode}"
            echo ""

            echo -e "${CYAN} VMs attached to network '${NET_NAME}':${RESET}"
            local ANY_VM=false
            local vm
            for vm in $(virsh list --all --name 2>/dev/null | sed '/^$/d'); do
                local line
                line=$(virsh domiflist "$vm" 2>/dev/null | awk -v n="$NET_NAME" '$2=="network" && $3==n {print $0}')
                [[ -z "$line" ]] && continue
                ANY_VM=true
                # Interface Type Source Model MAC
                echo "  VM: ${vm}"
                echo "$line" | while read -r ifname type source model mac; do
                    echo "    - if: ${ifname}, type: ${type}, source: ${source}, model: ${model}, MAC: ${mac}"
                done
            done
	    echo ""
            read -rp "Press ENTER to return..." _

            if [[ "$ANY_VM" == false ]]; then
                echo "  (no VMs attached)"
            fi

            echo ""
            ;;
            
        2)
            # By VM
            local VM_NAME
            echo -e "${CYAN} Select VM to inspect topology:${RESET}"
            VM_NAME=$(hnm_select_vm) || { echo -e "${WARN} Operation canceled.${RESET}"; return 0; }

            local STATE
            STATE=$(virsh domstate "$VM_NAME" 2>/dev/null)
            echo ""
            echo -e "${CYAN} VM: ${VM_NAME}${RESET}"
            echo -e "  State: ${STATE:-unknown}"

            # Basic info
            local vcpus mem
            vcpus=$(virsh dominfo "$VM_NAME" 2>/dev/null | awk -F': *' '/CPU.s/ {print $2}')
            mem=$(virsh dominfo "$VM_NAME" 2>/dev/null | awk -F': *' '/Max memory/ {print $2}')
            echo -e "  vCPUs: ${vcpus:-?}"
            echo -e "  Memory: ${mem:-?}"
            echo ""

            echo -e "${CYAN} Network interfaces:${RESET}"
            virsh domiflist "$VM_NAME" 2>/dev/null | sed '1,2d' | sed '/^$/d' \
                | while read -r ifname type source model mac; do
                    echo "  - if: ${ifname}"
                    echo "      type  : ${type}"
                    echo "      source: ${source}"
                    echo "      model : ${model}"
                    echo "      MAC   : ${mac}"
                done

            echo ""
            echo -e "${CYAN} Guessed IP addresses (if vm_guess_ip supports it):${RESET}"
            local IP_GUESS
            IP_GUESS=$(vm_guess_ip "$VM_NAME" 2>/dev/null)
            if [[ -n "$IP_GUESS" ]]; then
                echo "  - ${IP_GUESS}"
            else
                echo "  (no IP detected by vm_guess_ip)"
            fi
            echo ""
            read -rp "Press ENTER to return..." _
            ;;
        0|"")
            echo -e "${INFO} Returning from topology menu.${RESET}"
            ;;
        *)
            echo -e "${FAIL} Invalid option.${RESET}"
            ;;
    esac
}

#-----------------------------------------------------------
# Function: lab_create_ad_corp
# Module:   Labs
# Purpose:
#   Create or configure a corporate-style AD environment:
#   domain controller, member servers, and client machines,
#   all attached to AD lab networks created earlier.
#
# Inputs:
#   - VM templates or base images.
#   - Domain settings (FQDN, NETBIOS name, etc.).
#
# Outputs:
#   - A set of VMs with roles assigned (DC, member, client).
#
# Notes:
#   - Builds on create_ad_net and generic VM functions.
#-----------------------------------------------------------

lab_create_ad_corp() {
    echo -e "${INFO} Creating corporate AD LAB (DC + Server + Workstation)...${RESET}"

    # === AD LAB DEFAULT NETWORK SETTINGS ===
    # DC  -> 10.10.1.1/24  (bridge br_ad_dc)
    # SRV -> 10.10.2.1/24  (bridge br_ad_srv)
    # WS  -> 10.10.3.1/24  (bridge br_ad_ws)

    local DC_NET_NAME_DEFAULT="ad_corp_dc"
    local SRV_NET_NAME_DEFAULT="ad_corp_srv"
    local WS_NET_NAME_DEFAULT="ad_corp_ws"

    local DC_BR_DEFAULT="br_ad_dc"
    local SRV_BR_DEFAULT="br_ad_srv"
    local WS_BR_DEFAULT="br_ad_ws"

    local DC_IP_DEFAULT="10.10.1.1"
    local SRV_IP_DEFAULT="10.10.2.1"
    local WS_IP_DEFAULT="10.10.3.1"

    # === PERFIL RÁPIDO (SILENCIOSO) ===
    echo
    read -r -p "Use QUICK profile with default AD LAB networks? (Y/n): " quick
    if [[ -z "$quick" || "$quick" =~ ^[Yy]$ ]]; then
        # usa todos os defaults sem perguntar mais nada
        local DC_NET_NAME="$DC_NET_NAME_DEFAULT"
        local SRV_NET_NAME="$SRV_NET_NAME_DEFAULT"
        local WS_NET_NAME="$WS_NET_NAME_DEFAULT"

        local DC_BR="$DC_BR_DEFAULT"
        local SRV_BR="$SRV_BR_DEFAULT"
        local WS_BR="$WS_BR_DEFAULT"

        local DC_IP="$DC_IP_DEFAULT"
        local SRV_IP="$SRV_IP_DEFAULT"
        local WS_IP="$WS_IP_DEFAULT"
    else
        # === MODO INTERATIVO COM VALIDAÇÃO DE IP ===
        echo
        echo -e "${CYAN} AD LAB network settings (press ENTER to accept defaults):${RESET}"

        # --- DC network ---
        read -r -p "DC network name   [${DC_NET_NAME_DEFAULT}]: " DC_NET_NAME
        read -r -p "DC bridge name    [${DC_BR_DEFAULT}]: "       DC_BR

        # loop de validação de IP do DC
        while :; do
            read -r -p "DC gateway IP     [${DC_IP_DEFAULT}]: " DC_IP
            DC_IP="${DC_IP:-$DC_IP_DEFAULT}"
            if hnm_validate_ipv4 "$DC_IP"; then
                break
            else
                echo -e "${FAIL} Invalid IPv4 address '${DC_IP}'. Try again.${RESET}"
            fi
        done

        # --- SRV network ---
        read -r -p "SRV network name  [${SRV_NET_NAME_DEFAULT}]: " SRV_NET_NAME
        read -r -p "SRV bridge name   [${SRV_BR_DEFAULT}]: "       SRV_BR

        while :; do
            read -r -p "SRV gateway IP    [${SRV_IP_DEFAULT}]: " SRV_IP
            SRV_IP="${SRV_IP:-$SRV_IP_DEFAULT}"
            if hnm_validate_ipv4 "$SRV_IP"; then
                break
            else
                echo -e "${FAIL} Invalid IPv4 address '${SRV_IP}'. Try again.${RESET}"
            fi
        done

        # --- WS network ---
        read -r -p "WS network name   [${WS_NET_NAME_DEFAULT}]: " WS_NET_NAME
        read -r -p "WS bridge name    [${WS_BR_DEFAULT}]: "       WS_BR

        while :; do
            read -r -p "WS gateway IP     [${WS_IP_DEFAULT}]: " WS_IP
            WS_IP="${WS_IP:-$WS_IP_DEFAULT}"
            if hnm_validate_ipv4 "$WS_IP"; then
                break
            else
                echo -e "${FAIL} Invalid IPv4 address '${WS_IP}'. Try again.${RESET}"
            fi
        done

        # aplica defaults de nomes/bridges se usuário só deu ENTER
        DC_NET_NAME="${DC_NET_NAME:-$DC_NET_NAME_DEFAULT}"
        DC_BR="${DC_BR:-$DC_BR_DEFAULT}"

        SRV_NET_NAME="${SRV_NET_NAME:-$SRV_NET_NAME_DEFAULT}"
        SRV_BR="${SRV_BR:-$SRV_BR_DEFAULT}"

        WS_NET_NAME="${WS_NET_NAME:-$WS_NET_NAME_DEFAULT}"
        WS_BR="${WS_BR:-$WS_BR_DEFAULT}"
    fi

    echo
    echo -e "${INFO}Using AD LAB networks:${RESET}"
    echo "  DC : ${DC_NET_NAME}  (${DC_IP}/24)  bridge=${DC_BR}"
    echo "  SRV: ${SRV_NET_NAME} (${SRV_IP}/24) bridge=${SRV_BR}"
    echo "  WS : ${WS_NET_NAME}  (${WS_IP}/24)  bridge=${WS_BR}"
    echo

    # === CREATE AD LAB NETWORKS ===
    local NET_ERR=0

    create_ad_net "$DC_NET_NAME"  "$DC_BR"  "$DC_IP"  || NET_ERR=1
    create_ad_net "$SRV_NET_NAME" "$SRV_BR" "$SRV_IP" || NET_ERR=1
    create_ad_net "$WS_NET_NAME"  "$WS_BR"  "$WS_IP"  || NET_ERR=1

    if (( NET_ERR )); then
        echo
        echo -e "${FAIL} One or more AD LAB networks failed to be created/started.${RESET}"
        echo -e "${WARN} Check the messages above (virsh errors, XML, bridges) and fix before retrying.${RESET}"
        read -rp "Press ENTER to return to the menu..." _
        return 1
    fi

    echo
    read -r -p "Do you want to download images (ISO/qcow2) for this LAB now? (y/N): " dlim
    [[ "$dlim" =~ ^[Yy]$ ]] && vm_download_image_vm_mgr

    echo
    echo -e "${CYAN} Available VMs (virsh list --all):${RESET}"
    virsh -c qemu:///system list --all

    echo
    read -r -p "Enter the name of the VM that will be the Domain Controller (DC): " DC_VM
    read -r -p "Enter the name of the VM that will be the Server (e.g.: File/CA/Extra DNS) [optional]: " SRV_VM
    read -r -p "Enter the name of the VM that will be the Workstation (Win10/11) [optional]: " WS_VM

    # --- Connect VMs to the correct networks ---
    for pair in "DC_VM:${DC_NET_NAME}" "SRV_VM:${SRV_NET_NAME}" "WS_VM:${WS_NET_NAME}"; do
        VAR="${pair%%:*}"
        NET="${pair##*:}"
        VM="${!VAR}"

        [[ -z "$VM" ]] && continue

        echo -e "${INFO} Connecting VM ${VM} to network ${NET}...${RESET}"
        log_msg INFO "Connecting VM ${VM} to network ${NET} (AD LAB)."

        mkdir -p /root/vm-xml-backups
        virsh -c qemu:///system dumpxml "$VM" > /root/vm-xml-backups/${VM}-before-adlab.xml 2>/dev/null

        virsh -c qemu:///system dumpxml "$VM" \
        | sed -e "0,/<interface / s//<interface type='network'>/" \
              -e "0,/<source network='[^']*'/ s//<source network='${NET}'/" \
        > /tmp/${VM}-adlab.xml

        if virsh -c qemu:///system define /tmp/${VM}-adlab.xml >/dev/null 2>&1; then
            echo -e "${OK} VM ${VM} adjusted for network ${NET}.${RESET}"
        else
            echo -e "${FAIL} Failed to redefine VM XML ${VM} for network ${NET}.${RESET}"
        fi
    done

    echo
    read -r -p "Do you want to start the AD LAB VMs now? (y/N): " st
    if [[ "$st" =~ ^[Yy]$ ]]; then
        [[ -n "$DC_VM"  ]] && virsh -c qemu:///system start "$DC_VM"
        [[ -n "$SRV_VM" ]] && virsh -c qemu:///system start "$SRV_VM"
        [[ -n "$WS_VM"  ]] && virsh -c qemu:///system start "$WS_VM"
        echo -e "${OK} AD LAB VMs started.${RESET}"
    fi

    # calcular prefixos /24 a partir dos IPs de gateway
    local DC_NET_CIDR="${DC_IP%.*}.0/24"
    local SRV_NET_CIDR="${SRV_IP%.*}.0/24}"
    local WS_NET_CIDR="${WS_IP%.*}.0/24"

    echo
    echo -e "${GREEN} CORPORATE AD LAB ready!${RESET}"
    echo -e "Networks created:"
    echo -e "  ${DC_NET_NAME}  -> ${DC_NET_CIDR} (DC)"
    echo -e "  ${SRV_NET_NAME} -> ${SRV_NET_CIDR} (Server)"
    echo -e "  ${WS_NET_NAME}  -> ${WS_NET_CIDR} (Workstation)"
}

#-----------------------------------------------------------
# Function: lab_traffic_menu
# Module:   Labs
# Purpose:
#   Central menu for traffic generation and inspection in
#   the lab: DoS simulations, replay of pcaps, scanning,
#   noisy vs. stealth profiles, etc.
#
# Inputs:
#   - Source/target VMs.
#   - Traffic pattern type.
#
# Outputs:
#   - Executes traffic tools and shows summaries.
#
# Notes:
#   - Complements lab_sniff_interface and lab_network_perf.
#-----------------------------------------------------------

lab_traffic_menu() {
    echo
    draw_menu_title "TRAFFIC GENERATION"
    #echo -e "${BLUE}===== TRAFFIC GENERATION =====${RESET}"
    echo -e "${WHITE}1)${GREEN} Continuous ping to a host${RESET}"
    echo -e "${WHITE}2)${GREEN} iperf3 server on this host${RESET}"
    echo -e "${WHITE}3)${GREEN} iperf3 client against a host${RESET}"
    echo -e "${WHITE}4)${GREEN} HTTP request loop (curl)${RESET}"
    echo -e "${WHITE}0)${RED} Back${RESET}"
    flush_stdin
    read -r -p "Choice: " op_traf

    case "$op_traf" in
        1)
            echo -ne "${CYAN}Host/IP to ping: ${RESET}"
            read -r H
            [[ -z "$H" ]] && { echo -e "${FAIL} Empty host.${RESET}"; return; }
            echo -e "${INFO} Continuous ping to ${H} (CTRL+C to exit)...${RESET}"
            ping "$H"
            ;;
        2)
            if ! command -v iperf3 >/dev/null 2>&1; then
                echo -e "${FAIL} iperf3 not found. Install the 'iperf3' package to use this option.${RESET}"
                return
            fi
            echo -ne "${CYAN} iperf3 server port (default 5201): ${RESET}"
            read -r P
            [[ -z "$P" ]] && P=5201
            echo -e "${INFO} Starting iperf3 -s -p ${P} (CTRL+C to stop)...${RESET}"
            iperf3 -s -p "$P"
            ;;
        3)
            if ! command -v iperf3 >/dev/null 2>&1; then
                echo -e "${FAIL}iperf3 not found. Install the 'iperf3' package to use this option.${RESET}"
                return
            fi
            echo -ne "${CYAN}iperf3 server host/IP: ${RESET}"
            read -r H
            [[ -z "$H" ]] && { echo -e "${FAIL} Empty host.${RESET}"; return; }
            echo -ne "${CYAN}Port (default 5201): ${RESET}"
            read -r P
            [[ -z "$P" ]] && P=5201
            echo -e "${INFO} Running iperf3 -c ${H} -p ${P}...${RESET}"
            iperf3 -c "$H" -p "$P"
            ;;
        4)
            if ! command -v curl >/dev/null 2>&1; then
                echo -e "${FAIL} curl not found. Install the 'curl' package to use this option.${RESET}"
                return
            fi
            echo -ne "${CYAN}Target URL (e.g.: http://10.10.10.10/):${RESET}"
            read -r URL
            [[ -z "$URL" ]] && { echo -e "${FAIL} Empty URL.${RESET}"; return; }
            echo -e "${CYAN}Number of requests (default 50):${RESET}"
            read -r N
            [[ -z "$N" ]] && N=50
            echo -e "${INFO} Sending ${N} requests to ${URL}...${RESET}"
            for i in $(seq 1 "$N"); do
                echo -e "${INFO} Request #${i}${RESET}"
                curl -ks "$URL" >/dev/null 2>&1
            done
            echo -e "${OK} HTTP loop finished.${RESET}"
            ;;
        0) ;;
        *) echo -e "${FAIL} Invalid option.${RESET}" ;;
    esac
}

#-----------------------------------------------------------
# Function: lab_connectivity_tests
# Module:   Labs
# Purpose:
#   Run a series of basic connectivity checks across the
#   lab environment: ping, traceroute, DNS resolution,
#   HTTP checks, etc., to validate or troubleshoot the
#   current network configuration.
#
# Inputs:
#   - Selected source VM or host context.
#   - Target hosts/URLs.
#
# Outputs:
#   - Printed diagnostics and pass/fail for each test.
#
# Notes:
#   - Frequently used after lab_inject_misconfigs to
#     show how issues surface from the client perspective.
#-----------------------------------------------------------

lab_connectivity_tests() {
    echo
    draw_menu_title "CONNECTIVITY TESTS"
    #echo -e "${BLUE}===== CONNECTIVITY TESTS =====${RESET}"
    echo -ne "${CYAN}Target host or IP: ${RESET}"
    read -r TARGET
    [[ -z "$TARGET" ]] && { echo -e "${FAIL} Empty target.${RESET}"; return; }

    echo -ne "${CYAN}Port for TCP test (Enter to skip): ${RESET}"
    read -r PORT

    echo
    echo -e "${INFO} 1) Short ping (4 packets)...${RESET}"
    ping -c 4 "$TARGET" || echo -e "${WARN} Ping failed (might be blocked, but host may exist).${RESET}"

    echo
    if command -v getent >/dev/null 2>&1; then
        echo -e "${INFO} 2) DNS Resolution (getent hosts)...${RESET}"
        getent hosts "$TARGET" || echo -e "${WARN} DNS resolution failed.${RESET}"
    fi

    if [[ -n "$PORT" ]]; then
        echo
        if command -v nc >/dev/null 2>&1; then
            echo -e "${INFO} 3) TCP port test with nc -vz ${TARGET} ${PORT}...${RESET}"
            nc -vz "$TARGET" "$PORT" 2>&1 || echo -e "${WARN} TCP connection failed.${RESET}"
        else
            echo -e "${WARN} nc (netcat) not found; skipping port test.${RESET}"
        fi
    fi

    echo
    if command -v curl >/dev/null 2>&1; then
        echo -ne "${CYAN} Do you want to test HTTP(S) with curl (e.g.: http://${TARGET}/)(y/N)? ${RESET}"
        read -r ans_http
        if [[ "$ans_http" =~ ^[Yy]$ ]]; then
            echo -ne "${CYAN}Full URL (e.g.: http://${TARGET}/):${RESET}"
            read -r URL
            [[ -z "$URL" ]] && URL="http://${TARGET}/"
            echo -e "${INFO} HTTP request to ${URL}...${RESET}"
            curl -vk --max-time 5 "$URL" || echo -e "${WARN} HTTP(S) request failed.${RESET}"
        fi
    fi

    echo
    echo -e "${OK} Basic connectivity tests completed.${RESET}"
}
