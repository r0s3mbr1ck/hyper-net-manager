#############################################
# MODULE: Diagnostics
#############################################

#-----------------------------------------------------------
# Function: diagnostic_report
# Module:   Diagnostics
# Purpose:
#   Generate a consolidated diagnostic report of the host,
#   libvirt, VM networking, and HNM state for troubleshooting.
#
# Inputs:
#   - None (reads system state and HNM globals).
#
# Outputs:
#   - Prints a multi-section report including:
#       * OS and kernel info
#       * CPU / RAM summary
#       * KVM / libvirt status
#       * Network interfaces and bridges
#       * NetworkManager connections
#       * Libvirt networks and VMs
#
# Side effects:
#   - May append a copy of the report to LOG_FILE or a
#     dedicated diagnostics file (depending on implementation).
#
# Notes:
#   - Intended to be used when "something is wrong" and the
#     user needs a full picture of the environment.
#-----------------------------------------------------------

diagnostic_report() {
    draw_menu_title "ENVIRONMENT DIAGNOSTICS"
    #echo -e "${BLUE}====== ENVIRONMENT DIAGNOSTICS ======${RESET}"
    log_msg INFO "Running environment diagnostics."

    echo -e "${CYAN}Commands:${RESET}"
    for c in nmcli ip virsh iptables virt-manager; do
        if command -v "$c" &>/dev/null; then
            echo -e "  ${OK} ${c}"
        else
            echo -e "  ${FAIL} ${c} (not found)"
        fi
    done
    echo

    echo -e "${CYAN}Main Services:${RESET}"

    if systemctl list-unit-files | grep -q '^NetworkManager.service'; then
        systemctl is-active --quiet NetworkManager && s="${GREEN}active${RESET}" || s="${RED}inactive${RESET}"
        systemctl is-enabled --quiet NetworkManager && e="enabled" || e="disabled"
        echo -e "  NetworkManager: ${s} (${e})"
    else
        echo -e "  ${WARN} NetworkManager not found.${RESET}"
    fi

    if systemctl list-unit-files | grep -q '^libvirtd.service'; then
        systemctl is-active --quiet libvirtd && s="${GREEN}active${RESET}" || s="${RED}inactive${RESET}"
        systemctl is-enabled --quiet libvirtd && e="enabled" || e="disabled"
        echo -e "  libvirtd: ${s} (${e})"
    else
        echo -e "  ${WARN} libvirtd not found (or other libvirt service).${RESET}"
    fi

    if systemctl list-unit-files | grep -q '^systemd-resolved.service'; then
        systemctl is-active --quiet systemd-resolved && s="${GREEN}active${RESET}" || s="${RED}inactive${RESET}"
        systemctl is-enabled --quiet systemd-resolved && e="enabled" || e="disabled"
        echo -e "  systemd-resolved: ${s} (${e})"
    else
        echo -e "  ${WARN} systemd-resolved not installed.${RESET}"
    fi

    echo
    echo -e "${CYAN}nmcli general / device:${RESET}"
    nmcli general status 2>/dev/null || echo "  (nmcli unavailable)"
    echo
    nmcli device status 2>/dev/null || true
    echo
    echo -e "${CYAN}libvirt networks/VMs:${RESET}"
    virsh net-list --all 2>/dev/null || echo "  (virsh unavailable)"
    echo
    virsh list --all 2>/dev/null || true
    echo -e "${BLUE}=====================================${RESET}"
    echo
    echo -e "${CYAN} Press Enter to return to the MAIN MENU...${RESET}"
    read -r _dummy      # <-- pause here
}

