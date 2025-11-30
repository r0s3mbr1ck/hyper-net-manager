#############################################
# MODULE: VM Manager
# - Create / clone / power / snapshots / connect
#############################################

#-----------------------------------------------
# Function: vm_download_image_vm_mgr
# Module:   VM Manager
# Purpose:  Wrapper to download and/or extract VM images
#           (ISO, qcow2, archives) into the configured
#           image directory.
#
# Inputs:
#   - Uses global:
#       $HNM_IMAGE_DIR     -> base directory for images
#   - Relies on helper:
#       download_and_extract_images
#
# Outputs:
#   - Exit status of download_and_extract_images.
#
# Side effects:
#   - Downloads and extracts files into $HNM_IMAGE_DIR.
#   - Logs actions via log_msg (inside helpers).
#
# Typical usage:
#   - Called from VM Management Menu, option:
#       "Download / extract VM image (ISO/qcow2/tar/zip)"
#-----------------------------------------------

vm_download_image_vm_mgr() {
    echo
    echo -e "${INFO} Download image/ISO for use in VMs...${RESET}"
    download_and_extract_images
}

#-----------------------------------------------
# Function: vm_power_menu
# Module:   VM Manager
# Purpose:  Manage power state of a selected VM through
#           an interactive menu (start, shutdown, reboot,
#           force destroy).
#
# Inputs:
#   - VM selected via hnm_select_vm.
#   - User option for desired power action.
#
# Outputs:
#   - Human-readable status messages for each action.
#
# Side effects:
#   - Runs:
#       virsh start
#       virsh shutdown
#       virsh reboot
#       virsh destroy
#   - Writes log entries via log_msg for each operation.
#
# Typical usage:
#   - Called from VM Management Menu, option:
#       "Manage VM state (start / shutdown / reboot / destroy)"
#-----------------------------------------------

vm_power_menu() {
    echo
    draw_menu_title "MANAGE VM STATE"
    #echo -e "${GREEN_TITLE}==== MANAGE VM STATE ====${RESET}"
    echo ""

    # Show current VMs (informational)
    virsh list --all 2>/dev/null
    echo ""

    # Select VM with arrow-key menu
    local VM_NAME
    VM_NAME=$(hnm_select_vm) || { echo -e "${WARN} Operation canceled.${RESET}"; return; }

    # Get current state
    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null)
    echo -e "${INFO} Current state of VM ${VM_NAME}: ${state}${RESET}"

    echo
    echo -e "${WHITE}1)${GREEN} Start VM${RESET}"
    echo -e "${WHITE}2)${GREEN} Shutdown (ACPI shutdown)${RESET}"
    echo -e "${WHITE}3)${GREEN} Force Off (destroy)${RESET}"
    echo -e "${WHITE}4)${GREEN} Reboot${RESET}"
    echo -e "${WHITE}5)${GREEN} Add network interface (DMZ / internal / VLAN)${RESET}"
    echo -e "${WHITE}0)${RED} Back${RESET}"
    flush_stdin
    read -r -p "Choice: " op_p

    case "$op_p" in
        1)
            if [[ "$state" == "running" ]]; then
                echo -e "${WARN} VM ${VM_NAME} is already running.${RESET}"
            else
                echo -e "${INFO} Starting VM ${VM_NAME}...${RESET}"
                if virsh start "$VM_NAME" >/dev/null 2>&1; then
                    echo -e "${OK} VM ${VM_NAME} started.${RESET}"
                    log_msg INFO "VM ${VM_NAME} started via vm_power_menu."
                else
                    echo -e "${FAIL} Failed to start VM ${VM_NAME}.${RESET}"
                    log_msg ERROR "Failed to start VM ${VM_NAME} in vm_power_menu."
                fi
            fi
            ;;
        2)
            if [[ "$state" != "running" ]]; then
                echo -e "${WARN} VM ${VM_NAME} is not running.${RESET}"
            else
                echo -e "${INFO} Sending soft shutdown to ${VM_NAME}...${RESET}"
                if virsh shutdown "$VM_NAME" >/dev/null 2>&1; then
                    echo -e "${OK} Shutdown command sent.${RESET}"
                    log_msg INFO "Soft shutdown requested for VM ${VM_NAME}."
                else
                    echo -e "${FAIL} Failed to send shutdown to ${VM_NAME}.${RESET}"
                    log_msg ERROR "Failed to send shutdown to VM ${VM_NAME}."
                fi
            fi
            ;;
        3)
            if [[ "$state" != "running" ]]; then
                echo -e "${WARN} VM ${VM_NAME} is not running.${RESET}"
            else
                echo -ne "${WARN} This will IMMEDIATELY power off VM ${VM_NAME}. Confirm (y/N)? ${RESET}"
                read -r -p "> " ans_d
                if [[ "$ans_d" =~ ^[Yy]$ ]]; then
                    if virsh destroy "$VM_NAME" >/dev/null 2>&1; then
                        echo -e "${OK} VM ${VM_NAME} was forcibly shut down.${RESET}"
                        log_msg WARN "VM ${VM_NAME} forcibly shut down (destroy)."
                    else
                        echo -e "${FAIL} Failed to destroy VM ${VM_NAME}.${RESET}"
                        log_msg ERROR "Failed to destroy VM ${VM_NAME}."
                    fi
                else
                    echo -e "${INFO} Operation canceled.${RESET}"
                fi
            fi
            ;;
        4)
            if [[ "$state" != "running" ]]; then
                echo -e "${WARN} VM ${VM_NAME} is not running. Starting...${RESET}"
                if virsh start "$VM_NAME" >/dev/null 2>&1; then
                    echo -e "${OK} VM ${VM_NAME} started.${RESET}"
                    log_msg INFO "VM ${VM_NAME} started (reboot on stopped VM)."
                else
                    echo -e "${FAIL} Failed to start VM ${VM_NAME}.${RESET}"
                    log_msg ERROR "Failed to start VM ${VM_NAME} on reboot option."
                fi
            else
                echo -e "${INFO} Sending reboot to ${VM_NAME}...${RESET}"
                if virsh reboot "$VM_NAME" >/dev/null 2>&1; then
                    echo -e "${OK} Reboot requested for ${VM_NAME}.${RESET}"
                    log_msg INFO "Reboot requested for VM ${VM_NAME}."
                else
                    echo -e "${FAIL} Failed to send reboot to ${VM_NAME}.${RESET}"
                    log_msg ERROR "Failed to send reboot to VM ${VM_NAME}."
                fi
            fi
            ;;
        5)
            echo
            draw_menu_title "ADD NETWORK INTERFACE TO VM"
            #echo -e "${GREEN_TITLE}==== ADD NETWORK INTERFACE TO VM ====${RESET}"
            echo -e "${INFO} Available libvirt networks:${RESET}"
            virsh net-list --all 2>/dev/null || true
            echo
            echo -ne "${CYAN}Enter libvirt network name (DMZ / internal / VLAN): ${RESET}"
            read -r NET_NAME
            if [[ -z "$NET_NAME" ]]; then
                echo -e "${WARN} No network name provided. Operation canceled.${RESET}"
                return
            fi

            # Garante que a rede existe e está ativa
            ensure_libvirt_net "$NET_NAME" || return

            # Definir flags de attach conforme o estado
            local ATTACH_FLAGS
            if [[ "$state" == "running" ]]; then
                echo -e "${INFO} VM is running. Attaching interface live and persistent (--live --config).${RESET}"
                ATTACH_FLAGS="--live --config"
            else
                echo -e "${INFO} VM is powered off. Attaching interface persistently (--config).${RESET}"
                ATTACH_FLAGS="--config"
            fi

            echo -e "${INFO} Attaching interface from network ${NET_NAME} to VM ${VM_NAME}...${RESET}"
            if virsh attach-interface --domain "$VM_NAME" \
                                      --type network \
                                      --source "$NET_NAME" \
                                      --model virtio \
                                      $ATTACH_FLAGS >/dev/null 2>&1; then
                echo -e "${OK} Network interface added to VM ${VM_NAME} (network=${NET_NAME}).${RESET}"
                log_msg INFO "Added NIC to VM ${VM_NAME} using network ${NET_NAME} (${ATTACH_FLAGS})."
            else
                echo -e "${FAIL} Failed to attach interface to VM ${VM_NAME}.${RESET}"
                log_msg ERROR "Failed to attach NIC to VM ${VM_NAME} (network=${NET_NAME})."
            fi
            ;;
        0)
            echo -e "${INFO} Returning to VM menu.${RESET}"
            ;;
        *)
            echo -e "${WARN} Invalid option. Returning to VM menu.${RESET}"
            ;;
    esac
}

#-----------------------------------------------
# Function: vm_delete_vm
# Module:   VM Manager
# Purpose:  Safely delete a VM from libvirt, with the
#           option to also remove its associated disk
#           image(s) and/or ISO files.
#
# Inputs:
#   - VM selected via hnm_select_vm.
#   - Confirms:
#       - whether to shut down the VM if running
#       - whether to undefine the domain
#       - whether to delete attached disk/ISO paths
#
# Outputs:
#   - Success or failure messages for each step.
#
# Side effects:
#   - May stop a running VM (virsh shutdown/destroy).
#   - Removes libvirt domain definition (virsh undefine).
#   - Optionally deletes disk/ISO files with rm.
#   - Logs all relevant actions with log_msg.
#
# Typical usage:
#   - Called from VM Management Menu, option:
#       "Delete VM (with option to remove disks/ISO)"
#-----------------------------------------------

vm_delete_vm() {
    echo
    draw_menu_title "DELETE VM (with or without disk/ISO removal)"
    #echo -e "${GREEN_TITLE}==== DELETE VM (with or without disk/ISO removal) ====${RESET}"
    echo ""

    # Show VMs (informational)
    virsh list --all 2>/dev/null || true
    echo ""

    # Select VM using arrow-key menu
    local VM_NAME
    VM_NAME=$(hnm_select_vm) || { echo -e "${WARN} Operation canceled.${RESET}"; return; }

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null)

    if [[ "$state" == "running" ]]; then
        echo -e "${WARN} VM ${VM_NAME} is running.${RESET}"
        echo -e "${CYAN} 1) Send soft shutdown${RESET}"
        echo -e "${CYAN} 2) Force off (destroy)${RESET}"
        echo -e "${CYAN} 3) Cancel deletion${RESET}"
        flush_stdin
        read -r -p "Choice: " op_stop

        case "$op_stop" in
            1)
                virsh shutdown "$VM_NAME" >/dev/null 2>&1 || true
                echo -e "${INFO} Waiting for VM to shut down...${RESET}"
                sleep 5
                ;;
            2)
                virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
                ;;
            3|*) 
                echo -e "${INFO} Deletion canceled.${RESET}"
                return
                ;;
        esac
    fi

    # Recheck state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "shut off")
    if [[ "$state" == "running" ]]; then
        echo -e "${FAIL}VM ${VM_NAME} is still running. Aborting deletion.${RESET}"
        return
    fi

    echo
    echo -e "${INFO} Collecting disks attached to VM ${VM_NAME}...${RESET}"

    # List attached disks
    local TYPE DEVICE TARGET SOURCE
    local FILES=() DEVICES=()

    while read -r TYPE DEVICE TARGET SOURCE; do
        [[ -z "$TYPE" || "$SOURCE" == "-" ]] && continue
        # TYPE: file/block, DEVICE: disk/cdrom, TARGET: vda/sda, SOURCE: path
        FILES+=("$SOURCE")
        DEVICES+=("$DEVICE/$TARGET")
    done < <(virsh domblklist --details "$VM_NAME" 2>/dev/null | awk 'NR>2 && NF {print $1,$2,$3,$4}')

    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo -e "${WARN} No associated disk/ISO found in domblklist.${RESET}"
    else
        echo -e "${INFO} Disk/ISO files associated with the VM:${RESET}"
        local i
        for i in "${!FILES[@]}"; do
            echo "  [$i] ${FILES[$i]}  (type: ${DEVICES[$i]})"
        done
    fi

    echo
    echo -e "${WARN} Warning: 'Delete VM' will remove the definition from libvirt (undefine).${RESET}"
    echo -e "${WARN} Removal OF FILES (qcow2/ISO) will be asked individually.${RESET}"
    echo
    read -r -p "Confirm deletion of VM ${VM_NAME} (y/N)?: " ans_del
    [[ ! "$ans_del" =~ ^[Yy]$ ]] && { echo -e "${INFO}Operation canceled.${RESET}"; return; }

    # Undefine first
    if virsh undefine "$VM_NAME" >/dev/null 2>&1; then
        echo -e "${OK}VM ${VM_NAME} has been removed from libvirt (undefine).${RESET}"
        log_msg INFO "VM ${VM_NAME} undefine performed in vm_delete_vm."
    else
        echo -e "${FAIL} Failed to undefine VM ${VM_NAME}.${RESET}"
        log_msg ERROR "Failed to undefine VM ${VM_NAME} in vm_delete_vm."
        echo -e "${WARN} Aborting file removal to avoid inconsistencies.${RESET}"
        return
    fi

    # Ask for each file if it should be removed
    if [[ ${#FILES[@]} -gt 0 ]]; then
        echo
        echo -e "${CYAN} You can now choose to remove associated disk/ISO files.${RESET}"
        echo -e "${CYAN} Answer 'y' to remove or Enter/N to keep.${RESET}"
        local path
        for i in "${!FILES[@]}"; do
            path="${FILES[$i]}"
            [[ -z "$path" ]] && continue
            [[ "$path" == "/" ]] && continue

            echo
            echo -ne "${YELLOW} Remove file ${path} (y/N)? ${RESET}"
            read -r -p ans_file
            if [[ "$ans_file" =~ ^[Yy]$ ]]; then
                if [[ -e "$path" ]]; then
                    if rm -f -- "$path"; then
                        echo -e "${OK} File ${path} removed.${RESET}"
                        log_msg INFO "Disk/ISO file removed in vm_delete_vm: ${path}"
                    else
                        echo -e "${FAIL} Failed to remove file ${path}.${RESET}"
                        log_msg ERROR "Failed to remove file ${path} in vm_delete_vm."
                    fi
                else
                    echo -e "${WARN} File ${path} no longer exists on the filesystem.${RESET}"
                fi
            else
                echo -e "${INFO} File ${path} kept.${RESET}"
            fi
        done
    fi

    echo
    echo -e "${OK} Deletion process for VM ${VM_NAME} completed.${RESET}"
}

#-----------------------------------------------
# Function: vm_create_simple_vm
# Module:   VM Manager
# Purpose:  Guided wizard to create a simple KVM/libvirt VM
#           from an existing disk image (qcow2/raw) and
#           optional ISO, attaching up to two networks.
#
# Inputs:
#   - Interactively asks for:
#       VM name
#       RAM size (MiB)
#       vCPU count
#       disk path (existing or to be created)
#       primary and optional secondary libvirt networks
#       optional ISO path for installation
#   - Uses helpers:
#       hnm_select_vm_image
#       hnm_select_libvirt_network
#       check_disk_space
#
# Outputs:
#   - Defines a new libvirt domain with virsh define.
#   - Prints success/failure messages.
#
# Side effects:
#   - Creates VM XML in libvirt (qemu:///system).
#   - May create new qcow2 disk with qemu-img.
#   - May automatically start the VM and call
#     offer_ssh_after_actions on success.
#echo


# Typical usage:
#   - Called from VM Management Menu, option:
#       "Create simple VM from existing image"
#-----------------------------------------------

vm_create_simple_vm() {
    echo
    draw_menu_title "CREATE SIMPLE VM (virsh"
    #echo -e "${BLUE}===== CREATE SIMPLE VM (virsh) =====${RESET}"

    echo -ne "${CYAN}		New VM name: ${RESET}"
    read -r VM_NAME
    [[ -z "$VM_NAME" ]] && { echo -e "${FAIL}VM name cannot be empty.${RESET}"; return; }

    # usar o diretório configurado no HNM ou cair no padrão do libvirt
    local DEFAULT_IMG_DIR="${HNM_IMAGE_DIR:-/media/alex/ISO1}"
    echo -ne "${CYAN}Disk image directory (default: ${DEFAULT_IMG_DIR}): ${RESET}"
    read -r DISK_DIR
    [[ -z "$DISK_DIR" ]] && DISK_DIR="$DEFAULT_IMG_DIR"

    echo -ne "${CYAN}Name of qcow2 disk file (e.g.: ${VM_NAME}.qcow2): ${RESET}"
    read -r DISK_FILE
    [[ -z "$DISK_FILE" ]] && DISK_FILE="${VM_NAME}.qcow2"

    local DISK_PATH="${DISK_DIR%/}/${DISK_FILE}"

    if [[ -f "$DISK_PATH" ]]; then
        echo -ne "${WARN}Disk ${DISK_PATH} already exists.${RESET}"
    else
        echo -ne "${CYAN}Disk size in GB (e.g.: 40): ${RESET}"
        read -r DISK_GB
        [[ -z "$DISK_GB" ]] && DISK_GB=40

        check_disk_space "$DISK_DIR" "$DISK_GB" || return

        echo -e "${INFO} Creating qcow2 disk ${DISK_PATH} with ${DISK_GB}G...${RESET}"
        if qemu-img create -f qcow2 "$DISK_PATH" "${DISK_GB}G" >/dev/null 2>&1; then
            echo -e "${OK} qcow2 disk created at ${DISK_PATH}.${RESET}"
        else
            echo -e "${FAIL} Failed to create qcow2 disk at ${DISK_PATH}.${RESET}"
            return
        fi
    fi

    echo -ne "${CYAN}VM Memory in MB (default: 2048): ${RESET}"
    read -r RAM_MB
    [[ -z "$RAM_MB" ]] && RAM_MB=2048

    echo -ne "${CYAN}Number of vCPUs (default: 2): ${RESET}"
    read -r VCPUS
    [[ -z "$VCPUS" ]] && VCPUS=2

    echo
    echo -e "${CYAN}Network mode:${RESET}"
    echo -e "  [1] Single NIC (default)"
    echo -e "  [2] Dual NIC (WAN + LAN/DMZ)"
    echo

    read -rp "Select option [1-2, ENTER=1]: " NET_MODE

    case "$NET_MODE" in
    	""|1)
	        NET_MODE=1
	        echo -e "${INFO} Using network mode: Single NIC.${RESET}"
	        ;;
	    2)
	        NET_MODE=2
	        echo -e "${INFO} Using network mode: Dual NIC (WAN + LAN/DMZ).${RESET}"
	        ;;
	    *)
        	echo -e "${FAIL} Invalid option. Aborting VM creation.${RESET}"
        	return
        	;;
    esac

    echo -e "${CYAN} Libvirt network for primary NIC:${RESET}"

# pega só os nomes das redes
mapfile -t NETS < <(virsh net-list --all --name | awk 'NF {print $1}')

    if [[ ${#NETS[@]} -eq 0 ]]; then
    	echo -e "${FAIL} No libvirt networks found. Create one in virt-manager first.${RESET}"
    	return
    fi

    echo -e "${INFO} Available networks:${RESET}"
    for i in "${!NETS[@]}"; do
    	echo "  [$((i+1))] ${NETS[$i]}"
    done
    echo

    read -rp "Select network [1-${#NETS[@]}] (ENTER=${NETS[0]}): " NET_CHOICE

    if [[ -z "$NET_CHOICE" ]]; then
   	 NET_NAME1="${NETS[0]}"
    else
   	idx=$((NET_CHOICE-1))
   	if (( idx < 0 || idx >= ${#NETS[@]} )); then
        echo -e "${FAIL} Invalid option. Aborting VM creation.${RESET}"
        return
    fi
    NET_NAME1="${NETS[$idx]}"
    fi

    echo -e "${INFO} Using primary network: '${NET_NAME1}'${RESET}"

    ensure_libvirt_net "$NET_NAME1" || return

    # remove espaços em branco no começo/fim e espaços internos estranhos
    NET_NAME1="$(echo "$NET_NAME1_RAW" | tr -d '\r' | xargs)"

    # se ficar vazio, usa default
    [[ -z "$NET_NAME1" ]] && NET_NAME1="default"

    echo -e "${INFO} Using primary network: '${NET_NAME1}'${RESET}"

    ensure_libvirt_net "$NET_NAME1" || return


    # 🔹 Segunda interface (opcional, só se NET_MODE=2)
    NET_NAME2=""
    if [[ "$NET_MODE" == "2" ]]; then
        echo -e "${CYAN} Libvirt network for secondary NIC (DMZ / internal / pivot):${RESET}"
        echo -e "${INFO} Available networks:${RESET}"
        virsh net-list --all
        read -r NET_NAME2
        if [[ -z "$NET_NAME2" ]]; then
            echo -e "${WARN} No secondary network provided. Falling back to single NIC mode.${RESET}"
            NET_MODE=1
        else
            ensure_libvirt_net "$NET_NAME2" || return
        fi
    fi

    # 🔹 Montar XML das interfaces (1 ou 2, conforme escolha)
    local IFACE1_XML IFACE2_XML
    IFACE1_XML="    <interface type='network'>
      <source network='${NET_NAME1}'/>
      <model type='virtio'/>
    </interface>"

    IFACE2_XML=""
    if [[ "$NET_MODE" == "2" && -n "$NET_NAME2" ]]; then
        IFACE2_XML="    <interface type='network'>
      <source network='${NET_NAME2}'/>
      <model type='virtio'/>
    </interface>"
    fi

    echo -ne "${CYAN} Path to ISO for boot/installation (e.g.: /isos/win10.iso): ${RESET}"
    read -r ISO_PATH

    echo -e "${INFO} Defining VM ${VM_NAME} via virsh...${RESET}"

    if [[ -n "$ISO_PATH" ]]; then
        # VM with installation ISO
        if virsh define /dev/stdin <<EOF >/dev/null 2>&1
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${RAM_MB}</memory>
  <vcpu placement='static'>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='cdrom'/>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${ISO_PATH}'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
${IFACE1_XML}
${IFACE2_XML}
    <graphics type='spice' autoport='yes'/>
  </devices>
</domain>
EOF
        then
            echo -e "${OK} VM ${VM_NAME} defined successfully.${RESET}"
            log_msg INFO "VM ${VM_NAME} created with disk ${DISK_PATH}, RAM=${RAM_MB}MB, vCPUs=${VCPUS}, NET1=${NET_NAME1}, NET2=${NET_NAME2}, ISO=${ISO_PATH}."
        else
            echo -e "${FAIL} Failed to define VM ${VM_NAME}.${RESET}"
            log_msg ERROR "Failed to define VM ${VM_NAME} with ISO."
            return
        fi
    else
        # VM without ISO (boot ready)
        if virsh define /dev/stdin <<EOF >/dev/null 2>&1
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${RAM_MB}</memory>
  <vcpu placement='static'>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
${IFACE1_XML}
${IFACE2_XML}
    <graphics type='spice' autoport='yes'/>
  </devices>
</domain>
EOF
        then
            echo -e "${OK} VM ${VM_NAME} defined successfully (no ISO).${RESET}"
            log_msg INFO "VM ${VM_NAME} created (no ISO), disk=${DISK_PATH}, RAM=${RAM_MB}MB, vCPUs=${VCPUS}, NET1=${NET_NAME1}, NET2=${NET_NAME2}."
        else
            echo -e "${FAIL} Failed to define VM ${VM_NAME}.${RESET}"
            log_msg ERROR "Failed to define VM ${VM_NAME} (no ISO)."
            return
        fi
    fi

    echo
    echo -ne "${CYAN}Do you want to start VM ${VM_NAME} now (y/N)? ${RESET}"
    read -r start_ans
    if [[ "$start_ans" =~ ^[Yy]$ ]]; then
        # Garantir que as redes necessárias estão ativas
        ensure_libvirt_net "$NET_NAME1" || return
        if [[ -n "$NET_NAME2" ]]; then
            ensure_libvirt_net "$NET_NAME2" || return
        fi

        if virsh start "$VM_NAME" >/dev/null 2>&1; then
            echo -e "${OK} VM ${VM_NAME} started.${RESET}"
            log_msg INFO "VM ${VM_NAME} started after creation."
            offer_ssh_after_actions "$VM_NAME"
        else
            echo -e "${FAIL} Failed to start VM ${VM_NAME}.${RESET}"
            log_msg ERROR "Failed to start VM ${VM_NAME} after creation."
        fi
    else
        echo -e "${INFO} VM created, but not started now.${RESET}"
    fi
}

#-----------------------------------------------------------
# Function: vm_show_all_vms
# Module:   VM Manager
# Purpose:
#   Display all libvirt-managed VMs with basic information
#   such as ID, name and state.
#
# Inputs:
#   - None
#
# Outputs:
#   - Table printed using 'virsh list --all'.
#
# Side effects:
#   - None (read-only operation).
#
# Notes:
#   - Useful as a quick overview before performing VM actions.
#-----------------------------------------------------------

vm_show_all_vms() {
    echo
    echo -e "${INFO} Listing VMs (virsh list --all)...${RESET}"
    virsh list --all
}

#-----------------------------------------------
# Function: vm_tune_vm_resources
# Module:   VM Manager
# Purpose:  Adjust RAM, vCPU count, and optionally ballooning
#           for an existing VM.
#
# Inputs:
#   - VM selected via hnm_select_vm.
#   - User defines new RAM (MiB) and CPU count.
#
# Outputs:
#   - Prints updated resources and success/failure messages.
#
# Side effects:
#   - Applies settings via:
#       virsh setmem
#       virsh setvcpus
#   - May require VM reboot depending on hypervisor.
#   - Logs every modification with log_msg.
#
# Notes:
#   - Supports both live (running) and config (persistent)
#     changes when available.
#-----------------------------------------------

vm_tune_vm_resources() {
    echo
    draw_menu_title "ADJUST VM RESOURCES (CPU / MEMORY / NIC / USB)"
    echo ""

    # Select VM using arrow-key menu
    local VM_NAME
    VM_NAME=$(hnm_select_vm) || { echo -e "${WARN}Operation canceled.${RESET}"; return; }

    local STATE
    STATE=$(virsh --connect qemu:///system domstate "$VM_NAME" 2>/dev/null) || {
        echo -e "${FAIL} VM ${VM_NAME} not found.${RESET}"
        return
    }

    echo -e "${INFO} Current state of VM ${VM_NAME}: ${STATE}.${RESET}"

    #
    # 1) CPU / MEMORY
    #
    echo -ne "${CYAN}New memory in MB (Enter to keep current): ${RESET}"
    read -r NEW_MEM
    echo -ne "${CYAN}New number of vCPUs (Enter to keep current): ${RESET}"
    read -r NEW_VCPUS

    if [[ -n "$NEW_MEM" ]]; then
        echo -e "${INFO} Adjusting memory to ${NEW_MEM}MiB (persistent config)...${RESET}"
        virsh --connect qemu:///system setmem "$VM_NAME" "${NEW_MEM}MiB" --config >/dev/null 2>&1 \
            && echo -e "${OK} Memory adjusted.${RESET}" \
            || echo -e "${FAIL} Failed to adjust memory (VM might need to be off).${RESET}"
    fi

    if [[ -n "$NEW_VCPUS" ]]; then
        echo -e "${INFO} Adjusting vCPUs to ${NEW_VCPUS} (persistent config)...${RESET}"
        virsh --connect qemu:///system setvcpus "$VM_NAME" "$NEW_VCPUS" --config >/dev/null 2>&1 \
            && echo -e "${OK} vCPUs adjusted.${RESET}" \
            || echo -e "${FAIL} Failed to adjust vCPUs (VM might need to be off).${RESET}"
    fi

    if [[ -z "$NEW_MEM" && -z "$NEW_VCPUS" ]]; then
        echo -e "${WARN} No CPU or memory changes requested for VM ${VM_NAME}.${RESET}"
    fi

    #
    # 2) ADD NETWORK INTERFACE
    #
    echo
    echo -ne "${CYAN}Add a NEW network interface to this VM? (y/N): ${RESET}"
    read -r ADD_NIC
    if [[ "$ADD_NIC" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Available libvirt networks:${RESET}"
        virsh --connect qemu:///system net-list --all

        echo -ne "${CYAN}Network name to attach (e.g. default, vlan, dmz_web): ${RESET}"
        read -r NET_NAME
        NET_NAME=$(echo "$NET_NAME" | xargs)

        if [[ -z "$NET_NAME" ]]; then
            echo -e "${WARN} No network selected. Skipping NIC attach.${RESET}"
        else
            echo -e "${INFO}Attaching NIC (virtio) to network '${NET_NAME}' on VM ${VM_NAME}...${RESET}"
            if [[ "$STATE" == "running" ]]; then
                # live + persistent
                if virsh --connect qemu:///system attach-interface \
                        --domain "$VM_NAME" \
                        --type network \
                        --source "$NET_NAME" \
                        --model virtio \
                        --config --live >/dev/null 2>&1; then
                    echo -e "${OK} New NIC attached (live + persistent).${RESET}"
                else
                    echo -e "${FAIL} Failed to attach NIC (check network name, model, and VM state).${RESET}"
                fi
            else
                # only persistent (will appear next boot)
                if virsh --connect qemu:///system attach-interface \
                        --domain "$VM_NAME" \
                        --type network \
                        --source "$NET_NAME" \
                        --model virtio \
                        --config >/dev/null 2>&1; then
                    echo -e "${OK} New NIC added to VM (will be active on next start).${RESET}"
                else
                    echo -e "${FAIL} Failed to attach NIC to powered-off VM.${RESET}"
                fi
            fi
        fi
    fi

    #
    # 3) ATTACH USB DEVICE (HOSTDEV)
    #
    echo
    echo -ne "${CYAN}Attach a USB device from the HOST to this VM? (y/N): ${RESET}"
    read -r ADD_USB
    if [[ "$ADD_USB" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}Host USB devices (lsusb):${RESET}"
        lsusb
        echo
        echo -ne "${CYAN}Enter USB IDs in the form vendor:product (e.g. 046d:c534): ${RESET}"
        read -r USB_ID

        if [[ -z "$USB_ID" ]]; then
            echo -e "${WARN}No USB ID provided. Skipping USB attach.${RESET}"
        else
            local VENDOR PROD XML_USB
            VENDOR="0x${USB_ID%%:*}"
            PROD="0x${USB_ID##*:}"
            XML_USB="/tmp/${VM_NAME}-usb-${USB_ID}.xml"

            cat > "$XML_USB" <<EOF
<hostdev mode='subsystem' type='usb'>
  <source>
    <vendor id='${VENDOR}'/>
    <product id='${PROD}'/>
  </source>
</hostdev>
EOF

            echo -e "${INFO}Attaching USB device ${USB_ID} to VM ${VM_NAME}...${RESET}"
            # --config: persist in XML; --live: hot-plug if running
            if [[ "$STATE" == "running" ]]; then
                if virsh --connect qemu:///system attach-device "$VM_NAME" "$XML_USB" --config --live >/dev/null 2>&1; then
                    echo -e "${OK} USB device attached (live + persistent).${RESET}"
                else
                    echo -e "${FAIL} Failed to attach USB device to running VM.${RESET}"
                fi
            else
                if virsh --connect qemu:///system attach-device "$VM_NAME" "$XML_USB" --config >/dev/null 2>&1; then
                    echo -e "${OK} USB device added (will be attached on next start).${RESET}"
                else
                    echo -e "${FAIL} Failed to attach USB device to powered-off VM.${RESET}"
                fi
            fi
        fi
    fi

    echo
    echo -e "${INFO} VM tuning finished for ${VM_NAME}.${RESET}"
}


#-----------------------------------------------------------
# Function: vm_check_images_space
# Module:   VM Manager
# Purpose:
#   Show disk usage information for the image directory
#   and warn about low free space before creating or
#   cloning VMs.
#
# Inputs:
#   - HNM_IMAGE_DIR (global)
#
# Outputs:
#   - Human-readable disk statistics (df, du, etc).
#
# Side effects:
#   - None, except console output and optional logging.
#
# Notes:
#   - Typically called before large downloads or clones.
#-----------------------------------------------------------

vm_check_images_space() {
    local IMG_DIR="$HNM_IMAGE_DIR"
    echo
    echo -e "${INFO} Disk usage in ${IMG_DIR}:${RESET}"
    df -h "$IMG_DIR"
}

#-----------------------------------------------
# Function: vm_clone_vm
# Module:   VM Manager
# Purpose:  Clone an existing KVM/libvirt VM into a new
#           VM with its own disk image, preferably via
#           virt-clone (virtinst).
#
# Inputs:
#   - Interactively asks for:
#       source VM (template)   -> selected via hnm_select_vm
#       new VM name
#       target disk directory (default: $HNM_IMAGE_DIR)
#       disk filename for the clone (e.g. NEWVM.qcow2)
#
# Outputs:
#   - On success with virt-clone:
#       - New libvirt domain defined.
#       - New disk image created.
#   - On failure:
#       - Error message and log entry.
#
# Side effects:
#   - Runs virt-clone when available.
#   - Creates directories if needed.
#   - Logs operations with log_msg.
#
# Typical usage:
#   - Called from VM Management Menu, option:
#       "Clone VM (virt-clone)"
#-----------------------------------------------

vm_clone_vm() {
    echo
    draw_menu_title "CLONE EXISTING VM"
   #echo -e "${CYAN}==== CLONE EXISTING VM ====${RESET}"
    echo ""

    # Select source VM (template) using arrow-key menu
    local SRC_VM
    echo -e "${CYAN} Select source VM (template) to clone:${RESET}"
    SRC_VM=$(hnm_select_vm) || { echo -e "${WARN} Operation canceled.${RESET}"; return; }

    echo -e "${INFO} Source VM: ${SRC_VM}${RESET}"
    echo ""

    # New VM name
    echo -e "${CYAN}New VM name (clone):${RESET}"
    read -r NEW_VM
    NEW_VM=$(echo "$NEW_VM" | xargs)
    [[ -z "$NEW_VM" ]] && { echo -e "${FAIL} New VM name cannot be empty.${RESET}"; return; }

    # Disk directory
    local DEFAULT_IMG_DIR="$HNM_IMAGE_DIR"
    echo -e "${CYAN} New disk directory (default: ${DEFAULT_IMG_DIR}):${RESET}"
    read -r NEW_DIR
    NEW_DIR=$(echo "$NEW_DIR" | xargs)
    [[ -z "$NEW_DIR" ]] && NEW_DIR="$DEFAULT_IMG_DIR"
    mkdir -p "$NEW_DIR" || { echo -e "${FAIL}Could not create ${NEW_DIR}.${RESET}"; return; }

    # Disk file name
    echo -e "${CYAN} Clone's disk file name (e.g.: ${NEW_VM}.qcow2):${RESET}"
    read -r NEW_DISK
    NEW_DISK=$(echo "$NEW_DISK" | xargs)
    [[ -z "$NEW_DISK" ]] && NEW_DISK="${NEW_VM}.qcow2"
    local NEW_DISK_PATH="${NEW_DIR%/}/${NEW_DISK}"

    # Try to use virt-clone (virtinst package)
    if command -v virt-clone >/dev/null 2>&1; then
        echo -e "${INFO} Cloning VM using virt-clone...${RESET}"
        if virt-clone -o "$SRC_VM" -n "$NEW_VM" -f "$NEW_DISK_PATH"; then
            echo -e "${OK} VM ${NEW_VM} cloned with disk ${NEW_DISK_PATH}.${RESET}"
            log_msg INFO "VM ${NEW_VM} cloned from ${SRC_VM} (disk ${NEW_DISK_PATH})."
        else
            echo -e "${FAIL} Failed to clone VM with virt-clone.${RESET}"
            log_msg ERROR "Failed to clone VM ${SRC_VM} -> ${NEW_VM}."
        fi
        return
    fi

    # If virt-clone doesn't exist, just warn
    echo -e "${WARN} virt-clone not found. Install the 'virtinst' package for automatic cloning.${RESET}"
    log_msg WARN "virt-clone missing in vm_clone_vm."
    echo -e "${INFO} You can still clone manually with virsh + qemu-img.${RESET}"
}

#-----------------------------------------------
# Function: vm_guess_ip
# Module:   VM Manager
# Purpose:  Attempt a best-effort IP discovery for a VM.
#
# Strategy:
#   1. Query QEMU Guest Agent (most accurate)
#   2. Fallback to ARP table by MAC address
#
# Inputs:
#   - $1 : VM name
#
# Outputs:
#   - Prints guessed IP or empty string.
#
# Side effects:
#   - Reads ARP cache via ip neigh.
#
# Notes:
#   - Used by SSH helpers and VM connection menu.
#-----------------------------------------------

vm_guess_ip() {
    local VM_NAME="$1"
    local ip mac net_type net_src bridge_if cidr leases_file line
    local try max_tries=8   # 8 tries (~16s)

    for try in $(seq 1 "$max_tries"); do
        # 1) Try virsh domifaddr (qemu-guest-agent / DHCP info)
        ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null \
             | awk 'NR>2 && $4 ~ /\// {sub("/.*","",$4); print $4; exit}')
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi

        # 2) Get interface info: type, source (network/bridge) and MAC
        #    Ex: default  network  vnet0  virtio  52:54:00:aa:bb:cc
        read -r net_name net_type net_src _ mac <<<"$(virsh domiflist "$VM_NAME" 2>/dev/null \
            | awk 'NR>2 && NF {print $1,$2,$3,$4,$5; exit}')"

        # 2a) Try via libvirt leases (for internal NAT networks)
        if [[ -n "$mac" ]]; then
            for leases_file in /var/lib/libvirt/dnsmasq/*.leases; do
                [[ -f "$leases_file" ]] || continue
                line=$(grep -i "$mac" "$leases_file" 2>/dev/null | tail -n1)
                if [[ -n "$line" ]]; then
                    ip=$(awk '{print $3}' <<<"$line")
                    if [[ -n "$ip" ]]; then
                        echo "$ip"
                        return 0
                    fi
                fi
            done
        fi

        # 2b) If arp-scan is installed, try to discover via ARP
        if command -v arp-scan &>/dev/null && [[ -n "$mac" ]]; then
            # Determine physical/bridge interface used
            if [[ "$net_type" == "network" && -n "$net_name" ]]; then
                # Get bridge from libvirt network (e.g.: virbr0)
                bridge_if=$(virsh net-info "$net_name" 2>/dev/null \
                             | awk '/Bridge:/{print $2}')
            elif [[ "$net_type" == "bridge" && -n "$net_src" ]]; then
                # VM connected directly to a host bridge (br0, br_lab...)
                bridge_if="$net_src"
            fi

            # Discover the interface's CIDR
            if [[ -n "$bridge_if" ]]; then
                cidr=$(ip -4 addr show dev "$bridge_if" 2>/dev/null \
                       | awk '/inet /{print $2; exit}')
                if [[ -n "$cidr" ]]; then
                    # Do a quick ARP scan on that network
                    line=$(arp-scan --interface="$bridge_if" "$cidr" 2>/dev/null \
                           | grep -i "$mac" | head -n1)
                    if [[ -n "$line" ]]; then
                        ip=$(awk '{print $1}' <<<"$line")
                        if [[ -n "$ip" ]]; then
                            echo "$ip"
                            return 0
                        fi
                    fi
                fi
            fi
        fi

        # If still not found, wait a bit and try again
        sleep 2
    done

    # If we got here, couldn't discover
    return 1
}

#-----------------------------------------------
# Function: vm_guess_ip_quick
# Module:   VM Manager
# Purpose:  Lightweight IP discovery without full interface
#           enumeration. Useful for fast menu operations.
#
# Inputs:
#   - $1 : VM name
#
# Outputs:
#   - Echoes best guess (string) or empty.
#
# Notes:
#   - Prefers QEMU Guest Agent.
#   - Does not perform full ARP scanning like vm_guess_ip.
#-----------------------------------------------

vm_guess_ip_quick() {
    local VM_NAME="$1"
    local ip mac net_type net_src bridge_if cidr leases_file line

    # 1) virsh domifaddr
    ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null \
         | awk 'NR>2 && $4 ~ /\// {sub("/.*","",$4); print $4; exit}')
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }

    # 2) Interface info
    read -r net_name net_type net_src _ mac <<<"$(virsh domiflist "$VM_NAME" 2>/dev/null \
        | awk 'NR>2 && NF {print $1,$2,$3,$4,$5; exit}')"

    # 2a) Libvirt leases
    if [[ -n "$mac" ]]; then
        for leases_file in /var/lib/libvirt/dnsmasq/*.leases; do
            [[ -f "$leases_file" ]] || continue
            line=$(grep -i "$mac" "$leases_file" 2>/dev/null | tail -n1)
            if [[ -n "$line" ]]; then
                ip=$(awk '{print $3}' <<<"$line")
                [[ -n "$ip" ]] && { echo "$ip"; return 0; }
            fi
        done
    fi

    # 2b) Quick arp-scan (if it exists)
    if command -v arp-scan &>/dev/null && [[ -n "$mac" ]]; then
        if [[ "$net_type" == "network" && -n "$net_name" ]]; then
            bridge_if=$(virsh net-info "$net_name" 2>/dev/null | awk '/Bridge:/{print $2}')
        elif [[ "$net_type" == "bridge" && -n "$net_src" ]]; then
            bridge_if="$net_src"
        fi

        if [[ -n "$bridge_if" ]]; then
            cidr=$(ip -4 addr show dev "$bridge_if" 2>/dev/null \
                   | awk '/inet /{print $2; exit}')
            if [[ -n "$cidr" ]]; then
                line=$(arp-scan --interface="$bridge_if" "$cidr" 2>/dev/null \
                       | grep -i "$mac" | head -n1)
                if [[ -n "$line" ]]; then
                    ip=$(awk '{print $1}' <<<"$line")
                    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
                fi
            fi
        fi
    fi

    return 1
}

#-----------------------------------------------
# Function: hnm_list_vms_with_ips
# Module:   VM Manager
# Purpose:  Display all VMs with detected IP addresses,
#           using QEMU Guest Agent when available,
#           otherwise falling back to ARP lookup.
#
# Inputs:
#   - None
#
# Outputs:
#   - Table showing:
#       VM name
#       Power state
#       Detected IP addresses (possibly multiple)
#
# Side effects:
#   - Calls virsh domifaddr and ip neigh.
#
# Notes:
#   - Multi-NIC support.
#   - Purely informational (no mutations).
#-----------------------------------------------

hnm_list_vms_with_ips() {
    draw_menu_title "VMs (virsh) with IP detection (multi-NIC)"
    echo

    printf "%-18s %-12s %s\n" "VM" "State" "IP(s) detected"
    echo "---------------------------------------------------------------"

    local VMS VM STATE GA_OUT ARP_OUT MAIN_IP ALL_IPS

    VMS=$(virsh --connect qemu:///system list --all 2>/dev/null \
        | awk 'NR>2 && $2!="" {print $2}' \
        | sort -f)

    if [[ -z "$VMS" ]]; then
        echo -e "${FAIL} No VMs found via libvirt (qemu:///system).${RESET}"
        return 1
    fi

    for VM in $VMS; do
        STATE=$(virsh --connect qemu:///system domstate "$VM" 2>/dev/null)
        MAIN_IP="N/A"
        ALL_IPS=""

        if [[ "$STATE" == "running" ]]; then
            # Coleta IPs do guest agent, tudo em UMA LINHA
            GA_OUT=$(virsh --connect qemu:///system domifaddr "$VM" --source agent --full 2>/dev/null \
                        | awk 'NR>2 && $4!="-"{print $4}' \
                        | xargs)   # <- junta em "ip1 ip2 ip3"

            if [[ -n "$GA_OUT" ]]; then
                # Todos os IPs em CSV: "ip1, ip2, ip3"
                ALL_IPS=${GA_OUT// /, }

                # Escolhe MAIN_IP (prefere IPv4)
                local addr
                for addr in $GA_OUT; do
                    [[ -z "$addr" ]] && continue
                    if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]{1,2}))?$ ]]; then
                        MAIN_IP="$addr"
                        break
                    fi
                    [[ "$MAIN_IP" == "N/A" ]] && MAIN_IP="$addr"
                done
            fi

            # Fallback via ARP se não achou nada
            if [[ "$MAIN_IP" == "N/A" ]]; then
                ARP_OUT=$(ip neigh 2>/dev/null | awk 'NF>=5 {print $1}' | head -n1)
                [[ -n "$ARP_OUT" ]] && MAIN_IP="$ARP_OUT"
                [[ -z "$ALL_IPS" && -n "$ARP_OUT" ]] && ALL_IPS="$ARP_OUT"
            fi
        fi

        # Se ainda estiver vazio, usa MAIN_IP ou “N/A”
        [[ -z "$ALL_IPS" ]] && ALL_IPS="$MAIN_IP"
        [[ -z "$ALL_IPS" ]] && ALL_IPS="N/A"

        printf "%-18s %-12s %s\n" "$VM" "$STATE" "$ALL_IPS"
    done

    echo
}


#-----------------------------------------------
# Function: vm_connect_existing
# Module:   VM Manager
# Purpose:  Connect to a running VM via SSH or RDP/RFB,
#           depending on how the user chooses.
#
# Inputs:
#   - VM selected via hnm_select_vm or manual entry.
#   - Auto-detected IP from vm_guess_ip_quick or user input.
#
# Outputs:
#   - Launches user’s preferred terminal or Remmina profile.
#
# Side effects:
#   - Calls:
#       launch_ssh_in_terminal
#       open_vm_console_auto
#   - Logs operations with log_msg.
#
# Notes:
#   - Very commonly used after VM creation or power operations.
#-----------------------------------------------

vm_connect_existing() {
   #echo
    draw_menu_title "Connect to existing VM"
    #echo -e "${GREEN_TITLE}==== Connect to existing VM ====${RESET}"
    #echo ""

    # Show VMs (informational)
    #echo -e "${CYAN}VMs:${RESET}"
    #virsh net-list --all 2>/dev/null || echo "  (virsh unavailable)"
    #echo
    #virsh list --all 2>/dev/null || true
    echo

    # Select VM using arrow-key menu
    local VM_NAME
    VM_NAME=$(hnm_select_vm) || { echo -e "${WARN} Operation canceled.${RESET}"; return; }

    # Check state and, if shut off, offer to start
    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        echo -e "${WARN} VM ${VM_NAME} is in state '${state}'.${RESET}"
        read -r -p "Do you want to start it now? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            echo -e "${INFO} Starting VM ${VM_NAME}...${RESET}"
            if virsh start "$VM_NAME" >/dev/null 2>&1; then
                echo -e "${OK} VM ${VM_NAME} started.${RESET}"
                state="running"
                # give a few seconds for DHCP/guest to come up
                sleep 5
            else
                echo -e "${FAIL} Failed to start VM ${VM_NAME}.${RESET}"
                return
            fi
        else
            echo -e "${INFO} VM will not be started or connected.${RESET}"
            return
        fi
    fi

    # Try to discover IP
    echo -e "${INFO} Attempting to detect IP for VM ${VM_NAME}...${RESET}"
    local VM_IP
    VM_IP="$(vm_guess_ip "$VM_NAME")"

    if [[ -n "$VM_IP" ]]; then
        echo -e "${OK} IP detected: ${VM_IP}.${RESET}"
        offer_ssh_after_actions "$VM_NAME" "$VM_IP"
    else
        echo -e "${WARN} Could not detect IP automatically.${RESET}"
        read -r -p "Enter IP manually (or Enter to cancel): " VM_IP
        if [[ -n "$VM_IP" ]]; then
            offer_ssh_after_actions "$VM_NAME" "$VM_IP"
        else
            echo -e "${INFO} Connection will not be opened.${RESET}"
        fi
    fi
}

#-----------------------------------------------
# Function: vm_snapshot_menu
# Module:   VM Manager
# Purpose:  Interactive snapshot management for a single VM:
#           create, list, revert and remove snapshots using
#           virsh snapshot-* commands.
#
# Inputs:
#   - VM selected via hnm_select_vm.
#   - Snapshot names entered by user or auto-generated.
#
# Outputs:
#   - Prints current snapshot list and status messages.
#   - Exit when user selects "Back".
#
# Side effects:
#   - Creates snapshots (virsh snapshot-create-as).
#   - Reverts VM state to selected snapshot
#     (virsh snapshot-revert).
#   - Removes snapshots (virsh snapshot-delete).
#   - Logs key actions via log_msg.
#
# Typical usage:
#   - Called from VM Management Menu, option:
#       "VM Snapshot (create / list / revert / remove)"
#-----------------------------------------------

vm_snapshot_menu() {
    echo
    clear
    draw_menu_title "VM SNAPSHOT MANAGEMENT"
    #echo -e "${CYAN}==== VM SNAPSHOT MANAGEMENT ====${RESET}"
    echo ""

    # Select VM using arrow-key menu (hnm_select_vm)
    local VM_NAME
    VM_NAME=$(hnm_select_vm) || { echo -e "${WARN} Operation canceled.${RESET}"; return; }

    while true; do
        local SNAP_MENU SNAP_SEL op_snap

        echo

        SNAP_MENU=$(
        cat <<EOF
1) Create snapshot
2) List snapshots
3) Revert to snapshot
4) Remove snapshot
0) Back
EOF
        )

        # --- fzf-first interactive menu ---
        if ensure_fzf; then
            SNAP_SEL=$(hnm_select "Snapshot Menu for ${VM_NAME}" "$SNAP_MENU") || continue
            op_snap=$(echo "$SNAP_SEL" | awk '{print $1}' | tr -d ')')
        else
            # fallback normal menu
            echo -e "${WHITE} 1)${GREEN} Create snapshot${RESET}"
            echo -e "${WHITE} 2)${GREEN} List snapshots${RESET}"
            echo -e "${WHITE} 3)${GREEN} Revert to snapshot${RESET}"
            echo -e "${WHITE} 4)${GREEN} Remove snapshot${RESET}"
            echo -e "${WHITE} 0)${RED} Back${RESET}"

            flush_stdin
            read -r -p "Choice: " op_snap
        fi

        case "$op_snap" in
            1)
                echo -e "${CYAN} Snapshot name (leave empty for auto-generated):${RESET}"
                read -r SNAP_NAME
                [[ -z "$SNAP_NAME" ]] && SNAP_NAME="snap_$(date +%Y%m%d_%H%M%S)"

                echo -e "${INFO} Creating snapshot '${SNAP_NAME}' for VM '${VM_NAME}'...${RESET}"
                if virsh snapshot-create-as "$VM_NAME" "$SNAP_NAME" >/dev/null 2>&1; then
                    echo -e "${OK} Snapshot '${SNAP_NAME}' created successfully.${RESET}"
                    log_msg INFO "Snapshot ${SNAP_NAME} created for VM ${VM_NAME}."
                else
                    echo -e "${FAIL} Failed to create snapshot '${SNAP_NAME}'.${RESET}"
                    log_msg ERROR "Failed to create snapshot ${SNAP_NAME} on ${VM_NAME}."
                fi
                ;;

            2)
                echo -e "${INFO} Snapshots for VM '${VM_NAME}':${RESET}"
                virsh snapshot-list "$VM_NAME" 2>/dev/null || \
                    echo -e "${WARN} No snapshots found for this VM.${RESET}"
                ;;

            3)
                # Select snapshot dynamically with fzf menu
                local SNAP_REV
                SNAP_REV=$(hnm_select_snapshot "$VM_NAME") || {
                    echo -e "${WARN}No snapshot selected.${RESET}"
                    continue
                }

                echo -e "${WARN} Reverting to a snapshot is destructive. Are you sure? (y/N)${RESET}"
                read -r ans_rev
                [[ ! "$ans_rev" =~ ^[Yy]$ ]] && continue

                echo -e "${INFO} Reverting VM '${VM_NAME}' to snapshot '${SNAP_REV}'...${RESET}"
                if virsh snapshot-revert "$VM_NAME" "$SNAP_REV" >/dev/null 2>&1; then
                    echo -e "${OK} VM '${VM_NAME}' reverted to snapshot '${SNAP_REV}'.${RESET}"
                    log_msg INFO "VM ${VM_NAME} reverted to snapshot ${SNAP_REV}."
                else
                    echo -e "${FAIL} Failed to revert VM '${VM_NAME}' to snapshot '${SNAP_REV}'.${RESET}"
                    log_msg ERROR "Failed to revert ${VM_NAME} to snapshot ${SNAP_REV}."
                fi
                ;;

            4)
                local SNAP_DEL
                SNAP_DEL=$(hnm_select_snapshot "$VM_NAME") || {
                    echo -e "${WARN}No snapshot selected.${RESET}"
                    continue
                }

                echo -e "${WARN} Snapshot removal is irreversible. Confirm delete '${SNAP_DEL}'? (y/N)${RESET}"
                read -r ans_del
                [[ ! "$ans_del" =~ ^[Yy]$ ]] && continue

                echo -e "${INFO} Removing snapshot '${SNAP_DEL}' from VM '${VM_NAME}'...${RESET}"
                if virsh snapshot-delete "$VM_NAME" "$SNAP_DEL" >/dev/null 2>&1; then
                    echo -e "${OK} Snapshot '${SNAP_DEL}' removed successfully.${RESET}"
                    log_msg INFO "Snapshot ${SNAP_DEL} removed from ${VM_NAME}."
                else
                    echo -e "${FAIL} Failed to remove snapshot '${SNAP_DEL}'.${RESET}"
                    log_msg ERROR "Failed to remove snapshot ${SNAP_DEL} from ${VM_NAME}."
                fi
                ;;

            0)
                echo -e "${INFO} Returning to VM management menu.${RESET}"
                return
                ;;
                
            *)
                echo -e "${FAIL} Invalid option.${RESET}"
                ;;
        esac
    done
}

#-----------------------------------------------
# Function: vm_image_dir_menu
# Module:   VM Manager
# Purpose:  Allow user to inspect, configure and change the
#           directory used for VM images (qcow2, ISO, archives).
#
# Inputs:
#   - Reads/writes:
#       HNM_IMAGE_DIR
#
# Outputs:
#   - Updates config through hnm_save_config.
#
# Side effects:
#   - Creates directories if needed.
#   - Lists existing images.
#
# Notes:
#   - Centralized place to maintain your image library.
#-----------------------------------------------

vm_image_dir_menu() {
    echo ""
    draw_menu_title "VM IMAGE DIRECTORY"
    #echo -e "${GREEN_TITLE}==== VM IMAGE DIRECTORY ====${RESET}"
    echo ""
    echo -e "${INFO} Current directory:${RESET} ${YELLOW}${HNM_IMAGE_DIR}${RESET}"
    echo ""
    echo -e "${CYAN} Enter new directory for ISO/QCOW images (press Enter to keep current):${RESET}"
    read -r -p "> " newdir
    newdir=$(echo "$newdir" | xargs)

    if [[ -z "$newdir" ]]; then
        echo -e "${INFO} Keeping current image directory.${RESET}"
        return
    fi

    if [[ ! -d "$newdir" ]]; then
        echo -e "${WARN} Directory does not exist:${RESET} ${newdir}"
        read -r -p "Create it now? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            if ! mkdir -p "$newdir"; then
                echo -e "${FAIL} Failed to create directory.${RESET}"
                return
            fi
        else
            echo -e "${INFO} Operation canceled.${RESET}"
            return
        fi
    fi

    HNM_IMAGE_DIR="$newdir"
    hnm_save_config
    echo -e "${OK} Image directory set to:${RESET} ${YELLOW}${HNM_IMAGE_DIR}${RESET}"
}

#-----------------------------------------------------------
# Function: read_vm_name_tab_complete
# Module:   VM Manager / UX Helpers
# Purpose:
#   Read a VM name from user input with optional tab-completion
#   support or suggestions based on existing VM names.
#
# Inputs:
#   - Prompt text (parameter or global).
#
# Outputs:
#   - Echoes the chosen VM name on stdout.
#
# Side effects:
#   - May query 'virsh list --all' to provide suggestions.
#
# Notes:
#   - UX helper used where direct hnm_select_vm is not ideal.
#-----------------------------------------------------------

read_vm_name_tab_complete() {
    local __var_name="$1"   # output variable name
    local __prompt="$2"     # prompt text

    local TMP_DIR="/tmp/hnm_vm_complete"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"

    # populate VM list
    if command -v virsh >/dev/null 2>&1; then
        virsh list --all --name | sed '/^$/d' | while read -r vm; do
            : > "${TMP_DIR}/${vm}"
        done
    fi

    local input=""
    pushd "$TMP_DIR" >/dev/null 2>&1

    # -e => readline (arrows, TAB, etc.)
    # TAB now completes "file" names, which are the VM names
    read -r -p "$__prompt" input

    popd >/dev/null 2>&1

    # save result to the indicated variable
    printf -v "$__var_name" '%s' "$input"
}

#-----------------------------------------------------------
# Function: check_disk_space
# Module:   VM Manager / Safety Helpers
# Purpose:
#   Verify if there is enough free disk space on the target
#   filesystem before creating or expanding VM disk images.
#
# Inputs:
#   - Target directory path
#   - Required size (in MiB or GiB, depending on implementation)
#
# Outputs:
#   - Returns 0 if space is sufficient.
#   - Returns non-zero if not enough space is available.
#
# Side effects:
#   - Prints warnings/errors to the console.
#
# Notes:
#   - Called from vm_create_simple_vm and vm_clone_vm to
#     avoid failed image creations due to low disk space.
#-----------------------------------------------------------

check_disk_space() {
    local target_dir="$1"
    local min_gb="$2"

    [[ -z "$target_dir" ]] && target_dir="/"
    [[ -z "$min_gb" ]] && min_gb=5

    # Get free space in GB (integer)
    local avail_gb
    avail_gb=$(df -BG "$target_dir" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')

    if [[ -z "$avail_gb" ]]; then
        echo -e "${WARN} Could not get free space in ${target_dir}.${RESET}"
        log_msg WARN "check_disk_space: couldn't read df for ${target_dir}."
        return 1
    fi

    if (( avail_gb < min_gb )); then
        echo -e "${FAIL} Insufficient space in ${target_dir}: available ${avail_gb}G, required >= ${min_gb}G.${RESET}"
        log_msg ERROR "Insufficient space in ${target_dir} (free ${avail_gb}G, need ${min_gb}G)."
        return 1
    fi

    echo -e "${OK} Sufficient space in ${target_dir} (${avail_gb}G free, minimum ${min_gb}G).${RESET}"
    log_msg INFO "Space OK in ${target_dir} (${avail_gb}G free, minimum ${min_gb}G)."
    return 0
}

#-----------------------------------------------
# Function: launch_ssh_in_terminal
# Module:   VM Manager
# Purpose:  Spawn a new terminal and open an SSH session
#           to a VM using its auto-detected or user-provided IP.
#
# Inputs:
#   - $1 : IP address
#   - Optional: configured username or default ("alex", "root", etc.)
#
# Outputs:
#   - Launches system terminal emulator with SSH command.
#
# Side effects:
#   - Opens external process.
#   - Logs session attempt.
#
# Notes:
#   - Customized based on user’s terminal (gnome-terminal,
#     konsole, xfce-terminal, etc.).
#-----------------------------------------------

launch_ssh_in_terminal() {
    # $1 = VM name (optional, just for message)
    # $2 = VM IP
    local VM_NAME="$1"
    local VM_IP="$2"

    # If VM name is not provided, let the user pick one (for nicer messages/logs)
    if [[ -z "$VM_NAME" ]]; then
        echo ""
        echo -e "${CYAN} No VM name provided. Select a VM for SSH (optional, used only for display/logs):${RESET}"
        VM_NAME=$(hnm_select_vm) || VM_NAME="(no name)"
    fi

    if [[ -z "$VM_IP" ]]; then
        echo -e "${FAIL} VM IP not provided for SSH connection.${RESET}"
        return
    fi

    echo ""
    echo -e "${CYAN} SSH connection for VM ${VM_NAME}${RESET}"
    echo -e "${CYAN} Target IP: ${VM_IP}${RESET}"

    # suggest current user as default
    read -r -p "User for SSH (e.g., kali, root, administrator) [default: ${USER}]: " SSH_USER
    [[ -z "$SSH_USER" ]] && SSH_USER="$USER"

    local SSH_TARGET="${SSH_USER}@${VM_IP}"
    echo ""
    echo -e "${INFO} Opening SSH for ${SSH_TARGET} in a new terminal...${RESET}"

    # Try Tilix, then Konsole, GNOME Terminal, and finally xterm
    if command -v tilix >/dev/null 2>&1; then
        tilix -e bash -lc "ssh ${SSH_TARGET}; echo; read -n1 -rsp 'Press any key to close...';" &
    elif command -v konsole >/dev/null 2>&1; then
        konsole --noclose -e bash -lc "ssh ${SSH_TARGET}; echo; read -n1 -rsp 'Press any key to close...';" &
    elif command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal -- bash -lc 'ssh '"${SSH_TARGET}"'; echo; read -n1 -rsp "Press any key to close...";' &
    elif command -v xterm >/dev/null 2>&1; then
        xterm -e "ssh ${SSH_TARGET}" &
    else
        # fallback: no new terminal, just so we don't leave the user hanging
        echo -e "${WARN} No graphical terminal (tilix/konsole/gnome-terminal/xterm) found.${RESET}"
        echo -e "${INFO} Starting SSH in the current session...${RESET}"
        ssh "${SSH_TARGET}"
    fi
}

#-----------------------------------------------
# Function: open_vm_console_auto
# Module:   VM Manager
# Purpose:  Automatically detect the best available console
#           method for a VM and open it (virt-viewer, spice,
#           VNC socket, or "virsh console").
#
# Inputs:
#   - VM name
#
# Outputs:
#   - Opens GUI or TUI console.
#
# Side effects:
#   - Runs external tools:
#       virt-viewer
#       remote-viewer
#       virsh console
#
# Notes:
#   - Intelligent fallback chain to guarantee console access
#     even in minimal installations.
#-----------------------------------------------

open_vm_console_auto() {
    local VM_NAME="$1"
    local uri

    # If no VM_NAME provided, let the user select one with arrows
    if [[ -z "$VM_NAME" ]]; then
        echo ""
        echo -e "${CYAN}No VM name provided. Select a VM to open console:${RESET}"
        VM_NAME=$(hnm_select_vm) || { echo -e "${WARN}Operation canceled.${RESET}"; return 1; }
    fi

    # First try to get the VM's graphical URI (SPICE or VNC)
    uri=$(virsh domdisplay "$VM_NAME" 2>/dev/null)

    if [[ -n "$uri" ]]; then
        echo -e "${INFO} Graphical URI for ${VM_NAME}: ${uri}${RESET}"

        # remote-viewer is the most common for SPICE/VNC
        if command -v remote-viewer &>/dev/null; then
            echo -e "${INFO} Opening console with remote-viewer...${RESET}"
            remote-viewer "$uri" &>/dev/null &
            return 0
        fi

        # fallback: virt-viewer directly by name
        if command -v virt-viewer &>/dev/null; then
            echo -e "${INFO} Opening console with virt-viewer...${RESET}"
            virt-viewer "$VM_NAME" &>/dev/null &
            return 0
        fi
    fi

    # If domdisplay didn't work or no remote-viewer/virt-viewer, try virt-manager
    if command -v virt-manager &>/dev/null; then
        echo -e "${INFO} Opening console with virt-manager...${RESET}"
        virt-manager --connect qemu:///system --show-domain-console "$VM_NAME" &>/dev/null &
        return 0
    fi

    echo -e "${FAIL} No graphical tool found to open console (remote-viewer / virt-viewer / virt-manager).${RESET}"
    echo -e "${WARN} Install one of them (e.g., 'virt-viewer' or 'virt-manager' package) to use this function.${RESET}"
    return 1
}

#-----------------------------------------------
# Function: offer_ssh_after_actions
# Module:   VM Manager
# Purpose:  After creating/starting a VM, offer automatic
#           SSH connection to user based on quick IP detection.
#
# Inputs:
#   - $1 : VM name
#   - $2 : Optional (skip prompt flag)
#
# Outputs:
#   - “Connect now?” prompt and action.
#
# Side effects:
#   - May call launch_ssh_in_terminal.
#
# Notes:
#   - Frequently used right after vm_create_simple_vm or
#     vm_power_menu → start.
#-----------------------------------------------

offer_ssh_after_actions() {
    local VM_NAME="$1"
    local VM_IP="$2"


        echo ""
        echo -e "${CYAN} Do you want to access VM ${VM_NAME}?${RESET}"

        local MENU OPTIONS SEL OPT
        OPTIONS=$(
            cat <<EOF
1) SSH in new terminal
2) Graphical access (Remmina / SPICE)
3) Adjust VM network (bridge / VLAN – open VM networks menu)
0) Do nothing
EOF
        )

        # Try arrow-key menu with hnm_select
        if ensure_fzf; then
            SEL=$(hnm_select "Select action for VM ${VM_NAME}" "$OPTIONS") || {
                echo -e "${INFO} No connection opened for ${VM_NAME}.${RESET}"
                break
            }
            OPT=$(echo "$SEL" | awk '{print $1}' | tr -d ')')
        else
            # Fallback: classic numeric menu
            echo -e "${WHITE}1)${GREEN} SSH in new terminal${RESET}"
            echo -e "${WHITE}2)${GREEN} Graphical access (Remmina / SPICE)${RESET}"
            echo -e "${WHITE}3)${GREEN} Adjust VM network (bridge / VLAN – open VM networks menu)${RESET}"
            echo -e "${WHITE}0)${RED} Do nothing${RESET}"
            flush_stdin
            read -r -p "Choice: " OPT
        fi

        echo ""
        case "$OPT" in
            1)
                launch_ssh_in_terminal "$VM_NAME" "$VM_IP"
                ;;
            2)
                launch_gui_connection "$VM_NAME" "$VM_IP"
                ;;
            3)
                echo ""
                echo -e "${INFO} Opening VM networks MENU to adjust network for VM ${VM_NAME}.${RESET}"
                echo -e "${INFO} Use the VLAN/bridge options to move the VM to another network.${RESET}"
                vm_menu
                ;;
            0|"" )
                echo -e "${INFO} No connection opened for ${VM_NAME}.${RESET}"
                ;;
            *)
                echo -e "${FAIL} Invalid option.${RESET}"
                ;;
        esac

}

#-----------------------------------------------------------
# Function: download_and_extract_images
# Module:   VM Manager
# Purpose:
#   Download VM images (ISO, qcow2, archives such as .zip,
#   .tar.gz, .7z) from a URL or local path and extract them
#   into HNM_IMAGE_DIR.
#
# Inputs:
#   - User-provided URL or local file path.
#   - HNM_IMAGE_DIR (global destination).
#
# Outputs:
#   - One or more image files available in HNM_IMAGE_DIR.
#
# Side effects:
#   - Uses tools like curl/wget and decompression programs
#     (unzip, tar, 7z, etc.).
#   - May create subdirectories inside HNM_IMAGE_DIR.
#
# Notes:
#   - Called by vm_download_image_vm_mgr as a wrapper entry.
#-----------------------------------------------------------

download_and_extract_images() {
    echo
    echo -ne "${CYAN}Image URL (qcow2/ISO/tar/zip, etc.): ${RESET}"
    read -r IMG_URL
    if [[ -z "$IMG_URL" ]]; then
        echo -e "${WARN} Empty URL. Aborting download.${RESET}"
        return
    fi

    echo -ne "${CYAN}Destination folder (default: /media/alex/ISO1): ${RESET}"
    read -r DEST_DIR
    [[ -z "$DEST_DIR" ]] && DEST_DIR="$HNM_IMAGE_DIR"

    mkdir -p "$DEST_DIR" || {
        echo -e "${FAIL} Could not create ${DEST_DIR}.${RESET}"
        return
    }

    echo -ne "${CYAN}Estimated file size in GB (default: 5): ${RESET}"
    read -r EST_GB
    [[ -z "$EST_GB" ]] && EST_GB=5

    # Check disk space before downloading
    if ! check_disk_space "$DEST_DIR" "$EST_GB"; then
        echo -e "${FAIL} Aborting download due to lack of space.${RESET}"
        return
    fi

    echo -ne "${CYAN}File name (no path, e.g.: dc-ad.qcow2 or lab.tar.gz): ${RESET}"
    read -r DEST_NAME
    if [[ -z "$DEST_NAME" ]]; then
        DEST_NAME=$(basename "$IMG_URL")
        echo -e "${INFO} Using detected name: ${DEST_NAME}${RESET}"
    fi

    local DEST_PATH="${DEST_DIR%/}/${DEST_NAME}"

    echo -e "${INFO} Downloading ${IMG_URL} to ${DEST_PATH}...${RESET}"
    log_msg INFO "Downloading image from ${IMG_URL} to ${DEST_PATH}."

    if command -v curl >/dev/null 2>&1; then
        curl -L "$IMG_URL" -o "$DEST_PATH"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$DEST_PATH" "$IMG_URL"
    else
        echo -e "${FAIL} Neither curl nor wget are installed.${RESET}"
        log_msg ERROR "download_and_extract_images failed: no curl/wget."
        return
    fi

    if [[ $? -ne 0 ]]; then
        echo -e "${FAIL} Failed to download ${IMG_URL}.${RESET}"
        log_msg ERROR "Failed to download ${IMG_URL}."
        return
    fi

    echo -e "${OK} Download complete: ${DEST_PATH}${RESET}"
    log_msg INFO "Download complete: ${DEST_PATH}."

    # Offer to unpack if it's tar/zip etc.
    case "$DEST_PATH" in
        *.tar|*.tar.gz|*.tgz|*.tar.xz|*.zip)
            echo -ne "${CYAN} File appears to be an archive. Do you want to extract (y/N)? ${RESET}"
            read -r ans_ext
            if [[ "$ans_ext" =~ ^[Yy]$ ]]; then
                echo -e "${INFO} Extracting in ${DEST_DIR}...${RESET}"
                (
                    cd "$DEST_DIR" || exit 1
                    case "$DEST_PATH" in
                        *.tar)         tar xf "$DEST_PATH" ;;
                        *.tar.gz|*.tgz) tar xzf "$DEST_PATH" ;;
                        *.tar.xz)      tar xJf "$DEST_PATH" ;;
                        *.zip)         unzip -o "$DEST_PATH" ;;
                    esac
                )
                if [[ $? -eq 0 ]]; then
                    echo -e "${OK} Extraction complete in ${DEST_DIR}.${RESET}"
                    log_msg INFO "Extraction complete from ${DEST_PATH} in ${DEST_DIR}."
                else
                    echo -e "${FAIL} Failed to extract ${DEST_PATH}.${RESET}"
                    log_msg ERROR "Failed to extract ${DEST_PATH}."
                fi
            else
                echo -e "${INFO} Extraction not performed (user chose not to extract).${RESET}"
            fi
            ;;
        *)
            echo -e "${INFO} File does not appear to be tar/zip. No extraction performed.${RESET}"
            ;;
    esac
}

#-----------------------------------------------------------
# Function: launch_gui_connection
# Module:   VM Manager / GUI Helpers
# Purpose:
#   Launch a graphical remote access client (e.g. Remmina)
#   preconfigured to connect to the target VM using RDP,
#   VNC or SSH, depending on the chosen protocol.
#
# Inputs:
#   - Target IP or hostname.
#   - Protocol / profile name (RDP, VNC, SSH).
#
# Outputs:
#   - Starts external GUI client for remote access.
#
# Side effects:
#   - Spawns a separate process (Remmina or similar).
#   - Requires optional dependency (e.g. remmina).
#
# Notes:
#   - Complements open_vm_console_auto and SSH helpers.
#-----------------------------------------------------------

launch_gui_connection() {
    local vm_name="$1"
    local vm_ip="$2"

    echo ""
    draw_menu_title "GRAPHICAL CONNECTION FOR VM ${vm_name} (${vm_ip})"
    #echo -e "${CYAN}==== GRAPHICAL CONNECTION FOR VM ${vm_name} (${vm_ip}) ====${RESET}"
    echo ""

    local GUI_MENU GUI_SEL GUI_OPT
    GUI_MENU=$(
        cat <<EOF
1) RDP via Remmina (Windows/AD)
2) VNC via Remmina
3) SPICE (virt-viewer)
0) Cancel
EOF
    )

    # Try arrow-key selection using hnm_select
    if ensure_fzf; then
        GUI_SEL=$(hnm_select "Select the type of graphical connection for VM ${vm_name}" "$GUI_MENU") || {
            echo -e "${INFO} No graphical connection will be opened.${RESET}"
            return
        }
        GUI_OPT=$(echo "$GUI_SEL" | awk '{print $1}' | tr -d ')')
    else
        # Fallback to classic numeric menu
        echo -e "${CYAN}Select the type of graphical connection for VM ${vm_name}:${RESET}"
        echo -e "${WHITE}1)${GREEN} RDP via Remmina (Windows/AD)${RESET}"
        echo -e "${WHITE}2)${GREEN} VNC via Remmina${RESET}"
        echo -e "${WHITE}3)${GREEN} SPICE (virt-viewer)${RESET}"
        echo -e "${WHITE}0)${RED} Cancel${RESET}"
        flush_stdin
        read -r -p "Choice: " GUI_OPT
    fi

    case "$GUI_OPT" in
        1)
            if ! command -v remmina >/dev/null 2>&1; then
                echo -e "${WARN} Remmina is not installed.${RESET}"
                read -r -p "Do you want to install Remmina (RDP plugin)? (y/N): " inst
                if [[ "$inst" =~ ^[Yy]$ ]]; then
                    apt-get update -y >/dev/null 2>&1
                    apt-get install -y remmina-plugin-rdp remmina >/dev/null 2>&1
                else
                    echo -e "${FAIL} Remmina not installed. Aborting connection.${RESET}"
                    return
                fi
            fi
            echo -e "${INFO} Opening RDP via Remmina to ${vm_ip}...${RESET}"
            nohup remmina -c "rdp://$vm_ip" >/dev/null 2>&1 &
            ;;
        2)
            if ! command -v remmina >/dev/null 2>&1; then
                echo -e "${WARN} Remmina is not installed.${RESET}"
                read -r -p "Do you want to install Remmina (VNC plugin)? (y/N): " inst
                if [[ "$inst" =~ ^[Yy]$ ]]; then
                    apt-get update -y >/dev/null 2>&1
                    apt-get install -y remmina remmina-plugin-vnc >/dev/null 2>&1
                else
                    echo -e "${FAIL} Remmina not installed. Aborting connection.${RESET}"
                    return
                fi
            fi
            echo -e "${INFO} Opening VNC via Remmina to ${vm_ip}:5900...${RESET}"
            nohup remmina -c "vnc://$vm_ip:5900" >/dev/null 2>&1 &
            ;;
        3)
            if ! command -v virt-viewer >/dev/null 2>&1; then
                echo -e "${WARN} virt-viewer is not installed.${RESET}"
                read -r -p "Do you want to install virt-viewer? (y/N): " inst
                if [[ "$inst" =~ ^[Yy]$ ]]; then
                    apt-get update -y >/dev/null 2>&1
                    apt-get install -y virt-viewer >/dev/null 2>&1
                else
                    echo -e "${FAIL}virt-viewer not installed. Aborting.${RESET}"
                    return
                fi
            fi
            echo -e "${INFO} Opening SPICE console for VM '${vm_name}'...${RESET}"
            nohup virt-viewer --connect qemu:///system "$vm_name" >/dev/null 2>&1 &
            ;;
        0|""|*)
            echo -e "${INFO} No graphical connection will be opened.${RESET}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# select_vms_fzf
#
# Objetivo:
#   Permitir selecionar uma ou mais VMs do libvirt usando fzf em modo
#   multi-seleção e devolver os nomes escolhidos em uma única linha
#   (separados por espaço).
#
# Entradas (globais):
#   (nenhuma obrigatória; usa virsh para listar VMs)
#
# Saídas:
#   stdout - linha única com nomes de VMs separados por espaço
#            (ex: "win10 kali-lab dc01")
#
# Dependências:
#   fzf, virsh, awk
#
# Retorno:
#   0 - seleção feita
#   1 - se fzf não existir, retorna vazio e o chamador trata fallback
#
# Observação:
#   No futuro, pode ser reescrito usando um helper genérico como
#   hnm_select_multi() para reduzir repetição de código fzf.
# ---------------------------------------------------------------------------
select_vms_fzf() {
    # Ensure fzf exists
    if ! command -v fzf >/dev/null 2>&1; then
        echo -e "${WARN} fzf is not installed. Falling back to manual entry.${RESET}" >&2
        return
    fi

    # Get only the VM NAMES (column 2)
    local vms
    vms=$(virsh list --all | awk 'NR>2 {print $2}')

    if [[ -z "$vms" ]]; then
        echo ""
        return
    fi

    selected=$(
        printf '%s\n' "$vms" | fzf -m \
            --prompt="VMs > " \
            --header="↑/↓ navigate | TAB select | ENTER confirm" \
            --ansi
    )

    # Output: one line with space-separated names
    echo "$selected" | tr '\n' ' '
}

