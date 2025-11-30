############################################
# Hyper Net Manager (HNM) - Makefile 
# Author: Alex Marano
# Version: 1.0.3
############################################

PKG_NAME      := hyper-net-manager
APP_VERSION   := 1.0.3
DEB_VERSION   := $(APP_VERSION)
BUILD_DIR     := $(PKG_NAME)_$(DEB_VERSION)

SRC_PREINST   := debian-preinst-hnm.sh
INSTALL_BASE  := /opt/hyper-net-manager
INSTALL_BIN   := /usr/local/bin

LAUNCHER_NAME := hnm-launcher      # lançador GUI (usado no .desktop)
INSTALL_NAME  := hnm               # wrapper CLI -> /opt/hyper-net-manager/hnm.sh

POLKIT_ID     := com.hnm.launch
POLKIT_DIR    := /usr/share/polkit-1/actions
ICON_SIZE     := 64

############################################
# Main Targets
############################################
all: deb

deb: clean build_dirs copy_files control_file preinst postinst prerm desktop polkit
	dpkg-deb --build --root-owner-group $(BUILD_DIR)
	@echo "==> Package generated: $(BUILD_DIR).deb"

install: deb
	sudo dpkg -i $(BUILD_DIR).deb || sudo apt-get -f install -y

uninstall:
	sudo dpkg -r $(PKG_NAME) || true
	sudo dpkg -P $(PKG_NAME) || true

clean:
	rm -rf $(BUILD_DIR) $(BUILD_DIR).deb $(BUILD_DIR).deb.asc

############################################
# Directory structure
############################################
build_dirs:
	mkdir -p $(BUILD_DIR)/DEBIAN
	mkdir -p $(BUILD_DIR)$(INSTALL_BASE)
	mkdir -p $(BUILD_DIR)$(INSTALL_BIN)
	mkdir -p $(BUILD_DIR)/usr/share/icons/hicolor/$(ICON_SIZE)x$(ICON_SIZE)/apps
	mkdir -p $(BUILD_DIR)/usr/share/applications
	mkdir -p $(BUILD_DIR)$(POLKIT_DIR)

############################################
# Copy modular files
############################################
copy_files:
	# Main script
	cp hnm.sh $(BUILD_DIR)$(INSTALL_BASE)/hnm.sh
	chmod 755 $(BUILD_DIR)$(INSTALL_BASE)/hnm.sh

	# Wrapper CLI: /usr/local/bin/hnm
	echo '#!/bin/bash' >  $(BUILD_DIR)$(INSTALL_BIN)/$(INSTALL_NAME)
	echo 'exec sudo $(INSTALL_BASE)/hnm.sh "$$@"' >> $(BUILD_DIR)$(INSTALL_BIN)/$(INSTALL_NAME)
	chmod 755 $(BUILD_DIR)$(INSTALL_BIN)/$(INSTALL_NAME)

	# Launcher para uso no .desktop: /usr/local/bin/hnm-launcher
	cp $(LAUNCHER_NAME) $(BUILD_DIR)$(INSTALL_BIN)/$(LAUNCHER_NAME)
	chmod 755 $(BUILD_DIR)$(INSTALL_BIN)/$(LAUNCHER_NAME)

	# Dirs modulares
	cp -r core         $(BUILD_DIR)$(INSTALL_BASE)/
	cp -r host         $(BUILD_DIR)$(INSTALL_BASE)/
	cp -r vm           $(BUILD_DIR)$(INSTALL_BASE)/
	cp -r labs         $(BUILD_DIR)$(INSTALL_BASE)/
	cp -r diagnostics  $(BUILD_DIR)$(INSTALL_BASE)/

	# Ícone
	cp hnm.png $(BUILD_DIR)/usr/share/icons/hicolor/$(ICON_SIZE)x$(ICON_SIZE)/apps/hnm.png

############################################
# Polkit Policy
############################################
polkit:
	mkdir -p $(BUILD_DIR)/usr/share/polkit-1/actions
	echo '<?xml version="1.0" encoding="UTF-8"?>'                                            >  $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '<policyconfig>'                                                                    >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '  <action id="$(POLKIT_ID)">'                                                      >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '    <description>Run Hyper Net Manager (HNM)</description>'                        >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '    <message>Hyper Net Manager requires administrator privileges to run.</message>'>> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '    <defaults>'                                                                    >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '      <allow_any>auth_admin</allow_any>'                                           >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '      <allow_inactive>auth_admin</allow_inactive>'                                 >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '      <allow_active>auth_admin</allow_active>'                                     >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '    </defaults>'                                                                   >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/env</annotate>'   >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '  </action>'                                                                       >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy
	echo '</policyconfig>'                                                                   >> $(BUILD_DIR)/usr/share/polkit-1/actions/$(POLKIT_ID).policy

############################################
# DEBIAN/control
############################################
control_file:
	printf "Package: $(PKG_NAME)\n"                                    >  $(BUILD_DIR)/DEBIAN/control
	printf "Version: $(APP_VERSION)\n"                               >> $(BUILD_DIR)/DEBIAN/control
	printf "Section: utils\n"                                        >> $(BUILD_DIR)/DEBIAN/control
	printf "Priority: optional\n"                                    >> $(BUILD_DIR)/DEBIAN/control
	printf "Architecture: all\n"                                     >> $(BUILD_DIR)/DEBIAN/control
	printf "Maintainer: Alex Marano <alex_marano87@hotmail.com>\n"   >> $(BUILD_DIR)/DEBIAN/control
	printf "Depends: bash, coreutils, iproute2, iptables, libvirt-daemon-system, virt-manager, pkexec, polkitd, tilix | konsole | gnome-terminal | xfce4-terminal | xterm\n" >> $(BUILD_DIR)/DEBIAN/control
	printf "Description: Hyper Net Manager \n"                       >> $(BUILD_DIR)/DEBIAN/control
	printf " Modular KVM/libvirt virtualization, VLAN, DMZ and LAB automation tool.\n" >> $(BUILD_DIR)/DEBIAN/control

############################################
# Preinst
############################################
preinst:
	echo "#!/bin/bash"                          >  $(BUILD_DIR)/DEBIAN/preinst
	echo "set -e"                              >> $(BUILD_DIR)/DEBIAN/preinst
	echo "exit 0"                              >> $(BUILD_DIR)/DEBIAN/preinst
	chmod 755 $(BUILD_DIR)/DEBIAN/preinst

############################################
# Postinst
############################################
postinst:
	echo "#!/bin/bash"                                            >  $(BUILD_DIR)/DEBIAN/postinst
	echo "set -e"                                                >> $(BUILD_DIR)/DEBIAN/postinst
	echo "chmod 755 $(INSTALL_BIN)/$(INSTALL_NAME) || true"      >> $(BUILD_DIR)/DEBIAN/postinst
	echo "chmod 755 $(INSTALL_BIN)/$(LAUNCHER_NAME) || true"     >> $(BUILD_DIR)/DEBIAN/postinst
	echo "update-desktop-database >/dev/null 2>&1 || true"       >> $(BUILD_DIR)/DEBIAN/postinst
	echo "gtk-update-icon-cache /usr/share/icons/hicolor >/dev/null 2>&1 || true" >> $(BUILD_DIR)/DEBIAN/postinst
	echo "exit 0"                                                >> $(BUILD_DIR)/DEBIAN/postinst
	chmod 755 $(BUILD_DIR)/DEBIAN/postinst

############################################
# Prerm
############################################
prerm:
	echo "#!/bin/bash"                                            >  $(BUILD_DIR)/DEBIAN/prerm
	echo "set -e"                                                >> $(BUILD_DIR)/DEBIAN/prerm
	echo "update-desktop-database >/dev/null 2>&1 || true"       >> $(BUILD_DIR)/DEBIAN/prerm
	echo "gtk-update-icon-cache /usr/share/icons/hicolor >/dev/null 2>&1 || true" >> $(BUILD_DIR)/DEBIAN/prerm
	echo "exit 0"                                                >> $(BUILD_DIR)/DEBIAN/prerm
	chmod 755 $(BUILD_DIR)/DEBIAN/prerm

############################################
# Desktop Entry
############################################
desktop:
	printf "[Desktop Entry]\n"                                      >  $(BUILD_DIR)/usr/share/applications/hnm.desktop
	printf "Type=Application\n"                                    >> $(BUILD_DIR)/usr/share/applications/hnm.desktop
	printf "Name=Hyper Net Manager\n"                              >> $(BUILD_DIR)/usr/share/applications/hnm.desktop
	printf "Exec=$(INSTALL_BIN)/$(LAUNCHER_NAME)\n"                >> $(BUILD_DIR)/usr/share/applications/hnm.desktop
	printf "Icon=hnm\n"                                            >> $(BUILD_DIR)/usr/share/applications/hnm.desktop
	printf "Terminal=false\n"                                      >> $(BUILD_DIR)/usr/share/applications/hnm.desktop
	printf "Categories=System;Network;Utility;\n"                  >> $(BUILD_DIR)/usr/share/applications/hnm.desktop

############################################
# GPG signature (optional)
############################################
sign: deb
	@echo "==> Signing $(BUILD_DIR).deb with your default GPG key (if available)"
	@gpg --armor --detach-sign --output $(BUILD_DIR).deb.asc $(BUILD_DIR).deb || \
	    echo '==> GPG signing skipped (no key configured?)'
	@echo "==> Signature file (if created): $(BUILD_DIR).deb.asc"

