import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// RAW digital camera file support ("NRAW" — native RAW).
///
/// How the magic works, in order of preference:
///
///  1. **ImageIO speaks RAW natively.** Every mainstream camera RAW format
///     (CR2/CR3 Canon, NEF Nikon, ARW/SR2/SRF Sony, RAF Fuji, ORF Olympus,
///     RW2/RWL Panasonic, DNG + Adobe/Leica/Hasselblad variants, PEF Pentax,
///     RAW Samsung, GPR GoPro, R3D RED…) is registered with Launch Services
///     as a subtype of `public.camera-raw-image`. Handing such a URL to
///     `CGImageSourceCreateWithURL` already yields a decoded picture — but
///     only if ImageIO *knows* the bytes are an image, which it decides from
///     the file's UTI. A `.cr3` copied into a folder full of JPEGs is opaque
///     to ImageIO unless we tell it the type first. So for extension-only
///     detection we build the source with an explicit `kCGImageSourceTypeIdentifierHint`
///     derived from the file's UTI. That single hint turns "unsupported file"
///     into a hardware-accelerated decode for every RAW flavor macOS ships a
///     codec for — no LibRaw, no sidecar converters, zero extra dependencies.
///
///  2. **Embedded JPEG preview shortcut.** RAW bodies are Bayer sensor data;
///     demosaicing megapixels at navigation speed is not something we ask of
///     the CPU on every arrow-key press. Camera RAW files embed a full-size
///     (or display-size) JPEG preview plus thumbnails. Reading that preview
///     is 10–50× faster than a raw demosaic and is exactly what Lightroom
///     does while the real render happens in the background. We sniff the
///     TIFF/EXIF IFDs of the big-endian formats (NEF/CR2/ORF/DNG) and the
///     Foveon header of X3F to locate the embedded JPEG offset+length, then
///     decode just those bytes through `CGImageSourceCreateWithData`. If the
///     sniff fails or produces nothing usable, we transparently fall back
///     to step 1 (ImageIO's own pipeline, which internally uses the same
///     preview when asked for a small image).
enum RawSupport {
    /// All known camera RAW filename extensions. Covers the common formats
    /// across Canon, Nikon, Sony, Fujifilm, Olympus/OM System, Panasonic,
    /// Leica, Pentax, Sigma, Samsung, GoPro, RED, Hasselblad, Phase One,
    /// Epson, Minolta, Kodak, Casio, Ricoh, Apple ProRAW and more.
    static let allExtensions: Set<String> = [
        // Canon
        "cr2", "cr3", "crw",
        // Nikon
        "nef", "nrw",
        // Sony
        "arw", "sr2", "srf",
        // Fujifilm
        "raf",
        // Olympus / OM System
        "orf",
        // Panasonic
        "rw2", "rwl",
        // Adobe / generic digital negative
        "dng",
        // Pentax / Ricoh
        "pef", "ptx",
        // Sigma
        "x3f",
        // Samsung
        "srw",
        // GoPro
        "gpr",
        // RED
        "r3d",
        // Hasselblad
        "3fr",
        // Phase One
        "iiq",
        // Epson
        "erf",
        // Minolta
        "mrw",
        // Kodak
        "kdc", "kc2", "dcs",
        // Casio
        "cine",
        // Nokia (pureview)
        "nry",
        // Apple ProRAW & Photos RAW containers
        "hdp", "ief",
    ]

    static func isRawExtension(_ ext: String) -> Bool {
        allExtensions.contains(ext.lowercased())
    }

    /// Resolve a file's declared UTI (cheap Launch Services lookup, backed by
    /// the extension database even for files without a registered type).
    private static func uti(of url: URL) -> UTType? {
        if let t = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return t
        }
        return UTType(filenameExtension: url.pathExtension.lowercased())
    }

    /// True when the file is recognized as a camera RAW container — either by
    /// its extension list above or because Launch Services classifies it as a
    /// subtype of `public.camera-raw-image` (catches exotic extensions we
    /// don't list, e.g. a renamed .orf or vendor-specific types).
    static func isRawFile(at url: URL) -> Bool {
        if isRawExtension(url.pathExtension) { return true }
        guard let t = uti(of: url) else { return false }
        return t.conforms(to: .init(identifier: "public.camera-raw-image"))
    }

    /// Type-identifier hint for ImageIO. Passing this makes CGImageSource
    /// treat the bytes as the RAW codec's container regardless of what the
    /// filename says — the difference between "nil source" and a decode.
    static func typeHint(for url: URL) -> CFString? {
        guard let t = uti(of: url) else { return nil }
        return t.identifier as CFString
    }

    // MARK: - Embedded preview sniffing

    /// Byte offset/length of an embedded JPEG preview inside a RAW container.
    struct EmbeddedJPEG { let offset: Int; let length: Int }

    /// Locate the largest embedded JPEG in TIFF-based RAW formats.
    ///
    /// NEF/CR2/ORF/DNG/PEF/ARW(new)/RW2 are TIFF containers: an IFD chain of
    /// directory entries, each possibly pointing at sub-IFDs holding the
    /// previews. The classic trick (used by dcraw/exiftool) is following tag
    /// 0x014A (SubIFD); many makers also stuff JPEG previews into ordinary
    /// data entries, so we additionally harvest any component-type-6
    /// (JPEG-compressed) entry whose bytes really start with SOI. All reads
    /// are bounds-checked against the file size — malformed headers can never
    /// escape the mapped buffer.
    ///
    /// Runs on a memory-mapped read of the file: the kernel pages in only the
    /// few KB of IFD directory structures we actually touch, never the
    /// multi-hundred-MB sensor payload.
    static func embeddedJPEGPreview(in url: URL) -> EmbeddedJPEG? {
        guard let d = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              d.count > 16 else { return nil }
        let n = d.count
        // Single contiguous pass over the mapped range; indexed access through
        // `withUnsafeBytes` avoids per-subscript bounds-recheck overhead and
        // any copy of the buffer.
        return d.withUnsafeBytes { raw -> EmbeddedJPEG? in
            let p = raw.bindMemory(to: UInt8.self)
            func u16(_ o: Int, be: Bool) -> Int? {
                guard o >= 0, o + 2 <= n else { return nil }
                return be ? (Int(p[o]) << 8) | Int(p[o + 1])
                          : (Int(p[o + 1]) << 8) | Int(p[o])
            }
            func u32(_ o: Int, be: Bool) -> Int? {
                guard o >= 0, o + 4 <= n else { return nil }
                return be ? (Int(p[o]) << 24) | (Int(p[o+1]) << 16) | (Int(p[o+2]) << 8) | Int(p[o+3])
                          : (Int(p[o+3]) << 24) | (Int(p[o+2]) << 16) | (Int(p[o+1]) << 8) | Int(p[o])
            }
            func isSOI(_ o: Int) -> Bool {
                o >= 0 && o + 2 <= n && p[o] == 0xFF && p[o + 1] == 0xD8
            }

            var best: EmbeddedJPEG?

            // Harvest candidate JPEG regions from one IFD, recursing through
            // SubIFD pointers (tag 0x014A) where the big previews hide.
            func walkIFD(_ ifd: Int, be: Bool, depth: Int) {
                guard depth < 4, let count = u16(ifd, be: be), count < 1024 else { return }
                guard ifd + 2 + count * 12 + 4 <= n else { return }
                for e in 0..<count {
                    let entry = ifd + 2 + e * 12
                    guard let tag = u16(entry, be: be),
                          let comp = u16(entry + 2, be: be),
                          let len = u32(entry + 4, be: be) else { continue }
                    let valueField = entry + 8

                    if tag == 0x014A, comp == 4 { // SubIFD pointer(s)
                        if len == 1, let sub = u32(valueField, be: be) {
                            walkIFD(sub, be: be, depth: depth + 1)
                        } else if len > 1, let arrOff = u32(valueField, be: be),
                                  arrOff + len * 4 <= n {
                            for k in 0..<min(len, 8) {
                                if let sub = u32(arrOff + k * 4, be: be) {
                                    walkIFD(sub, be: be, depth: depth + 1)
                                }
                            }
                        }
                        continue
                    }

                    // JPEG-compressed data (TIFF component type 6): the
                    // maker-note full-size previews of CR2/ORF/NEF/DNG live
                    // here. Only accept runs that really start with SOI.
                    guard comp == 6, len > 100 else { continue }
                    let off: Int?
                    if len <= 4 {
                        off = u32(valueField, be: be) // inline value
                    } else {
                        let o = u32(valueField, be: be)
                        off = (o != nil && o! + len <= n) ? o : nil
                    }
                    guard let off = off, isSOI(off) else { continue }
                    if best == nil || len > best!.length {
                        best = EmbeddedJPEG(offset: off, length: len)
                    }
                }
            }

            // TIFF magic: "II" little-endian or "MM" big-endian.
            if p[0] == 0x49, p[1] == 0x49 {
                if let off = u32(4, be: false) { walkIFD(off, be: false, depth: 0) }
            } else if p[0] == 0x4D, p[1] == 0x4D {
                if let off = u32(4, be: true) { walkIFD(off, be: true, depth: 0) }
            }
            // Foveon X3F: fixed-layout header ("FIHR") carries the preview
            // image directory offset/length pair.
            else if n > 40, p[0] == 0x46, p[1] == 0x49, p[2] == 0x48, p[3] == 0x52 {
                if let imgOff = u32(32, be: false), let imgLen = u32(36, be: false),
                   imgLen > 100, imgOff + imgLen <= n, isSOI(imgOff) {
                    best = EmbeddedJPEG(offset: imgOff, length: imgLen)
                }
            }
            return best
        }
    }

    /// Decode the embedded JPEG preview (if any) at up to `capPixels` long
    /// edge. Returns nil quickly when the file has no sniffable preview.
    static func decodeEmbeddedPreview(from url: URL, capPixels: Int) -> CGImage? {
        guard let jpeg = embeddedJPEGPreview(in: url) else { return nil }
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe),
              jpeg.offset >= 0, jpeg.offset + jpeg.length <= d.count
        else { return nil }
        // Slice the mapped range without copying: ImageIO consumes the
        // provider lazily and the parent Data keeps the mapping alive for
        // the duration of the call.
        let slice = d[jpeg.offset..<(jpeg.offset + jpeg.length)]
        guard let source = CGImageSourceCreateWithData(slice as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: capPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
