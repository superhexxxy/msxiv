class Msxiv < Formula
  desc "Neo Simple X Image Viewer for macOS (Apple Silicon native)"
  homepage "https://github.com/yourusername/msxiv"
  url "https://github.com/yourusername/msxiv/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"
  license "WTFPL"
  head "https://github.com/yourusername/msxiv.git", branch: "main"

  bottle do
    root_url "https://github.com/yourusername/msxiv/releases/download/v1.0.0"
    rebuild 1
    sha256 cellar: :any_skip_relocation, arm64_sonoma: "REPLACE_WITH_ACTUAL_SHA256"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "REPLACE_WITH_ACTUAL_SHA256"
  end

  depends_on xcode: ["14.0", :build]
  depends_on macos: :ventura

  def install
    system "make"
    bin.install ".build/release/msxiv"
    
    # Install example config
    (etc/"msxiv").install "config.example" => "config"
    
    # Install man page (if you create one)
    # man1.install "msxiv.1"
  end

  def caveats
    <<~EOS
      msxiv has been installed.
      
      To set up configuration:
        mkdir -p ~/.config/msxiv
        cp #{etc}/msxiv/config ~/.config/msxiv/config
      
      Optional scripts (make them executable with chmod +x):
        ~/.config/msxiv/key-handler   - Run custom actions on ; key
        ~/.config/msxiv/image-info    - Custom status bar text
        ~/.config/msxiv/thumb-info    - Custom thumbnail labels
        ~/.config/msxiv/win-title     - Custom window title
      
      Example key-handler script:
        #!/bin/sh
        while read file; do
          case "$1" in
            default) open -a "Preview" "$file" ;;
          esac
        done
    EOS
  end

  test do
    system "#{bin}/msxiv", "--help"
  end
end
