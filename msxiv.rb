class Msxiv < Formula
  desc "Neo Simple X Image Viewer for macOS (Apple Silicon native)"
  homepage "https://github.com/superhexxxy/msxiv"
  url "https://github.com/superhexxxy/msxiv/archive/refs/tags/v1.0.2.tar.gz"
  sha256 "4196218fb2b01ef87b6c55f6134602a6e4abb00b8ed6842fcbfd71ac59f4f127"
  license "WTFPL"
  head "https://github.com/superhexxxy/msxiv.git", branch: "main"


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
