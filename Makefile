# btresumed build
# Build: make
# Install: sudo make install  (as root to place LaunchAgent + binary)
# Uninstall: sudo make uninstall

BINARY  := btresumed
SRC     := btresumed.m
PLIST   := com.user.btresumed.plist

PREFIX     ?= /usr/local
BINDIR     := $(PREFIX)/bin
AGENT_DIR  := /Library/LaunchAgents
# Under `sudo make install`, HOME is /var/root — so HOME-based detection is wrong.
# SUDO_USER is set by sudo to the invoking user. Fall back to USER for plain make.
INSTALL_USER ?= $(if $(SUDO_USER),$(SUDO_USER),$(USER))
INSTALL_UID  ?= $(shell id -u $(INSTALL_USER) 2>/dev/null)

ARCH     ?= $(shell uname -m)
CFLAGS   := -arch $(ARCH) -fobjc-arc -O2 -Wall -Wno-deprecated-declarations
FRAMEWORKS := -framework Foundation -framework IOBluetooth -framework CoreBluetooth

.PHONY: all install uninstall clean reload

all: $(BINARY)

$(BINARY): $(SRC)
	clang $(CFLAGS) -o $@ $< $(FRAMEWORKS)

install: $(BINARY)
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Run with sudo: sudo make install" >&2; exit 1; \
	fi
	@if [ -z "$(INSTALL_UID)" ] || [ "$(INSTALL_USER)" = "root" ]; then \
		echo "Cannot determine non-root user. Run 'sudo make install' from a user account." >&2; exit 1; \
	fi
	mkdir -p $(BINDIR)
	install -m 755 $(BINARY) $(BINDIR)/$(BINARY)
	install -m 644 $(PLIST) $(AGENT_DIR)/$(PLIST)
	@echo
	@echo "Installed. Loading LaunchAgent for $(INSTALL_USER) (uid $(INSTALL_UID))..."
	launchctl bootstrap gui/$(INSTALL_UID) $(AGENT_DIR)/$(PLIST) 2>/dev/null || \
		launchctl kickstart -k gui/$(INSTALL_UID)/com.user.btresumed
	@echo
	@echo "macOS will prompt to allow Bluetooth access — click Allow."
	@echo "Logs: /tmp/btresumed.log"
	@echo "Verify: launchctl print gui/$(INSTALL_UID)/com.user.btresumed"

uninstall:
	-launchctl bootout gui/$(INSTALL_UID)/com.user.btresumed 2>/dev/null
	-rm -f $(AGENT_DIR)/$(PLIST)
	-rm -f $(BINDIR)/$(BINARY)
	@echo "Uninstalled."

reload:
	launchctl kickstart -k gui/$(INSTALL_UID)/com.user.btresumed

clean:
	rm -f $(BINARY)
