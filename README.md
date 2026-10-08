# msxiv

**Neo Simple Image Viewer for macOS** — A native Apple Silicon (M1/M2/M3/M4) port of [nsxiv](https://github.com/nsxiv/nsxiv), built with Swift and AppKit for maximum performance.

## Features

- **Blazing Fast**: Native Apple Silicon optimization with hardware-accelerated image decoding
- **Two Modes**: Image mode and thumbnail grid mode
- **Keyboard-Driven**: Vim-like keybindings (`h/j/k/l`, `w`, `r`, `t`, etc.)
- **Zero Dependencies**: Pure Swift + macOS frameworks, no third-party libraries
- **Scriptable**: External hooks for `key-handler`, `image-info`, `thumb-info`, and `win-title`
- **Live Reload**: Automatically refreshes when the current image is modified
- **EXIF Auto-Orientation**: Photos display with correct rotation
- **Thumbnail Caching**: Disk-backed cache for instant subsequent loads
- **File Marking**: Mark files with `x`, printed to stdout on quit

## Installation

### From Source

```bash
git clone https://github.com/yourusername/msxiv.git
cd msxiv
make
sudo make install
make install-config  # Optional: install example config
```

### Via Homebrew

```bash
brew install --build-from-source ./msxiv.rb
```

## Usage

```bash
# View images in a directory
msxiv ~/Pictures/vacation/

# Start in thumbnail mode
msxiv -t ~/Pictures/

# View specific files
msxiv photo1.jpg photo2.png
```

## Keybindings

### Image Mode

| Key | Action |
|-----|--------|
| `h/j/k/l` or arrows | Pan image |
| `Left/Right/Space` | Previous/Next image |
| `w` | Fit image to window |
| `W` (Shift+w) | Fit window to image |
| `f` | Toggle fullscreen |
| `r` | Rotate 90° (view only) |
| `R` (Shift+r) | Rotate 90° and save to disk |
| `1` | Zoom to 100% (true pixels) |
| `+/-` | Zoom in/out |
| `s` | Slideshow on/off (`[` `]` adjust delay) |
| `c` | Copy file path to clipboard |
| `o` | Open in default app |
| `x` | Mark/unmark file |
| `t` | Toggle thumbnail mode |
| `g/G` | Jump to first/last image |
| `;` | Run `key-handler` script |
| `d` then `y`/`n` (`Esc` cancels) | Delete file to Trash (with confirm) |
| `q` | Quit |

### Thumbnail Mode

| Key | Action |
|-----|--------|
| `h/j/k/l` or arrows | Navigate grid |
| `Return` | Open selected image |
| `x` | Mark/unmark file |
| `c` | Copy file path to clipboard |
| `o` | Open in default app |
| `d` then `y`/`n` (`Esc` cancels) | Delete file to Trash (with confirm) |
| `t` | Back to image mode |
| `f` | Toggle fullscreen |
| `g/G` | Jump to first/last |
| `q` | Quit |

## Configuration

Edit `~/.config/msxiv/config`:

```ini
thumbnail_size = 128
zoom_increment = 1.25
background_color = #282828
status_bar = true
sort_by = name          # name | date | size
recursive = false       # scan subdirectories
slideshow_delay = 3.0   # seconds (0.5 - 30)
```

## Script Hooks

Create executable scripts in `~/.config/msxiv/`:

### `key-handler`

Triggered by `;` key. Receives file paths on stdin.

```bash
#!/bin/sh
while read file; do
  case "$1" in
    default) 
      # Example: open in Preview
      open -a "Preview" "$file"
      ;;
  esac
done
```

### `image-info`

Output is displayed in the status bar.

```bash
#!/bin/sh
file="$1"
size=$(stat -f%z "$file")
echo "$(basename "$file") - $((size / 1024))KB"
```

### `thumb-info`

Output is displayed below each thumbnail.

```bash
#!/bin/sh
echo "$(basename "$1")"
```

### `win-title`

Output sets the window title.

```bash
#!/bin/sh
echo "VIEWING: $(basename "$1")"
```

## Performance

- **M4 Apple Silicon**: Hardware-accelerated decoding via ImageIO
- **Large Directories**: Lazy thumbnail loading with visible-rect culling
- **Memory Efficient**: Automatic cache trimming under memory pressure
- **120Hz ProMotion**: Smooth panning and zooming on compatible displays

## License

GPL-2.0-or-later — Same as nsxiv

## Credits

Inspired by [nsxiv](https://github.com/nsxiv/nsxiv) and the suckless philosophy.
