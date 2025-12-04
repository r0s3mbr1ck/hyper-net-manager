#############################################
# MODULE: Host Network – Status / Overview
#############################################

# ------------------------------------------------------------------------------
# FUNCTION: host_status
#
# Purpose:
#   Print high-level host network status:
#     - IP / PREFIX / GATEWAY
#     - WIRED_IF / BRIDGE_IF
#     - Bridge mode active?
# ------------------------------------------------------------------------------

host_status() {
    echo ""
    draw_menu_title "HOST STATUS"
    #echo -e "${BLUE}===== HOST STATUS =====${RESET}"
    nmcli device status
    echo
    ip -4 addr show
    echo
    ip route
    echo -e "${BLUE}================================${RESET}"
}

# ------------------------------------------------------------------------------
# FUNCTION: status_networks_and_vms
#
# Purpose:
#   Comprehensive debugging dump:
#     - Linux interfaces
#     - NetworkManager connections
#     - Libvirt networks
#     - VMs and MAC/IP detection
# ------------------------------------------------------------------------------

status_networks_and_vms() {
    draw_menu_title "Libvirt Networks "
    #echo -e "${BLUE}=== Libvirt Networks ===${RESET}"
    virsh net-list --all
    echo
    draw_menu_title "VMs"
    #echo -e "${BLUE}=== VMs ===${RESET}"
    virsh list --all
    echo
    draw_menu_title "Active VM Interfaces"
    #echo -e "${BLUE}=== Active VM Interfaces ===${RESET}"
    virsh list --name | sed '/^$/d' | while read -r dom; do
        echo -e "${CYAN}VM: ${dom}${RESET}"
        virsh domiflist "$dom"
        echo
    done
}
