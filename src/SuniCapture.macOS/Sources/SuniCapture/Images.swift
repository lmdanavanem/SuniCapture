import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Exports flattened pixels only: no original image, edit layers or source metadata.
enum ImageFiles {
    static let maxPixels = 100_000_000
    static let importTypes: [UTType] = [.png, .jpeg, .bmp, .tiff, .gif]

    static func load(_ url: URL) throws -> CGImage {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw AppError(L.t("image.missing"))
        }
        if let size = attributes[.size] as? Int, size > 512 * 1024 * 1024 { throw AppError(L.t("image.limit")) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw AppError(L.t("image.empty")) }
        guard width >= 1, height >= 1, width * height <= maxPixels else { throw AppError(L.t("image.pixelLimit")) }
        // First frame only (GIF), oriented like the Finder shows it.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AppError(L.t("image.empty"))
        }
        return try normalized(image)
    }

    static func save(_ image: CGImage, to url: URL) throws {
        try validate(image)
        let fileExtension = url.pathExtension.lowercased()
        let type: UTType
        switch fileExtension {
        case "png": type = .png
        case "jpg", "jpeg": type = .jpeg
        case "bmp": type = .bmp
        case "pdf": type = .pdf
        default: throw AppError(L.t("image.exportType"))
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".sunicapture-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        if type == .pdf {
            try writePDF(image, to: temporary)
        } else {
            let pixels = type == .png ? image : try flatten(image)
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else {
                throw AppError(L.t("image.exportType"))
            }
            let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.94] : [:]
            CGImageDestinationAddImage(destination, pixels, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AppError(L.t("error.export")) }
        }
        guard rename(temporary.path, url.path) == 0 else { throw AppError(String(cString: strerror(errno))) }
    }

    nonisolated static func thumbnail(_ url: URL, maxPixel: Int = 400) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func validate(_ image: CGImage) throws {
        guard image.width >= 1, image.height >= 1, image.width * image.height <= maxPixels else {
            throw AppError(L.t("image.pixelLimit"))
        }
    }

    static func context(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Redraws into plain sRGB RGBA pixels, which also drops any embedded metadata.
    static func normalized(_ image: CGImage) throws -> CGImage {
        guard let context = context(width: image.width, height: image.height) else { throw AppError(L.t("image.pixelLimit")) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw AppError(L.t("image.pixelLimit")) }
        return result
    }

    static func flatten(_ image: CGImage) throws -> CGImage {
        guard let context = context(width: image.width, height: image.height, opaque: true) else { throw AppError(L.t("image.pixelLimit")) }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw AppError(L.t("image.pixelLimit")) }
        return result
    }

    /// Single page sized to the image, so the screenshot keeps its aspect ratio without clipping.
    private static func writePDF(_ image: CGImage, to url: URL) throws {
        let scale = min(0.75, 14400.0 / Double(max(image.width, image.height)))
        var box = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw AppError(L.t("error.export")) }
        context.beginPDFPage(nil)
        context.draw(try flatten(image), in: box)
        context.endPDFPage()
        context.closePDF()
    }
}

enum Clipboard {
    static func write(_ image: CGImage) -> Bool {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        return pasteboard.setData(png, forType: .png) && pasteboard.setData(representation.tiffRepresentation, forType: .tiff)
    }

    static func readImage() -> CGImage? {
        guard let image = NSImage(pasteboard: .general) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        // Prefer the largest bitmap representation so Retina clipboard images keep their pixels.
        if let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }) {
            return bitmap.cgImage
        }
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
