# Default to Apple Silicon Homebrew prefix, fallback to /usr/local
PREFIX ?= $(shell if [ -d /opt/homebrew ]; then echo /opt/homebrew; else echo /usr/local; fi)
BINDIR = $(PREFIX)/bin
CONFDIR = $(HOME)/.config/msxiv

# Homebrew compiles inside its own sandbox, and SwiftPM's inner manifest
# sandbox cannot nest inside it (fails with "sandbox_apply: Operation not
# permitted"). Disable only the inner sandbox for brew builds; the outer
# brew sandbox still applies. Plain `make` is unaffected.
ifdef HOMEBREW_CELLAR
SWIFTFLAGS += --disable-sandbox
endif

.PHONY: all install install-config clean

all:
	@echo "Building msxiv..."
	@swift build -c release $(SWIFTFLAGS)

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
