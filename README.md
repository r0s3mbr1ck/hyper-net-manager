<img src="/docs/images/bridge.png">

<div align="center">
  
# Hyper Net Manager (HNM)
</div>


## Hyper Net Manager (HNM) is a fully automated KVM/libvirt network & virtualization orchestration framework, engineered for:

- Cybersecurity labs
- Corporate AD labs
- Pentest / offensive security simulations
- VLAN/DMZ network engineering
- VM lifecycle automation
- Training environments

### Designed for professionals who need fast, repeatable, and reliable virtual network labs.

<div align="center">

## 🔥 Features

| Category                 | Features                                                            |
| ------------------------ | ------------------------------------------------------------------- |
| **Host Network Manager** | Bridge switching, Ethernet mode, auto-detect NICs                   |
| **VM Manager**           | Create, clone, snapshot, resize CPU/RAM, detect IPs                 |
| **VM Networks**          | Internal VLANs, NAT, host-only, real VLANs, DMZ                     |
| **LAB Scenarios**        | AD LAB, pivoting, sandbox isolation, sniffing, misconfig injections |
| **Diagnostics**          | Network/state reports, DNS/NM/libvirt validation                    |
| **UX**                   | Tilix launcher, polished banners, FZF menus, fast navigation        |

</div>
<div align="center">

## 🎬 Demo

</div>

### 📽️ Banner + Boot Animation
<img src="/docs/gifs/banner.gif">

### 📽️ VM Lifecycle (create → connect → console)

### 📽️ VLAN / Libvirt Networking

### 📽️ Pentest / AD LAB Automation

<div align="center">
  
## ⬇️ Instalation

</div>

Download the latest .deb from Releases and install:
```bash
sudo dpkg -i hyper-net-manager_1.0.3.deb
sudo apt --fix-broken install -y   # if needed
```
### This installs:
- /usr/local/bin/hnm → main engine
- /usr/local/bin/hnm-launcher → PKEXEC GUI launcher
- Polkit policy (/usr/share/polkit-1/actions/com.hnm.launch.policy)
- Desktop entry (/usr/share/applications/hnm.desktop)
- Icons (/usr/share/icons/hicolor/.../hnm.png)

<div align="center">
  
## 🚀 Launching

</div>

### From GUI:
#### Applications Menu → Hyper Net Manager

#### From terminal:
```bash
hnm
```
<div align="center">
  
## 📂 Project Structure
</div>

```graphql
hyper-net-manager/
│
├── src/
│   ├── core/           # main helpers, globals, banner, selectors
│   ├── host/           # host network engine (bridge/ethernet)
│   ├── vm/             # VM lifecycle + networking
│   ├── labs/           # prebuilt cybersecurity labs
│   ├── diagnostics/    # environment analyzers
│   └── hnm.sh          # main modular engine
│
├── packaging/
│   ├── Makefile        # deb package builder
│   ├── debian/         # control, preinst, postinst, prerm
│   ├── hnm-launcher    # terminal launcher with pkexec
│   └── debian-preinst-hnm.sh
│
├── docs/
│   ├── gifs/           # demo GIFs for README
│   └── screenshots/
│
└── README.md

```
---

<div align="center">
  
## 🛠 Requirements

</div>

### Mandatory:
- Bash ≥ 5
- libvirt-daemon-system
- libvirt-clients
- bridge-utils
- iproute2
- iptables

### Recommended:
- Tilix (best experience)
- virt-manager / virt-viewer
- systemd-resolved enabled

## 🧩 Building Your Own .deb
### Inside /packaging:
```bash
make clean
make deb
```
### **Install your newly built package:**
```bash
sudo dpkg -i hyper-net-manager_1.0.3.deb
```

<div align="center">
  
## 🧪 Tested On
</div>

- Debian 12
- Ubuntu 24.04
- Kali Linux 2024/2025
- KDE Plasma, GNOME, XFCE


<div align="center">

## 🛡️ Security Notes
</div>

- Runs under pkexec for safer privilege elevation
- Internal networks are isolated by default
- No persistent VM modifications unless explicitly triggered
- XML backups of VMs are auto-stored in /root/vm-xml-backups/


<div align="center">

## 👨‍💻 Lead Developer

</div>

- **Alex Marano**
- Cyber Warfare Specialist
- ✉️ alex_marano87@hotmail.com

> [!IMPORTANT]
> The script may have execution errors, translation issues, and opportunities for visual improvements. Contribute!
