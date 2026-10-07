# msxiv

[![Swift](https://img.shields.io/badge/Swift-5.9+-FA7343?style=flat-square&logo=swift)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-13+-000000?style=flat-square&logo=apple)](https://www.apple.com/macos)
[![License: WTFPL](https://img.shields.io/badge/License-WTFPL-brightgreen.svg?style=flat-square)](https://www.wtfpl.net/)
[![Status](https://img.shields.io/badge/status-active-brightgreen?style=flat-square)](https://github.com/superhexxxy/msxiv)

msxiv is a fast, keyboard-driven image viewer for macOS, inspired by nsxiv and implemented natively with Swift and AppKit.

It is optimized for Apple Silicon Macs and designed for users who prefer lightweight, scriptable tools with minimal overhead and a vim-like workflow.

## Overview

msxiv provides:

- a native macOS image viewer
- image mode and thumbnail-grid mode
- fast keyboard navigation
- configurable script hooks
- file marking and selection workflows
- automatic reload of modified images
- minimal dependencies and no heavy runtime

This project follows the same philosophy as classic Unix tools: small, fast, configurable, and focused on the task at hand.

## Requirements

The following software and system requirements are needed for msxiv to build and run correctly on macOS:

### System

- macOS 13 or newer
- Apple Silicon recommended (M1/M2/M3/M4)
- Xcode-compatible environment

### Required packages

Install the following on a Mac before building or running the project:

- Xcode Command Line Tools
  - provides `clang`, `make`, and the Swift toolchain
  - install with:
    ```bash
    xcode-select --install
    ```
- Homebrew (recommended for installation and package management)
  - install with:
    ```bash
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ```

### Notes

- No third-party runtime libraries are required for normal operation.
- The app is built against Apple frameworks only: AppKit and the Swift standard library.
- This project does not depend on Electron, GTK, or Qt.

## Installation

### Build from source

```bash
git clone https://github.com/superhexxxy/msxiv.git
cd msxiv
make
sudo make install
```

Optional: install the example configuration file:

```bash
make install-config
```

### Install with Homebrew

```bash
brew install --build-from-source ./msxiv.rb
```

## Quick Start

Open a directory of images:

```bash
msxiv ~/Pictures
```

Open specific files:

```bash
msxiv photo1.jpg photo2.png
```

Open in thumbnail mode:

```bash
msxiv -t ~/Pictures
```

## Usage

msxiv opens in image mode by default. Use the keyboard to navigate, zoom, and manipulate images.

### Navigation

- `h`, `j`, `k`, `l` or arrow keys: pan and navigate
- `Space`, `Left`, `Right`: move between images
- `g` / `G`: jump to the first or last image
- `t`: toggle thumbnail mode
- `f`: toggle fullscreen
- `q`: quit

### Zoom and viewing

- `w`: fit image to window
- `W`: fit window to image
- `1`: view at 100% zoom
- `+` / `-`: zoom in or out
- `r`: rotate in view
- `R`: rotate and save to disk

### File operations

- `c`: copy file path to clipboard
- `o`: open the current file in the default app
- `x`: mark or unmark a file
- `d` then `y` or `n`: move file to Trash with confirmation
- `;`: run the configured key-handler script

### Slideshow

- `s`: toggle slideshow
- `[` / `]`: adjust slideshow delay

## Configuration

The example configuration is installed to:

```bash
~/.config/msxiv/config
```

Example:

```ini
thumbnail_size = 128
zoom_increment = 1.25
background_color = #282828
status_bar = true
sort_by = name
recursive = false
slideshow_delay = 3.0
```

## Script Hooks

Scripts can be placed in:

```bash
~/.config/msxiv/
```

### key-handler

Triggered by the `;` key and receives file paths through stdin.

```bash
#!/bin/sh
while read file; do
  open -a "Preview" "$file"
done
```

### image-info

Displays additional image information in the status bar.

```bash
#!/bin/sh
file="$1"
size=$(stat -f%z "$file" 2>/dev/null)
echo "$(basename "$file") - $((size / 1024))KB"
```

### thumb-info

Displays metadata under each thumbnail.

```bash
#!/bin/sh
echo "$(basename "$1")"
```

### win-title

Sets the window title for the current image.

```bash
#!/bin/sh
echo "VIEWING: $(basename "$1")"
```

## Development

### Build

```bash
make
```

### Clean build artifacts

```bash
make clean
```

### Package layout

```text
msxiv/
├── Sources/msxiv/           # Swift implementation
├── Package.swift            # Swift package manifest
├── Makefile                 # Build and install targets
├── install.sh               # Installation helper
├── update.sh                # Update helper
├── config.example           # Example config
├── msxiv.rb                 # Homebrew formula
├── README.md                # Project documentation
├── .gitignore
└── LICENSE
```

## Technical Notes

- Language: Swift
- Framework: AppKit
- Build system: Swift Package Manager
- Platform: macOS 13+
- Runtime environment: native macOS
- Dependencies: Apple system frameworks only

## Troubleshooting

### `msxiv: command not found`

Verify the install path is in your shell PATH:

```bash
echo $PATH
```

Typical locations:

- Apple Silicon: `/opt/homebrew/bin`
- Intel: `/usr/local/bin`

Then reinstall:

```bash
make install
```

### Config not applying

Check the active config:

```bash
cat ~/.config/msxiv/config
```

Restart the application after making changes.

### Build failures

Ensure Xcode Command Line Tools are installed:

```bash
xcode-select --install
swift --version
```

## License

This project is licensed under the DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE (WTFPL).

See [LICENSE](LICENSE) for the full text.

## Credits

- Inspired by [nsxiv](https://github.com/nsxiv/nsxiv)
- Built natively for macOS using Swift and AppKit
- Designed around a minimal, high-performance, keyboard-driven workflow

## Contributing

Contributions are welcome.

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Commit and push
5. Open a pull request

---

If you want, I can also produce a more minimal, more aggressive "hacker-style" README version or tighten this one further for a cleaner GitHub landing page.
