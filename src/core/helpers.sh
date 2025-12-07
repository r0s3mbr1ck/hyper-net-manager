#############################################
# MODULE: Core / Helpers & Globals
# -------------------------------------------
# - Banner information and app metadata
# - Global paths/config (HNM_CONFIG_FILE, etc.)
# - Colors and status labels
# - Ctrl+C handler and stdin flush
# - Logging and state persistence
# - Dependency checking (nmcli, virsh, etc.)
# - Generic selectors (fzf-based) and VM listing
#############################################

#############################
# BANNER INFORMATION        #
#############################
APP_VERSION="1.0.4v"
APP_AUTHOR="Lead Developer: Alex Marano"
APP_AI="AI-Assisted Build"
APP_EMAIL="Support: alex_marano87@hotmail.com"
APP_INFO="${APP_VERSION}  |  ${APP_AUTHOR}  |  ${APP_AI}  |  ${APP_EMAIL}"

#############################
#             GLOBAL COLORS         #
#############################
RED="\e[31m";   GREEN="\e[32m";   YELLOW="\e[33m"
BLUE="\e[96m";  PURPLE="\e[95m";  CYAN="\e[36m"
WHITE="\e[97m"; RESET="\e[0m"
BOLD="\e[1m"
GREEN_TITLE="${BOLD}${GREEN}"
OK="${GREEN}[ OK ]${RESET}"
FAIL="${RED}[ FAIL ]${RESET}"
WARN="${YELLOW}[ ! ]${RESET}"
INFO="${CYAN}[ INFO ]${RESET}"
PROMPT=">>"
STATE_FILE="/root/.hyper-net-manager-nm.state"
XML_BACKUP_DIR="/root/vm-xml-backups"
LOG_FILE="/var/log/hyper-net-manager.log"

#############################
#             GLOBAL CONFIG         #
#############################
STATE_FILE="/root/.hyper-net-manager-nm.state"
XML_BACKUP_DIR="/root/vm-xml-backups"
LOG_FILE="/var/log/hyper-net-manager.log"

#------------------------------------------------------------------------------
# _menu_titldrawe()
# Purpose : Draw a full-width centered title bar using '=' characters.
# Usage   : draw_menu_title "MAIN MENU"
#------------------------------------------------------------------------------
draw_menu_title() {
    local title="$1"
    local width
    width=$(tput cols 2>/dev/null || echo 80)

    local inner=" ${title} "
    local inner_len=${#inner}

    # Se o texto for maior que a largura, só imprime o texto
    if (( inner_len >= width )); then
        echo -e "${BOLD}${BLUE}${inner}${RESET}"
        return
    fi

    local pad_total=$(( width - inner_len ))
    local pad_left=$(( pad_total / 2 ))
    local pad_right=$(( pad_total - pad_left ))

    local left right
    left=$(printf '%*s' "$pad_left" '' | tr ' ' '=')
    right=$(printf '%*s' "$pad_right" '' | tr ' ' '=')

    echo -e "${BOLD}${BLUE}${left}${inner}${right}${RESET}"
}

#------------------------------------------------------------------------------
# flush_stdin()
# Purpose : Clear any pending keystrokes from stdin (including ESC sequences).
# Module  : Global Helpers
# Used by : All menus before 'read' to avoid "ghost" keypresses.
#------------------------------------------------------------------------------
flush_stdin() {
    while IFS= read -r -t 0.01 -n 1 _; do
        : # discard
    done 2>/dev/null || true
}

#------------------------------------------------------------------------------
# hnm_init_kvm_qemu_libvirt()
# Purpose : Verify that libvirt (qemu:///system) is reachable and ready.
# Module  : Global Helpers
# Notes   :
#   - Fails fast with a clear message if libvirt is not accessible.
#   - Helps detect missing services or group membership issues early.
#------------------------------------------------------------------------------
hnm_init_kvm_qemu_libvirt() {
    if ! command -v virsh >/dev/null 2>&1; then
        echo -e "${FAIL} [ERROR] 'virsh' command not found. Is libvirt installed?${RESET}"
        exit 1
    fi

    # Silent connection test
    if ! virsh --connect qemu:///system uri >/dev/null 2>&1; then
        echo -e "${FAIL} [ERROR] Could not connect to libvirt (qemu:///system).${RESET}"
        echo -e "${WARN} Make sure libvirtd/virtqemud services are running and your user is in libvirt groups.${RESET}"
        exit 1
    fi
}
#------------------------------------------------------------------------------
# hnm_load_config()
# Purpose : Load persistent configuration from HNM_CONFIG_FILE.
# Module  : Global Helpers
# Notes   :
#   - Creates parent directory if needed.
#   - Falls back to HNM_IMAGE_DIR_DEFAULT if no value is stored.
#------------------------------------------------------------------------------

hnm_load_config() {
    mkdir -p "$(dirname "$HNM_CONFIG_FILE")"

    if [[ -f "$HNM_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$HNM_CONFIG_FILE"
    fi

    [[ -z "$HNM_IMAGE_DIR" ]] && HNM_IMAGE_DIR="$HNM_IMAGE_DIR_DEFAULT"
}

#------------------------------------------------------------------------------
# hnm_save_config()
# Purpose : Persist current configuration (e.g. image dir) to disk.
# Module  : Global Helpers
#------------------------------------------------------------------------------
hnm_save_config() {
    mkdir -p "$(dirname "$HNM_CONFIG_FILE")"
    cat > "$HNM_CONFIG_FILE" <<EOF
# Hyper Net Manager configuration
HNM_IMAGE_DIR="$HNM_IMAGE_DIR"
EOF
}

#------------------------------------------------------------------------------
# ctrl_c_handler()
# Purpose : Handle Ctrl+C gracefully and clear input buffer.
# Module  : Global Helpers
#------------------------------------------------------------------------------
ctrl_c_handler() {
    echo -e "\n${WARN} Operation canceled by user (Ctrl+C).${RESET}"
    flush_stdin
}
trap ctrl_c_handler SIGINT

#------------------------------------------------------------------------------
# ensure_fzf()
# Purpose : Ensure that 'fzf' is available for interactive menus.
# Module  : Global Helpers
# Behavior:
#   - If fzf exists, returns 0.
#   - If not, offers to install (apt-get) when available.
#   - If user refuses or install fails, returns 1 and menus fall back to manual.
#------------------------------------------------------------------------------
ensure_fzf() {
    if command -v fzf >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${WARN} 'fzf' is not installed. It is required for arrow-key selection menus.${RESET}"

    if ! command -v apt-get >/dev/null 2>&1; then
        echo -e "${FAIL} Package manager 'apt-get' not found. Please install 'fzf' manually.${RESET}"
        return 1
    fi

    read -rp "Install fzf now using apt-get? [Y/n]: " INSTALL_FZF
    INSTALL_FZF=${INSTALL_FZF:-Y}

    if [[ "$INSTALL_FZF" =~ ^[Yy]$ ]]; then
        echo -e "${INFO} Installing fzf...${RESET}"
        log_msg INFO "Installing fzf for arrow-key selection menus"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y fzf   >/dev/null 2>&1
        if command -v fzf >/dev/null 2>&1; then
            echo -e "${OK} fzf successfully installed.${RESET}"
            return 0
        else
            echo -e "${FAIL} Failed to install fzf. Menus will fall back to manual typing.${RESET}"
            log_msg ERROR "Failed to install fzf"
            return 1
        fi
    else
        echo -e "${WARN} User chose not to install fzf. Menus will fall back to manual typing.${RESET}"
        return 1
    fi
}

#------------------------------------------------------------------------------
# hnm_select()
# Purpose : Generic selector for any list (VMs, interfaces, networks, etc.).
# Module  : Global Helpers
# Usage   :
#   choice=$(hnm_select "Select VM" "$LIST") || return 1
#------------------------------------------------------------------------------
hnm_select() {
    local PROMPT="$1"
    local LIST="$2"
    local CHOICE=""

    if [[ -z "$LIST" ]]; then
        echo -e "${FAIL} No items available for selection (${PROMPT}).${RESET}" >&2
        return 1
    fi

    # Preferred: arrow-key selection with fzf
    if ensure_fzf; then
        local FZF_BIN
        FZF_BIN="$(command -v fzf 2>/dev/null)" || FZF_BIN="fzf"

        CHOICE=$(
            printf "%s\n" "$LIST" \
            | FZF_DEFAULT_OPTS="" "$FZF_BIN" \
                --layout=reverse \
                --no-sort \
                --prompt="${PROMPT} > " \
                --height=15 \
                --border \
                --ansi
        )
    fi

    # Fallback: manual numeric or name-based selection
    if [[ -z "$CHOICE" ]]; then
        echo -e "${CYAN}${PROMPT}:${RESET}" >&2
        echo "----------------------------------------" >&2

        local i=1 line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf " %2d) %s\n" "$i" "$line" >&2
            ((i++))
        done <<< "$LIST"
        echo "----------------------------------------" >&2

        read -rp "Type the item number or name (Enter to cancel): " CHOICE_RAW
        CHOICE_RAW=$(echo "$CHOICE_RAW" | xargs)

        [[ -z "$CHOICE_RAW" ]] && {
            echo -e "${WARN} Operation canceled by user.${RESET}" >&2
            return 1
        }

        if [[ "$CHOICE_RAW" =~ ^[0-9]+$ ]]; then
            local idx=1
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                if [[ "$idx" -eq "$CHOICE_RAW" ]]; then
                    CHOICE="$line"
                    break
                fi
                ((idx++))
            done <<< "$LIST"
        else
            CHOICE="$CHOICE_RAW"
        fi
    fi

    CHOICE=$(echo "$CHOICE" | xargs)  # trim

    if [[ -z "$CHOICE" ]]; then
        echo -e "${WARN} Operation canceled by user.${RESET}" >&2
        return 1
    fi

    printf '%s\n' "$CHOICE"
    return 0
}

#------------------------------------------------------------------------------
# hnm_list_vms_with_ips()
# Purpose : Show all libvirt VMs with detected IP addresses (multi-NIC aware).
# Module  : Global Helpers (VM utility)
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# vm_list_vms_with_ip_multi()
# Purpose : Show all libvirt VMs with detected IP addresses (multi-NIC aware).
#------------------------------------------------------------------------------
vm_list_vms_with_ip_multi() {
    echo
    draw_menu_title "VMs (virsh) with IP detection (multi-NIC)"
    echo

    printf "%-18s %-12s %s\n" "VM" "State" "IP(s) detected"
    echo "---------------------------------------------------------------"

    local VMS VM STATE GA_OUT MAIN_IP ALL_IPS

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
            # IPs via guest agent (IPv4/IPv6, tudo em uma linha)
            GA_OUT=$(virsh --connect qemu:///system domifaddr "$VM" --source agent --full 2>/dev/null \
                        | awk 'NR>2 && $4!="-"{print $4}' \
                        | xargs)

            if [[ -n "$GA_OUT" ]]; then
                ALL_IPS=${GA_OUT// /, }
            fi

            # IP principal padronizado (IPv4 preferido)
            MAIN_IP=$(hnm_get_vm_primary_ip "$VM")
        fi

        [[ -z "$ALL_IPS" ]] && ALL_IPS="$MAIN_IP"
        [[ -z "$ALL_IPS" ]] && ALL_IPS="N/A"

        printf "%-18s %-12s %s\n" "$VM" "$STATE" "$ALL_IPS"
    done

    echo
}


#------------------------------------------------------------------------------
# hnm_get_vm_primary_ip()
# Purpose : Get the primary IPv4 address of a running VM (ignoring loopback).
# Returns : IPv4 (sem /prefix) ou nada se não achar
#------------------------------------------------------------------------------
hnm_get_vm_primary_ip() {
    local VM_NAME="$1"
    local IP=""

    # 1) Tenta via guest agent, ignorando loopback (lo / 127.x)
    IP=$(
        virsh --connect qemu:///system domifaddr "$VM_NAME" --source agent --full 2>/dev/null \
        | awk 'NR>2 && $1!="lo" && $3=="ipv4" {print $4}' \
        | head -n1 \
        | cut -d'/' -f1
    )

    # 2) Sem agent (ou sem IP válido), tenta domifaddr "normal"
    if [[ -z "$IP" ]]; then
        IP=$(
            virsh --connect qemu:///system domifaddr "$VM_NAME" 2>/dev/null \
            | awk 'NR>2 && $3=="ipv4" {print $4}' \
            | head -n1 \
            | cut -d'/' -f1
        )
    fi

    # 3) Último recurso: leases DHCP da rede default
    if [[ -z "$IP" ]]; then
        IP=$(
            virsh --connect qemu:///system net-dhcp-leases default 2>/dev/null \
            | awk -v vm="$VM_NAME" '$0 ~ vm && /ipv4/ {print $5}' \
            | head -n1 \
            | cut -d'/' -f1
        )
    fi

    [[ -n "$IP" ]] && echo "$IP"
}



#------------------------------------------------------------------------------
# hnm_select_vm()
# Purpose : Present VMs (with state/IPs) and let user choose one.
# Module  : Global Helpers (VM utility)
# Returns : Selected VM name on stdout.
#------------------------------------------------------------------------------
#------------------------------------------------------------------------------
# hnm_select_vm()
# Purpose : Present VMs (with state/IPs) and let user choose one.
# Returns : Selected VM name on stdout.
#------------------------------------------------------------------------------
hnm_select_vm() {
    local VMS
    VMS=$(virsh --connect qemu:///system list --all 2>/dev/null \
        | awk 'NR>2 && $2!="" {print $2}' \
        | sort -f)

    if [[ -z "$VMS" ]]; then
        echo -e "${FAIL} No VMs found via libvirt (qemu:///system).${RESET}"
        return 1
    fi

    local MENU=""
    local VM STATE GA_OUT MAIN_IP ALL_IPS

    for VM in $VMS; do
        STATE=$(virsh --connect qemu:///system domstate "$VM" 2>/dev/null)
        MAIN_IP="N/A"
        ALL_IPS=""

        if [[ "$STATE" == "running" ]]; then
            # IPs via guest agent (para exibir na lista)
            GA_OUT=$(virsh --connect qemu:///system domifaddr "$VM" --source agent --full 2>/dev/null \
                        | awk 'NR>2 && $4!="-"{print $4}' \
                        | xargs)

            if [[ -n "$GA_OUT" ]]; then
                ALL_IPS=${GA_OUT// /, }
            fi

            # IP principal padronizado
            MAIN_IP=$(hnm_get_vm_primary_ip "$VM")
        fi

        [[ -z "$ALL_IPS" ]] && ALL_IPS="$MAIN_IP"
        [[ -z "$ALL_IPS" ]] && ALL_IPS="N/A"

        local LINE
        printf -v LINE "%-18s %-12s %s" "$VM" "[$STATE]" "$ALL_IPS"
        MENU+="${LINE}"$'\n'
    done

    local SEL
    SEL=$(hnm_select "Select VM" "$MENU") || return 1
    echo "$SEL" | awk '{print $1}'
}


hnm_ensure_nmcli() {
    if ! command -v nmcli >/dev/null 2>&1; then
        echo -e "${FAIL} nmcli (NetworkManager) not found. Host connection management requires NetworkManager.${RESET}"
        return 1
    fi

    if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo -e "${WARN} NetworkManager service is not active.${RESET}"
        echo -e "${INFO} Try: sudo systemctl start NetworkManager${RESET}"
        return 1
    fi
    return 0
}

host_nm_manage_wifi() {
    hnm_ensure_nmcli || return 1

    echo
    draw_menu_title "HOST: WIFI CONNECTIONS (NetworkManager)"
    echo

    # Detect Wi-Fi device (ex: wlp4s0)
    local WIFI_IF
    WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
                | awk -F: '$2=="wifi" || $2=="wifi-p2p" || $2=="wlan"{print $1}' \
                | head -n1)

    # Fallback genérico: qualquer TYPE que contenha "wifi"
    if [[ -z "$WIFI_IF" ]]; then
        WIFI_IF=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
                    | awk -F: 'tolower($2) ~ /wifi/ {print $1}' \
                    | head -n1)
    fi

    if [[ -z "$WIFI_IF" ]]; then
        echo -e "${FAIL} No Wi-Fi interface managed by NetworkManager was found.${RESET}"
        return 1
    fi

    # Conexão ativa na interface Wi-Fi
    local ACTIVE_SSID
    ACTIVE_SSID=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
                    | awk -F: -v dev="$WIFI_IF" '$2==dev {print $1; exit}')

    echo -e "${INFO} Wi-Fi interface detected: ${WIFI_IF}${RESET}"
    if [[ -n "$ACTIVE_SSID" ]]; then
        echo -e "${OK} Active Wi-Fi: ${ACTIVE_SSID}.${RESET}"
    else
        echo -e "${WARN} No active Wi-Fi connection.${RESET}"
    fi

    echo
    echo -e "${CYAN}Select an action:${RESET}"

    local WIFI_MENU
    WIFI_MENU=$(
        cat <<EOF
Scan & connect to a Wi-Fi network
Disconnect current Wi-Fi
Manage saved Wi-Fi profiles
Back
EOF
    )

    local ACTION
    ACTION=$(hnm_select "Wi-Fi Action" "$WIFI_MENU") || {
        echo -e "${WARN} Operation canceled.${RESET}"
        return 0
    }

    case "$ACTION" in
                "Scan & connect to a Wi-Fi network")
            # === SCAN WIFI NETWORKS ===
            echo
            echo -e "${INFO} Scanning Wi-Fi networks on ${WIFI_IF}...${RESET}"
            local WIFI_SCAN
            WIFI_SCAN=$(nmcli -t -f SSID,SIGNAL,SECURITY device wifi list ifname "$WIFI_IF" 2>/dev/null \
                            | sed '/^:/d' | sort -t: -k2 -nr)

            if [[ -z "$WIFI_SCAN" ]]; then
                echo -e "${FAIL} No Wi-Fi networks found.${RESET}"
                return 0
            fi

            local MENU="" ssid signal sec line
            while IFS=: read -r ssid signal sec; do
                [[ -z "$ssid" ]] && continue
                [[ -z "$signal" ]] && signal="?"

                # Montar barra de sinal em 10 blocos
                local bar signal_disp
                bar=""
                if [[ "$signal" =~ ^[0-9]+$ ]]; then
                    local full=$(( signal / 10 ))
                    (( full > 10 )) && full=10
                    local empty=$(( 10 - full ))
                    local i
                    for (( i=0; i<full;  i++ )); do bar+="█"; done
                    for (( i=0; i<empty; i++ )); do bar+="░"; done
                    signal_disp="${bar} ${signal}%"
                else
                    signal_disp="???????? ${signal}"
                fi

                [[ -z "$sec" ]] && sec="--"
                printf -v line "%-32s %-16s %-14s" "$ssid" "$signal_disp" "$sec"
                MENU+="${line}"$'\n'
            done <<< "$WIFI_SCAN"

            echo -e "${CYAN}Select Wi-Fi network:${RESET}"
            local SEL SSID
            SEL=$(hnm_select "Wi-Fi SSID" "$MENU") || return 0
            SSID=$(echo "$SEL" | sed 's/[[:space:]].*$//')

            echo
            echo -e "${INFO} Connecting to '${SSID}' on ${WIFI_IF}...${RESET}"

            # 1ª tentativa: usa perfil salvo, se existir e estiver ok
            if nmcli device wifi connect "$SSID" ifname "$WIFI_IF" >/dev/null 2>&1; then
                echo -e "${OK} Connected to ${SSID}.${RESET}"
                return 0
            fi

            echo -e "${WARN} Connection failed. Network '${SSID}' may require credentials.${RESET}"
            echo -e "${INFO} Trying interactive nmcli (--ask). You may be prompted for password/username.${RESET}"
            echo

            # 2ª tentativa: nmcli pergunta tudo o que precisa
            if nmcli --ask device wifi connect "$SSID" ifname "$WIFI_IF"; then
                echo -e "${OK} Connected to ${SSID}.${RESET}"
                return 0
            fi

            # Se ainda falhar, pode haver um perfil quebrado com esse nome
            echo -e "${WARN} Connection still failed.${RESET}"
            local HAS_PROFILE=0
            if nmcli -t -f NAME,TYPE connection show 2>/dev/null \
                | awk -F: -v s="$SSID" '($1==s && ($2=="wifi" || $2=="802-11-wireless")) {found=1} END {exit !found}'; then
                HAS_PROFILE=1
            fi

            if [[ "$HAS_PROFILE" -eq 1 ]]; then
                echo -e "${WARN} An existing Wi-Fi profile named '${SSID}' was found."
                echo -e "It may be corrupted (e.g., missing key-mgmt).${RESET}"
                echo -ne "${CYAN}Delete profile '${SSID}' and retry with interactive wizard? (y/N): ${RESET}"
                local yn
                read -r yn
                if [[ "$yn" =~ ^[Yy]$ ]]; then
                    nmcli connection delete "$SSID" >/dev/null 2>&1 || true
                    echo -e "${INFO} Profile deleted. Retrying with nmcli --ask...${RESET}"
                    echo
                    if nmcli --ask device wifi connect "$SSID" ifname "$WIFI_IF"; then
                        echo -e "${OK} Connected to ${SSID}.${RESET}"
                        return 0
                    else
                        echo -e "${FAIL} Failed to connect to ${SSID} even after deleting the profile.${RESET}"
                        return 0
                    fi
                fi
            fi

            echo -e "${FAIL} Failed to connect to ${SSID}.${RESET}"
            echo -e "${INFO} Tip: you can inspect/delete profiles with:${RESET}"
            echo -e "      nmcli -t -f NAME,TYPE connection show | grep -i wifi"
            echo -e "      nmcli connection delete \"${SSID}\""
            ;;

        "Disconnect current Wi-Fi")
            if [[ -z "$ACTIVE_SSID" ]]; then
                echo -e "${WARN} No active Wi-Fi to disconnect.${RESET}"
            else
                echo -e "${INFO} Disconnecting Wi-Fi '${ACTIVE_SSID}'...${RESET}"
                if nmcli connection down "$ACTIVE_SSID" >/dev/null 2>&1; then
                    echo -e "${OK} Wi-Fi disconnected.${RESET}"
                else
                    if nmcli device disconnect "$WIFI_IF" >/dev/null 2>&1; then
                        echo -e "${OK} Wi-Fi device ${WIFI_IF} disconnected.${RESET}"
                    else
                        echo -e "${FAIL} Failed to disconnect Wi-Fi.${RESET}"
                    fi
                fi
            fi
            ;;

        "Manage saved Wi-Fi profiles")
            local SAVED LIST PROFILE
            SAVED=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
                        | awk -F: '$2=="wifi" || $2=="802-11-wireless" || tolower($2) ~ /wifi/ {print $1}')

            if [[ -z "$SAVED" ]]; then
                echo -e "${WARN} No saved Wi-Fi profiles.${RESET}"
                return 0
            fi

            LIST=""
            while read -r PROFILE; do
                [[ -z "$PROFILE" ]] && continue
                LIST+="${PROFILE}"$'\n'
            done <<< "$SAVED"

            echo -e "${CYAN}Select a Wi-Fi profile to delete:${RESET}"
            local SEL_PROF
            SEL_PROF=$(hnm_select "Saved Wi-Fi profiles" "$LIST") || return 0
            local PROF_NAME="$SEL_PROF"

            echo -e "${WARN} Delete Wi-Fi profile '${PROF_NAME}'? (y/N)${RESET}"
            read -r yn
            [[ ! "$yn" =~ ^[Yy]$ ]] && return 0

            if nmcli connection delete "$PROF_NAME" >/dev/null 2>&1; then
                echo -e "${OK} Profile deleted.${RESET}"
            else
                echo -e "${FAIL} Failed to delete profile.${RESET}"
            fi
            ;;

        "Back")
            return 0
            ;;
    esac

    echo
    read -r -p "Press ENTER to return to the host menu..." _
    return 0
}


host_nm_manage_vpn() {
    hnm_ensure_nmcli || return 1

    echo
    draw_menu_title "HOST: VPN CONNECTIONS (NetworkManager)"
    echo

    local VPN_CONNS VPN_MENU line name state
    VPN_CONNS=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="vpn"{print $1}')

    if [[ -z "$VPN_CONNS" ]]; then
        echo -e "${WARN} No VPN connections configured in NetworkManager.${RESET}"
        return 0
    fi

    VPN_MENU=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        state=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: -v n="$line" '$1==n && $2=="vpn"{print "active"}')
        [[ -z "$state" ]] && state="inactive"
        VPN_MENU+="${line}  [${state}]"$'\n'
    done <<< "$VPN_CONNS"

    echo -e "${CYAN}Select a VPN connection:${RESET}"
    local SEL
    SEL=$(hnm_select "VPN connection" "$VPN_MENU") || {
        echo -e "${WARN} Operation canceled.${RESET}"
        return 0
    }

    local VPN_NAME VPN_STATE
    VPN_NAME=$(echo "$SEL" | awk '{print $1}')
    VPN_STATE=$(echo "$SEL" | awk '{print $2}' | tr -d '[]')

    if [[ "$VPN_STATE" == "active" ]]; then
        echo -ne "${CYAN}VPN '${VPN_NAME}' is active. Disconnect it? (y/N): ${RESET}"
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            if nmcli connection down "$VPN_NAME" >/dev/null 2>&1; then
                echo -e "${OK} VPN '${VPN_NAME}' disconnected.${RESET}"
            else
                echo -e "${FAIL} Failed to disconnect VPN '${VPN_NAME}'.${RESET}"
            fi
        fi
    else
        echo -ne "${CYAN}VPN '${VPN_NAME}' is inactive. Connect it now? (y/N): ${RESET}"
        read -r ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            if nmcli connection up "$VPN_NAME" >/dev/null 2>&1; then
                echo -e "${OK} VPN '${VPN_NAME}' connected.${RESET}"
            else
                echo -e "${FAIL} Failed to connect VPN '${VPN_NAME}'.${RESET}"
            fi
        fi
    fi
}

host_nm_ensure_wifi_for_bridge() {
    hnm_ensure_nmcli || return 1

    # Já existe Wi-Fi ativo?
    local ACTIVE_WIFI
    ACTIVE_WIFI=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null \
                    | awk -F: '$2=="wifi"{print $1":"$3}' | head -n1)

    if [[ -n "$ACTIVE_WIFI" ]]; then
        local name dev
        name=${ACTIVE_WIFI%%:*}
        dev=${ACTIVE_WIFI##*:}
        echo -e "${OK} Wi-Fi already active: ${name} on ${dev}.${RESET}"
        return 0
    fi

    echo -e "${WARN} No active Wi-Fi connection detected. Bridge mode works best with Wi-Fi providing internet.${RESET}"
    echo -ne "${CYAN}Open Wi-Fi connection manager now to connect to a network? (y/N): ${RESET}"
    read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        host_nm_manage_wifi
    fi

    # Re-check
    ACTIVE_WIFI=$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="wifi"{print $1}' | head -n1)
    if [[ -z "$ACTIVE_WIFI" ]]; then
        echo -e "${FAIL} No active Wi-Fi connection after Wi-Fi manager. Aborting bridge activation.${RESET}"
        return 1
    fi
    echo -e "${OK} Wi-Fi connected. Proceeding with bridge activation.${RESET}"
    return 0
}

#------------------------------------------------------------------------------
# log_msg()
# Purpose : Append a structured log line to LOG_FILE and also echo to stdout.
# Module  : Global Helpers
# Params  :
#   $1 - log level (INFO, WARN, ERROR, DEBUG, etc.)
#   $2 - message text
#------------------------------------------------------------------------------
log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$ts] [$level] $msg" >> "$LOG_FILE"

    case "$level" in
        INFO)  echo -e "${INFO} $msg${RESET}" ;;
        WARN)  echo -e "${WARN} $msg${RESET}" ;;
        ERROR) echo -e "${FAIL} $msg${RESET}" ;;
        *)     echo -e "${CYAN}[$level]${RESET} $msg" ;;
    esac
}

open_new_terminal() {
    local CMD="$1"

    if command -v tilix >/dev/null 2>&1; then
        tilix -e bash -c "$CMD; echo; read -p 'Press ENTER to close this window...' _"
    elif command -v konsole >/dev/null 2>&1; then
        konsole --hold -e bash -c "$CMD"
    elif command -v xfce4-terminal >/dev/null 2>&1; then
        xfce4-terminal --hold -e bash -c "$CMD"
    elif command -v gnome-terminal >/dev/null 2>&1; then
        gnome-terminal -- bash -c "$CMD; echo; read -p 'Press ENTER to close this window...' _"
    else
        echo -e "${WARN} No supported graphical terminal found. Running inline in this shell...${RESET}"
        bash -c "$CMD"
    fi
}

hnm_validate_ipv4() {
    local ip="$1"
    # regex simples de IPv4
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"

    for o in "$o1" "$o2" "$o3" "$o4"; do
        if (( o < 0 || o > 255 )); then
            return 1
        fi
    done

    return 0
}


#------------------------------------------------------------------------------
# ensure_libvirt_net()
# Purpose : Ensure a given libvirt network exists and is active.
# Module  : Global Helpers (VM networking utility)
# Params  :
#   $1 - libvirt network name
#------------------------------------------------------------------------------
ensure_libvirt_net() {
    local NET_NAME="$1"

    if [[ -z "$NET_NAME" ]]; then
        echo -e "${FAIL} No libvirt network name provided.${RESET}"
        return 1
    fi

    # Mostra qual libvirt está sendo usado
    echo -e "${INFO} Using libvirt URI: $(virsh uri 2>/dev/null)${RESET}"

    echo -e "${INFO} Checking libvirt network '${NET_NAME}'...${RESET}"

    # 1) Já está ativa?
    if virsh net-list --name | awk 'NF {print $1}' | grep -x "$NET_NAME" >/dev/null 2>&1; then
        echo -e "${OK} Libvirt network '${NET_NAME}' is already active.${RESET}"
        return 0
    fi

    # 2) Existe mas está inativa?
    if virsh net-list --all --name | awk 'NF {print $1}' | grep -x "$NET_NAME" >/dev/null 2>&1; then
        echo -e "${WARN} Libvirt network '${NET_NAME}' is defined but not active. Trying to start it...${RESET}"

        # NÃO esconda o erro do virsh
        if virsh net-start "$NET_NAME"; then
            echo -e "${OK} Libvirt network '${NET_NAME}' started.${RESET}"
            return 0
        else
            echo -e "${FAIL} virsh failed to start libvirt network '${NET_NAME}'. See error above.${RESET}"
            echo -e "${INFO} TIP: test manually with:${RESET}"
            echo -e "      sudo virsh -c qemu:///system net-start '${NET_NAME}'"
            return 1
        fi
    fi

    # 3) Não existe
    echo -e "${FAIL} Libvirt network '${NET_NAME}' does not exist on this libvirt URI.${RESET}"
    echo -e "${INFO} Create it via virt-manager (Virtual Networks) or 'virsh net-define'.${RESET}"
    return 1
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

# ------------------------------------------------------------------------------
# FUNCTION: hnm_menu_select
#
# Purpose:
#   Generic interactive menu wrapper that presents a list of options and returns
#   the selected one. Can use fzf or a simple numbered menu.
#
# Inputs (globals):
#   None
#
# Outputs (globals):
#   None
#
# Output (stdout):
#   Selected option text or identifier
#
# External Commands:
#   fzf (optional), read, printf
#
# Depends On:
#   ensure_fzf, hnm_select, flush_stdin
#
# Returns:
#   0 on successful selection
#   non-zero if user cancels or invalid choice is made
#
# Notes:
#   Base for several higher-level menus (host, VM, labs).
# ----------------------------------------------------------------------------------------------------------------------------------------------------
hnm_menu_select() {
    local PROMPT="$1"
    local MENU_LIST="$2"
    local ITEM
    ITEM=$(hnm_select "$PROMPT" "$MENU_LIST") || return 1
    echo "$ITEM" | awk '{print $1}' | tr -d ')'
}

# ------------------------------------------------------------------------------
# FUNCTION: hnm_select_network
#
# Purpose:
#   Present a list of available libvirt networks and let the user choose one.
#
# Inputs (globals):
#   None
#
# Outputs (globals):
#   None
#
# Output (stdout):
#   Selected libvirt network name
#
# External Commands:
#   virsh, fzf (optional), read
#
# Depends On:
#   hnm_menu_select, ensure_libvirt_net (indirectly), log_msg
#
# Returns:
#   0 on successful selection
#   non-zero if selection is canceled or no networks exist
#
# Notes:
#   Used whenever the user needs to attach VMs to a specific virtual network.
# ------------------------------------------------------------------------------

hnm_select_network() {
    local NET_LIST NET_NAME

    NET_LIST=$(virsh net-list --all --name 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d')

    if [[ -z "$NET_LIST" ]]; then
        echo -e "${FAIL} No libvirt networks found.${RESET}" >&2
        echo -e "${INFO} You can create one using the VM NETWORKS menu first.${RESET}" >&2
        log_msg WARN "hnm_select_network: no libvirt networks available"
        return 1
    fi

    NET_NAME=$(hnm_menu_select "Select libvirt network" "$NET_LIST") || return 1
    NET_NAME=$(echo "$NET_NAME" | xargs)

    if ! virsh net-info "$NET_NAME" >/dev/null 2>&1; then
        echo -e "${FAIL} Libvirt network '${NET_NAME}' not found.${RESET}" >&2
        log_msg ERROR "hnm_select_network: network '${NET_NAME}' not found"
        return 1
    fi

    printf '%s\n' "$NET_NAME"
    return 0
}

# ------------------------------------------------------------------------------
# FUNCTION: show_banner
#
# Purpose:
#   Clear the terminal (on first call) and display the HNM ASCII banner and
#   basic information (version, author, etc.).
#
# Inputs (globals):
#   APP_VERSION, APP_AUTHOR, APP_AI, APP_EMAIL, color variables
#
# Outputs (globals):
#   None
#
# External Commands:
#   clear, echo, cat
#
# Depends On:
#   None
#
# Returns:
#   0 always
#
# Notes:
#   Typically called once when the main menu is first displayed.
# ------------------------------------------------------------------------------

show_banner() {
    clear

    GREEN="\e[1;32m"
    LIGHTGREEN="\e[92m"
    RESET="\e[0m"

    # ASCII HNM
    read -r -d '' HNM_ASCII << 'EOF'
██╗  ██╗ ███╗   ██╗ ███╗   ███╗
██║  ██║ ████╗  ██║ ████╗ ████║
███████║ ██╔██╗ ██║ ██╔████╔██║
██╔══██║ ██║╚██╗██║ ██║╚██╔╝██║
██║  ██║ ██║ ╚████║ ██║ ╚═╝ ██║
╚═╝  ╚═╝ ╚═╝  ╚═══╝ ╚═╝     ╚═╝
EOF

    # Terminal width
    TERM_WIDTH=$(tput cols)

    # Find the longest line of ASCII (real width)
    ASCII_WIDTH=0
    while IFS= read -r line; do
        len=${#line}
        (( len > ASCII_WIDTH )) && ASCII_WIDTH=$len
    done <<< "$HNM_ASCII"

    # Left padding to center the entire HNM block
    PAD=$(( (TERM_WIDTH - ASCII_WIDTH) / 2 ))

    echo -e "${GREEN}"
    # Print the centered ASCII
    while IFS= read -r line; do
        printf "%${PAD}s%s\n" "" "$line"
    done <<< "$HNM_ASCII"
    echo -e "${RESET}"

    # ---------- "HYPER NET MANAGER" CENTERED UNDER HNM ----------
    local SUBTITLE="H Y P E R   N E T   M A N A G E R"
    local SUB_LEN=${#SUBTITLE}
    local SUB_PAD=$(( (TERM_WIDTH - SUB_LEN) / 2 ))
    (( SUB_PAD < 0 )) && SUB_PAD=0
    printf "%${SUB_PAD}s${LIGHTGREEN}%s${RESET}\n" "" "$SUBTITLE"

    # ---------- APP INFO (centered red line under subtitle) ----------
    # Linha "cheia"
    local APP_FULL="Version ${APP_VERSION}  |  Lead Developer: Alex Marano  |  AI-Assisted Build  |  Support: alex_marano87@hotmail.com"
    # Linha reduzida, caso o terminal seja estreito
    local APP_SHORT="Version ${APP_VERSION}  |  Lead Dev: Alex Marano  |  Support: alex_marano87@hotmail.com"

    local APP_LINE
    if (( ${#APP_FULL} > TERM_WIDTH )); then
        APP_LINE="$APP_SHORT"
    else
        APP_LINE="$APP_FULL"
    fi

    local APP_LEN=${#APP_LINE}
    local APP_PAD=$(( (TERM_WIDTH - APP_LEN) / 2 ))
    (( APP_PAD < 0 )) && APP_PAD=0

    printf "%${APP_PAD}s${RED}%s${RESET}\n" "" "$APP_LINE"

    if [[ "$HNM_BOOT_SHOWN" -eq 0 ]]; then
    # Metasploit-style boot
	echo ""
	echo -ne "${LIGHTGREEN}[*] Initializing modules"
	sleep 0.3; echo -ne "."
	sleep 0.3; echo -ne "."
	sleep 0.3; echo -ne ".${RESET}"
	echo

    # Progress bar
	echo -ne "${GREEN}["
	for i in {1..30}; do
		echo -ne "#"
        	sleep 0.04
	done
        echo -e "]${RESET}"

	sleep 0.3
	echo -e "${LIGHTGREEN}[*] Loading network engine...${RESET}"
	sleep 0.4
	echo -e "${LIGHTGREEN}[*] Starting virtualization modules...${RESET}"
	sleep 0.4
	echo -e "${LIGHTGREEN}[*] Hyper Net Manager online.${RESET}"
	echo ""
	HNM_BOOT_SHOWN=1     # mark as already shown
    fi
}

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

#------------------------------------------------------------------------------
# is_debian()
# Purpose : Quick check whether the system is Debian-based.
# Module  : Global Helpers
#------------------------------------------------------------------------------
is_debian() { [[ -f /etc/debian_version ]]; }

#------------------------------------------------------------------------------
# pkg_installed()
# Purpose : Check if a dpkg package is installed.
# Module  : Global Helpers
#------------------------------------------------------------------------------
pkg_installed() { dpkg -s "$1" &>/dev/null; }

#------------------------------------------------------------------------------
# ensure_cmd_or_pkg()
# Purpose : Ensure a command exists; if not, offer to install a given package.
# Module  : Global Helpers
#------------------------------------------------------------------------------
ensure_cmd_or_pkg() {
    local cmd="$1" pkg="$2"

    if command -v "$cmd" &>/dev/null; then
        return 0
    fi

    echo -e "${WARN} Command '${cmd}' not found.${RESET}"
    log_msg WARN "Command '${cmd}' not found. Trying to install '${pkg}'."

    if is_debian; then
        read -r -p "Install package '${pkg}' now via apt? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            echo -e "${INFO} Installing package ${pkg}...${RESET}"
            if apt-get update && apt-get install -y "$pkg"; then
                log_msg INFO "Package '${pkg}' installed successfully."
            else
                echo -e "${FAIL} Failed to install ${pkg}.${RESET}"
                log_msg ERROR "Failed to install package '${pkg}'. Aborting."
                exit 1
            fi
        else
            echo -e "${FAIL} Without '${cmd}', the script cannot continue.${RESET}"
            log_msg ERROR "User refused to install '${pkg}' for '${cmd}'. Aborting."
            exit 1
        fi
    else
        echo -e "${FAIL} System does not appear to be Debian. Please install package '${pkg}' manually.${RESET}"
        log_msg ERROR "Non-Debian system and '${cmd}' is missing. Requires '${pkg}'."
        exit 1
    fi
}

#------------------------------------------------------------------------------
# ensure_optional_cmd_or_pkg()
# Purpose : Same as ensure_cmd_or_pkg, but for optional features.
# Module  : Global Helpers
# Notes   : Never aborts the whole script, only logs and continues.
#------------------------------------------------------------------------------
ensure_optional_cmd_or_pkg() {
    local cmd="$1" pkg="$2"

    if command -v "$cmd" &>/dev/null; then
        return 0
    fi

    echo -e "${WARN} Optional command '${cmd}' not found.${RESET}"
    log_msg WARN "Optional command '${cmd}' not found."

    if is_debian; then
        read -r -p "Do you want to install package '${pkg}' (recommended)? (y/N): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            echo -e "${INFO} Installing optional package ${pkg}...${RESET}"
            if apt-get update && apt-get install -y "$pkg"; then
                log_msg INFO "Optional package '${pkg}' installed successfully."
            else
                log_msg ERROR "Failed to install optional package '${pkg}'."
            fi
        fi
    else
        echo -e "${WARN} Please install package '${pkg}' manually if you wish to use the GUI.${RESET}"
        log_msg WARN "Non-Debian system. User must install '${pkg}' manually if GUI is desired."
    fi
}

#------------------------------------------------------------------------------
# check_systemd_resolved()
# Purpose : Verify presence and status of systemd-resolved and offer to enable.
# Module  : Global Helpers
#------------------------------------------------------------------------------
check_systemd_resolved() {
    if ! systemctl list-unit-files | grep -q '^systemd-resolved.service'; then
        echo -e "${WARN} systemd-resolved is not installed.${RESET}"
        log_msg WARN "systemd-resolved not installed."
        if is_debian; then
            read -r -p "Install systemd-resolved now via apt? (y/N): " ans
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                if apt-get update && apt-get install -y systemd-resolved; then
                    log_msg INFO "systemd-resolved installed."
                else
                    echo -e "${FAIL} Failed to install systemd-resolved.${RESET}"
                    log_msg ERROR "Failed to install systemd-resolved."
                    return
                fi
            else
                echo -e "${WARN} Proceeding without systemd-resolved. DNS will remain as is.${RESET}"
                log_msg WARN "User opted not to install systemd-resolved."
                return
            fi
        fi
    fi

    if systemctl list-unit-files | grep -q '^systemd-resolved.service'; then
        if ! systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
            echo -e "${WARN} systemd-resolved is disabled.${RESET}"
            log_msg WARN "systemd-resolved disabled."
            read -r -p "Do you want to enable and start systemd-resolved? (y/N): " ans2
            if [[ "$ans2" =~ ^[Yy]$ ]]; then
                if systemctl enable --now systemd-resolved; then
                    log_msg INFO "systemd-resolved enabled and started."
                else
                    echo -e "${FAIL} Failed to enable systemd-resolved.${RESET}"
                    log_msg ERROR "Failed to enable systemd-resolved."
                fi
            fi
        fi
    fi
}

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
# save_state()
# Purpose : Save current host/bridge network state variables to STATE_FILE.
# Module  : Global Helpers
#------------------------------------------------------------------------------
save_state() {
    cat > "$STATE_FILE" <<EOF
WIRED_IF="$WIRED_IF"
HOST_IP="$HOST_IP"
HOST_PREFIX="$HOST_PREFIX"
GATEWAY="$GATEWAY"
LAN_NET="$LAN_NET"
BRIDGE_IF="$BRIDGE_IF"
BRIDGE_NAME="$BRIDGE_NAME"
BRIDGE_SLAVE_NAME="$BRIDGE_SLAVE_NAME"
BRIDGE_IP="$BRIDGE_IP"
ETH_CONN_ORIG="$ETH_CONN_ORIG"
EOF
    log_msg INFO "State saved to ${STATE_FILE}."
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

#------------------------------------------------------------------------------
# backup_vm_xml()
# Purpose : Create a timestamped XML backup of a libvirt domain definition.
# Module  : Global Helpers (VM safety utility)
# Params  :
#   $1 - libvirt domain name
#------------------------------------------------------------------------------
backup_vm_xml() {
    local dom="$1"
    mkdir -p "$XML_BACKUP_DIR"

    # Sanitize name to avoid '/', spaces, etc. in file path
    local safe_dom
    safe_dom=$(echo "$dom" | tr '/ ' '__')

    local ts
    ts=$(date '+%Y-%m-%d-%H%M%S')

    virsh dumpxml "$dom" > "${XML_BACKUP_DIR}/${safe_dom}.${ts}.xml" 2>/dev/null || return 1
    log_msg INFO "VM ${dom} XML backup saved to ${XML_BACKUP_DIR}/${safe_dom}.${ts}.xml"
}
