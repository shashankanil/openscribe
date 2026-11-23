import AppKit

/// Clipboard images for Phone Link: read from and written to the Mac pasteboard, and fitted under the size limit.
enum ClipboardImage {
    static let types: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]

    /// An image on the pasteboard as PNG or JPEG data, or nil if there is none.
    static func read(from pasteboard: NSPasteboard) -> (data: Data, mime: String)? {
        if let png = pasteboard.data(forType: .png) { return (png, "image/png") }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { return (jpeg, "image/jpeg") }
        if let tiff = pasteboard.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return (png, "image/png")
        }
        return nil
    }

    /// Phones send PNG, JPEG, HEIC, WebP or GIF. Mac apps paste PNG and JPEG most reliably, so others become PNG.
    static func pasteable(_ data: Data) -> (data: Data, mime: String)? {
        guard let image = NSBitmapImageRep(data: data) else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return (data, "image/png") }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return (data, "image/jpeg") }
        return image.representation(using: .png, properties: [:]).map { ($0, "image/png") }
    }

    /// Keeps images under `limit`: re-encodes as JPEG, scaling down until it fits. Nil if it can't be decoded.
    static func fit(_ data: Data, mime: String, limit: Int = PhoneLinkProtocol.maxImageBytes) -> (data: Data, mime: String)? {
        if data.count <= limit { return (data, mime) }
        guard var image = NSBitmapImageRep(data: data) else { return nil }
        for _ in 0..<8 {
            if let jpeg = image.representation(using: .jpeg, properties: [.compressionFactor: 0.85]), jpeg.count <= limit {
                return (jpeg, "image/jpeg")
            }
            guard let smaller = scaled(image, by: 0.75) else { return nil }
            image = smaller
        }
        return nil
    }

    private static func scaled(_ image: NSBitmapImageRep, by factor: CGFloat) -> NSBitmapImageRep? {
        let width = max(1, Int(CGFloat(image.pixelsWide) * factor)), height = max(1, Int(CGFloat(image.pixelsHigh) * factor))
        guard let cgImage = image.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map(NSBitmapImageRep.init(cgImage:))
    }
}
