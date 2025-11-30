#!/bin/bash
###############################################################################
# Hyper Net Manager (HNM) – Modular Edition
# Compatible with NetworkManager + systemd-resolved
# - Manages HOST network via nmcli (bridge/ethernet)
# - Manages VM networks via libvirt (internal VLANs, host-only, DMZ, br0)
# - Uses multiple modules under ./core, ./host, ./vm, ./labs, ./diagnostics
###############################################################################
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CoreS
source "${BASE_DIR}/core/helpers.sh"

# Host networking
source "${BASE_DIR}/host/detect.sh"
source "${BASE_DIR}/host/bridge.sh"
source "${BASE_DIR}/host/status.sh"

# VM
source "${BASE_DIR}/vm/vm-manager.sh"
source "${BASE_DIR}/vm/vm-network.sh"

# Labs
source "${BASE_DIR}/labs/labs.sh"

# Diagnostics
source "${BASE_DIR}/diagnostics/diagnostics.sh"

#------------------------------------------------------------------------------
# require_root()
# Purpose : Enforce root execution (sudo) for critical operations.
# Module  : Global Helpers
#------------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${FAIL} Please run this script as root (sudo).${RESET}"
        exit 1
    fi
}
	echo
log_msg INFO "===== Starting Hyper Net Manager ====="

#------------------------------------------------------------------------------
# check_prereqs()
# Purpose : Ensure core commands and services required by HNM are present.
# Module  : Global Helpers
#------------------------------------------------------------------------------
check_prereqs() {
    ensure_cmd_or_pkg nmcli network-manager
    ensure_cmd_or_pkg ip    iproute2
    ensure_cmd_or_pkg virsh libvirt-daemon-system
    ensure_cmd_or_pkg iptables iptables

    ensure_optional_cmd_or_pkg virt-manager virt-manager
    check_systemd_resolved
}

#------------------------------------------------------------------------------
# load_state()
# Purpose : Load previously saved host/bridge state, if present.
# Module  : Global Helpers
#------------------------------------------------------------------------------
load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        log_msg INFO "State loaded from ${STATE_FILE}."
    fi
}

# ------------------------------------------------------------------------------
# FUNCTION: hnm_check_dependencies
#
# Purpose:
#   Validate that all required system commands and packages for HNM are present,
#   offering installation where appropriate and aborting on hard failures.
#
# Inputs (globals):
#   None
#
# Outputs (globals):
#   None
#
# External Commands:
#   command, apt-get, etc.
#
# Depends On:
#   ensure_cmd_or_pkg, ensure_optional_cmd_or_pkg, ensure_fzf, log_msg
#
# Returns:
#   0 if all required dependencies are satisfied
#   non-zero (or exit) if critical dependencies are missing
#
# Notes:
#   Should be called early in the main flow before menus are displayed.
# ------------------------------------------------------------------------------

hnm_check_dependencies() {
    # Só roda essa checagem como root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${FAIL} Hyper Net Manager must be run as root (sudo or pkexec).${RESET}"
        exit 1
    fi

    # Lista de pacotes obrigatórios (nomes do APT)
    local REQUIRED_PKGS=(
        libvirt-daemon-system
        libvirt-clients
        virt-manager
        bridge-utils
    )

    # Pacotes “recomendados” (ex: terminal Tilix, mas não é fatal)
    local OPTIONAL_PKGS=(
        tilix
    )

    local MISSING_PKGS=()
    local MISSING_OPT=()

    # Verifica pacotes obrigatórios
    for pkg in "${REQUIRED_PKGS[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
    done

    # Verifica opcionais
    for pkg in "${OPTIONAL_PKGS[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_OPT+=("$pkg")
    done

    # Se não estiver faltando nada crítico, só informa opcionais (se quiser) e segue
    if ((${#MISSING_PKGS[@]} == 0)); then
        if ((${#MISSING_OPT[@]} > 0)); then
            echo -e "${WARN} Optional packages not installed: ${MISSING_OPT[*]}${RESET}"
        fi
        return 0
    fi

    echo ""
    echo -e "${FAIL} The following required packages are missing:${RESET}"
    printf '  - %s\n' "${MISSING_PKGS[@]}"
    echo ""

    read -rp "Install these packages now with apt? (y/N): " ans
    ans=${ans:-N}

    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        echo -e "${FAIL} Cannot continue without required dependencies.${RESET}"
        echo -e "${INFO} Please install them manually, e.g.:${RESET}"
        echo -e "  sudo apt update"
        echo -e "  sudo apt install ${MISSING_PKGS[*]}"
        exit 1
    fi

    echo -e "${INFO} Installing required packages via apt-get...${RESET}"
    apt-get update

    if ! apt-get install -y "${MISSING_PKGS[@]}"; then
        echo ""
        echo -e "${FAIL} apt-get could not install all required packages.${RESET}"
        echo -e "${WARN} Your package manager reported unmet dependencies.${RESET}"
        echo -e "${INFO} Recommended next step:${RESET}"
        echo -e "  sudo apt --fix-broken install"
        echo -e "  sudo apt install ${MISSING_PKGS[*]}"
        echo ""
        echo -e "${FAIL} Hyper Net Manager cannot continue until this is fixed.${RESET}"
        exit 1
    fi

    echo -e "${OK} Required dependencies installed successfully.${RESET}"
}

#-----------------------------------------------------------
# Function: menu_principal
# Module:   Main
# Purpose:
#   Main entrypoint menu for Hyper Net Manager (HNM). From
#   here the user can:
#     - Manage host networking (bridge / ethernet)
#     - Manage VM networks (internal VLANs / host-only / DMZ)
#     - Manage VMs (images, creation, power, snapshots)
#     - Manage Labs (AD, DMZ, pivot, traffic, etc.)
#     - Run Environment Diagnostics
#
# Inputs:
#   - None (interactive loop using user input).
#
# Outputs:
#   - Calls:
#       host_menu
#       <VM networking menu function>
#       vm_menu_manager or vm_menu
#       labs_menu
#       diagnostic_report / status_networks_and_vms
#
# Side effects:
#   - Keeps running in a loop until the user selects "Exit".
#   - Clears the screen and reprints banner on first run.
#
# Notes:
#   - This is the main control hub for HNM and the function
#     that should be called at the end of the script after
#     initialization.
#-----------------------------------------------------------

menu_principal() {
    local first_run=1
    local MENU_LIST MENU_SEL opcao
    
    while true; do
   	show_banner
        if [[ $first_run -eq 1 ]]; then    
            first_run=0
        else
            echo
        fi
	
        # MENU LIST FOR FZF / NORMAL INPUT
        MENU_LIST=$(
        cat <<EOF
1) Manage HOST NETWORK (bridge / ethernet / Wifi / VPN)
2) Manage VM NETWORKS (internal VLANs / host-only / DMZ)
3) Manage VMs (image download, creation, resources)
4) Manage Pentest / Study LABs
5) Environment Diagnostics (NM, libvirt, DNS, etc.)
0) Exit
EOF
        )
        draw_menu_title "MAIN MENU"
        # Prefer FZF via hnm_select
        if ensure_fzf; then
            MENU_SEL=$(hnm_select "Select option" "$MENU_LIST") || continue
            opcao=$(echo "$MENU_SEL" | awk '{print $1}' | tr -d ')')
        else
            # Fallback manual menu (the one you already have)
            echo -e "${WHITE}1)${GREEN} Manage HOST NETWORK (bridge / ethernet / Wifi / VPN)${RESET}"
            echo -e "${WHITE}2)${GREEN} Manage VM NETWORKS (internal VLANs / host-only / DMZ)${RESET}"
            echo -e "${WHITE}3)${GREEN} Manage VMs (image download, creation, resources)${RESET}"
            echo -e "${WHITE}4)${GREEN} Manage Pentest / Study LABs${RESET}"
            echo -e "${WHITE}5)${GREEN} Environment Diagnostics (NM, libvirt, DNS, etc.)${RESET}"
            echo -e "${WHITE}0)${RED} Exit${RESET}"
            flush_stdin
            read -r -p "Choice: " opcao
        fi

        echo ""

        # MATCH THE OPTION
        case "$opcao" in
            1) host_menu ;;
            2) vm_menu ;;
            3) vm_menu_manager ;;
            4) labs_menu ;;
            5) diagnostic_report ;;
            0)
                echo -e "${GREEN} Exiting.${RESET}"
                echo
                log_msg INFO "Shutting down Hyper Net Manager."
                echo
                exit 0
                ;;
            *) echo -e "${FAIL} Invalid option.${RESET}" ;;
        esac
    done
}

#-----------------------------------------------
# Function: vm_menu_manager
# Module:   VM Manager
# Purpose:  Central interactive menu for VM operations.
#           Groups image download, creation, clone, power,
#           snapshots, connection and image directory config.
#
# Inputs:
#   - Uses ensure_fzf + hnm_select for arrow-key menu when
#     available; falls back to classic numeric menu.
#
# Outputs:
#   - Returns to main menu when user chooses option 0.
#
# Side effects:
#   - Calls multiple VM Manager helpers:
#       vm_download_image_vm_mgr
#       vm_create_simple_vm
#       hnm_list_vms_with_ips
#       vm_tune_vm_resources
#       vm_connect_existing
#       open_vm_console_auto
#       vm_clone_vm
#       vm_snapshot_menu
#       vm_power_menu
#       vm_delete_vm
#       vm_image_dir_menu
#
# Typical usage:
#   - Invoked from main menu option "Manage VMs".
#-----------------------------------------------

vm_menu_manager() {

    while true; do
        local MENU_LIST MENU_SEL op_vm
	echo
        draw_menu_title "VM MANAGEMENT MENU"
        
        MENU_LIST=$(
        cat <<EOF
1) Download / extract VM image (ISO/qcow2/tar/zip)
2) Create simple VM from existing image
3) List VMs with IP (virsh + IP detection)
4) Adjust VM resources (CPU / memory)
5) Connect to existing VM (SSH / GUI)
6) Open VM graphical console (virt-viewer / virt-manager)
7) Clone VM (virt-clone)
8) VM Snapshot (create / list / revert / remove)
9) Manage VM state (start / shutdown / reboot / destroy)
10) Delete VM (with option to remove disks/ISO)
11) Configure image directory (ISO/QCOW)
0) Back to main menu
EOF
        )

        if ensure_fzf; then
            MENU_SEL=$(hnm_select "Select option" "$MENU_LIST") || continue
            op_vm=$(echo "$MENU_SEL" | awk '{print $1}' | tr -d ')')
        else
            echo -e "${WHITE}1)${GREEN} Download / extract VM image (ISO/qcow2/tar/zip)${RESET}"
            echo -e "${WHITE}2)${GREEN} Create simple VM from existing image${RESET}"
            echo -e "${WHITE}3)${GREEN} List VMs with IP (virsh + IP detection)${RESET}"
            echo -e "${WHITE}4)${GREEN} Adjust VM resources (CPU / memory)${RESET}"
            echo -e "${WHITE}5)${GREEN} Connect to existing VM (SSH / GUI)${RESET}"
            echo -e "${WHITE}6)${GREEN} Open VM graphical console (virt-viewer/virt-manager)${RESET}"
            echo -e "${WHITE}7)${GREEN} Clone VM (virt-clone)${RESET}"
            echo -e "${WHITE}8)${GREEN} VM Snapshot (create/list/revert/remove)${RESET}"
            echo -e "${WHITE}9)${GREEN} Manage VM state (start/shutdown/reboot/destroy)${RESET}"
            echo -e "${WHITE}10)${GREEN} Delete VM (with option to remove disks/ISO)${RESET}"
            echo -e "${WHITE}11)${GREEN} Configure image directory (ISO/QCOW)${RESET}"
            echo -e "${WHITE}0)${RED} Back to main menu${RESET}"
            flush_stdin
            read -r -p "Choice: " op_vm
        fi

        echo ""

        case "$op_vm" in
            1)  vm_download_image_vm_mgr ;;
            2)  vm_create_simple_vm ;;
            3)  hnm_list_vms_with_ips ;;
            4)  vm_tune_vm_resources ;;
            5)  vm_connect_existing ;;
            6)
                echo
                virsh list --all
                read_vm_name_tab_complete VM_CONS "Name of VM to open graphical console: "
                echo ""
                [[ -n "$VM_CONS" ]] && open_vm_console_auto "$VM_CONS"
                ;;
            7)  vm_clone_vm ;;
            8)  vm_snapshot_menu ;;
            9)  vm_power_menu ;;
            10) vm_delete_vm ;;
            11) vm_image_dir_menu ;;
            0)  return ;;
            *)  echo -e "${FAIL} Invalid option.${RESET}" ;;
        esac
    done
}

#-----------------------------------------------------------
# Function: host_menu
# Module:   Host Network / Menus
# Purpose:
#   Provide an interactive menu for host-level network
#   operations: show host status, enable/disable bridge
#   mode, manage VLANs on the bridge, and run diagnostics.
#
# Inputs:
#   - User selection via numeric or fzf-based menu.
#
# Outputs:
#   - Calls appropriate Host Network functions:
#       * host_status
#       * enable_bridge_mode
#       * enable_eth_mode
#       * create_vlan_on_bridge
#       * delete_vlan_bridge
#       * status_networks_and_vms
#       * diagnostic_report
#
# Side effects:
#   - Changes host networking configuration when the user
#     selects actions like enabling bridge mode or adding
#     VLANs.
#
# Notes:
#   - Invoked from the main menu under:
#       "Manage HOST NETWORK (bridge / ethernet)".
#-----------------------------------------------------------

host_menu() {
    while true; do
        load_state
        echo
        draw_menu_title "HOST MENU (NetworkManager) "
        echo -e "Interface: ${WHITE}${WIRED_IF:-(not configured)}${RESET}"
        echo -e "IP:        ${WHITE}${HOST_IP:-(unknown)}${RESET}"
        echo -e "Bridge:    ${WHITE}${BRIDGE_IF} (${BRIDGE_IP:-no IP})${RESET}"
        echo

        local MENU_LIST MENU_SEL op

        MENU_LIST=$(
        cat <<EOF
1) Activate BRIDGE mode (host uses ${BRIDGE_IF})
2) Revert to ETHERNET mode (restore original connection)
3) Manage Wi-Fi connections
4) Manage VPN connections
5) Show host status
0) Back to main menu
EOF
        )

        if ensure_fzf; then
            MENU_SEL=$(hnm_select "Select option" "$MENU_LIST") || continue
            op=$(echo "$MENU_SEL" | awk '{print $1}' | tr -d ')')
        else
            echo -e "${WHITE}1)${GREEN} Activate BRIDGE mode (host uses ${BRIDGE_IF})${RESET}"
            echo -e "${WHITE}2)${GREEN} Revert to ETHERNET mode (restore original connection)${RESET}"
            echo -e "${WHITE}3)${GREEN} Manage Wi-Fi connections${RESET}"
            echo -e "${WHITE}4)${GREEN} Manage VPN connections${RESET}"
            echo -e "${WHITE}5)${GREEN} Show host status${RESET}"
            echo -e "${WHITE}0)${RED} Back to main menu${RESET}"
            flush_stdin
            read -r -p "Choice: " op
        fi

        echo ""

        case "$op" in
            1) enable_bridge_mode ;;
            2) enable_eth_mode ;;
            3) host_nm_manage_wifi ;;
            4) host_nm_manage_vpn ;;
            5) host_status ;;
            0) break ;;
            *) echo -e "${FAIL} Invalid option.${RESET}" ;;
        esac
    done
}
#-----------------------------------------------------------
# Function: vm_menu
# Module:   VM Manager / Menus
# Purpose:
#   Legacy / secondary VM menu that groups VM-related tasks
#   (create, delete, power, snapshots, network attach, etc.)
#   in a simpler or alternative layout to vm_menu_manager.
#
# Inputs:
#   - User choice via interactive menu.
#
# Outputs:
#   - Delegates to VM Manager and VM Networking helpers:
#       * vm_create_simple_vm
#       * vm_show_all_vms
#       * vm_power_menu
#       * vm_snapshot_menu
#       * vm_clone_vm
#       * vm_delete_vm
#       * vm_connect_existing
#       * vm_image_dir_menu
#
# Side effects:
#   - May start/stop/delete VMs and change configuration,
#     depending on selected actions.
#
# Notes:
#   - If vm_menu_manager is the main entry point, this menu
#     can be considered a "classic" or compact alternative.
#-----------------------------------------------------------

vm_menu() {
    while true; do
        local VLAN_MENU VLAN_SEL op
	draw_menu_title "VMs / LIBVIRT / VLAN MENU"
        VLAN_MENU=$(
        cat <<EOF
1) Create internal VLAN (NAT libvirt network)
2) Connect VMs to internal VLAN (with start/reboot option)
3) Put VMs on the same network as host (bridge ${BRIDGE_IF})
4) Remove internal VLAN (with optional shutdown/reboot)
5) Revert VMs on br0 to default NAT
6) Create host-only network (no NAT)
7) Create DMZ network (NAT via ${BRIDGE_IF} + iptables)
8) Create real VLAN on ${BRIDGE_IF}
9) Remove real VLAN from ${BRIDGE_IF}
10) List internal VLANs / libvirt networks
11) Duplicate internal VLAN (new network)
12) Show detailed networks and VMs
0) Back to main menu
EOF
        )

        # ---------------------------
        # 💠 Apenas UM título!
        # ---------------------------
        

        if ensure_fzf; then
            VLAN_SEL=$(hnm_select "Select option" "$VLAN_MENU") || return
            op=$(echo "$VLAN_SEL" | awk '{print $1}' | tr -d ')')
        else
            echo "$VLAN_MENU"
            flush_stdin
            read -r -p "Choice: " op
        fi

        echo ""

        case "$op" in
            1)  create_internal_network ;;
            2)  attach_vms_to_network ;;
            3)  attach_vms_to_br0 ;;
            4)  remove_internal_network ;;
            5)  remove_vms_from_br0 ;;
            6)  create_hostonly_network ;;
            7)  create_dmz_network ;;
            8)  create_vlan_on_bridge ;;
            9)  delete_vlan_bridge ;;
            10) list_internal_networks ;;
            11) duplicate_internal_network ;;
            12) status_networks_and_vms ;;
            0)  return ;;
            *)  echo -e "${FAIL} Invalid option.${RESET}" ;;
        esac
    done
}


#########################
# MAIN ENTRY            #
#########################

hnm_load_config
hnm_init_kvm_qemu_libvirt
require_root
check_prereqs
load_state
hnm_check_dependencies
menu_principal

exit 0
