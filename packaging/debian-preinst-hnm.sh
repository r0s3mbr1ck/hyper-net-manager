#!/bin/bash
set -e

# ===== Colors / tags estilo HNM =====
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; RESET="\e[0m"
OK="${GREEN}[OK]${RESET}"
FAIL="${RED}[FAIL]${RESET}"
WARN="${YELLOW}[WARN]${RESET}"
INFO="${CYAN}[INFO]${RESET}"

echo -e "--------------------------------------------------"
echo -e " Hyper Net Manager - Dependency Pre-Installer"
echo -e "--------------------------------------------------"

# ===== Detecta distro (Debian/Ubuntu/Pop!_OS/Kali/Outros) =====
DISTRO_ID="unknown"
DISTRO_NAME="Unknown"

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$NAME}"
fi

echo -e "${INFO} Detected distro: ${YELLOW}${DISTRO_NAME} (${DISTRO_ID})${RESET}"

# Só continua se for família Debian (usa APT)
if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${FAIL} APT not found. This installer currently supports Debian-based systems only."
    echo -e "      Detected: ${DISTRO_NAME}"
    exit 1
fi

case "$DISTRO_ID" in
    debian)
        echo -e "${INFO} Applying defaults optimized for Debian.${RESET}"
        ;;
    ubuntu)
        echo -e "${INFO} Applying defaults optimized for Ubuntu.${RESET}"
        ;;
    pop|pop-os|popos)
        echo -e "${INFO} Detected Pop!_OS (Ubuntu-based). Using Ubuntu defaults.${RESET}"
        ;;
    kali)
        echo -e "${INFO} Detected Kali Linux (Debian-based). Using Debian defaults.${RESET}"
        ;;
    *)
        echo -e "${WARN} Unknown Debian-based derivative (${DISTRO_ID}). Proceeding with generic APT logic.${RESET}"
        ;;
esac

# ===== Auto-repair de dependências quebradas (se houver) =====
echo -e "${INFO} Checking for broken packages (dry-run)...${RESET}"
if apt-get -s -o Debug::BrokenDeps=yes dist-upgrade >/dev/null 2>&1; then
    echo -e "${OK} No obvious broken dependencies reported by APT.${RESET}"
else
    echo -e "${WARN} APT reported possible broken dependencies.${RESET}"
    echo -e "${INFO} Running 'apt-get -f install' auto-repair (may take a while)...${RESET}"
    if apt-get -y -f install >/dev/null 2>&1; then
        echo -e "${OK} Auto-repair completed successfully.${RESET}"
    else
        echo -e "${FAIL} Auto-repair with 'apt-get -f install' failed.${RESET}"
        echo -e "      Please fix APT issues manually and re-run the installation."
        exit 1
    fi
fi

# ===== Pacotes opcionais (libvirt / virt-manager / tilix) =====
OPTIONAL_PKGS="libvirt-daemon-system virt-manager tilix"

echo
echo -e "${INFO} The following optional packages improve HNM experience:${RESET}"
for p in $OPTIONAL_PKGS; do
    echo "  - $p"
done
echo

read -r -p "Install these optional packages now? (y/N): " ans
ans="${ans:-N}"

if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo -e "${INFO} Installing optional dependencies: ${YELLOW}${OPTIONAL_PKGS}${RESET}"
    if apt-get update -y >/dev/null 2>&1 && apt-get install -y $OPTIONAL_PKGS; then
        echo -e "${OK} Optional packages installed successfully.${RESET}"
    else
        echo -e "${WARN} Optional package installation failed. Trying auto-repair...${RESET}"
        if apt-get -y -f install >/dev/null 2>&1; then
            echo -e "${OK} Auto-repair after optional install completed.${RESET}"
        else
            echo -e "${WARN} Could not run 'apt-get -f install' successfully."
            echo -e "      Optional packages were not installed (core HNM will still work)."
        fi
    fi
else
    echo -e "${INFO} Skipping optional package installation.${RESET}"
fi

echo
echo -e "${OK} Continuing Hyper Net Manager installation...${RESET}"
exit 0

