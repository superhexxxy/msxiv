# Default to Apple Silicon Homebrew prefix, fallback to /usr/local
PREFIX ?= $(shell if [ -d /opt/homebrew ]; then echo /opt/homebrew; else echo /usr/local; fi)
BINDIR = $(PREFIX)/bin
CONFDIR = $(HOME)/.config/msxiv

.PHONY: all install install-config clean

all:
	@echo "Building msxiv..."
	@swift build -c release

install: all
	@echo "Installing to $(BINDIR)..."
	@install -d $(BINDIR)
	@install -m 755 .build/release/msxiv $(BINDIR)/msxiv
	@echo "Installed msxiv to $(BINDIR)/msxiv"

install-config:
	@echo "Installing example config to $(CONFDIR)/config..."
	@install -d $(CONFDIR)
	@install -m 644 config.example $(CONFDIR)/config
	@echo "Done. Edit $(CONFDIR)/config to customize."

clean:
	@swift package clean
	@echo "Cleaned build artifacts."
