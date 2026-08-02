import AppKit
import Foundation
import ImageIO

// SEARCH-HELPER: rendered Markdown local image provider, preview image containment, image byte cap

/// Pure path-resolution outcome used before any local image bytes are read.
enum AgentPreviewMarkdownImageSourceResolution: Equatable {
    case local(URL)
    case external(URL)
    case rejected(AgentPreviewMarkdownImageRejection)
}

enum AgentPreviewMarkdownImageRejection: Equatable {
    case emptyPath
    case unsupportedScheme
    case absolutePath
    case outsideScope
    case missing
    case notRegularFile
}

/// Byte-gated result. Tests stop at this seam so they never require an AppKit image server.
enum AgentPreviewMarkdownImageDataResolution: Equatable {
    case loaded(Data, URL)
    case external(URL)
    case rejected(AgentPreviewMarkdownImageRejection)
    case tooLarge(byteCount: Int)
    case unreadable
}

/// The only image loader wired into rendered Markdown in the utility-panel Preview.
///
/// It shares document containment exactly: both the checkout and candidate are symlink-resolved,
/// and only a candidate below that resolved checkout is accepted. HTTP(S) is classified but never
/// read, allowing `EnhancedMarkdownCompiler` to preserve its historical linked-alt-text fallback.
struct AgentPreviewMarkdownImageProvider: @unchecked Sendable {
    static let maximumImageBytes = 10 * 1024 * 1024

    let document: AgentPreviewResolvedDocument
    var maximumBytes = maximumImageBytes

    func resolve(source: String) -> AgentPreviewMarkdownImageSourceResolution {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.emptyPath) }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return .external(url)
            }
            return .rejected(.unsupportedScheme)
        }

        var path = trimmed
        if let fragment = path.firstIndex(of: "#") {
            path = String(path[..<fragment])
        }
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return .rejected(.emptyPath) }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            return .rejected(.absolutePath)
        }

        let candidate = document.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = document.checkoutRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard AgentPreviewDocumentResolver.isContained(candidate, in: root) else {
            return .rejected(.outsideScope)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return .rejected(.missing)
        }
        guard !isDirectory.boolValue else { return .rejected(.notRegularFile) }
        return .local(candidate)
    }

    func loadData(source: String) -> AgentPreviewMarkdownImageDataResolution {
        guard !Task.isCancelled else { return .unreadable }
        switch resolve(source: source) {
        case let .external(url):
            return .external(url)
        case let .rejected(rejection):
            return .rejected(rejection)
        case let .local(url):
            guard !Task.isCancelled else { return .unreadable }
            let byteCount: Int
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return .rejected(.notRegularFile) }
                byteCount = values.fileSize ?? 0
            } catch {
                return .unreadable
            }
            guard byteCount <= maximumBytes else { return .tooLarge(byteCount: byteCount) }

            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                guard data.count <= maximumBytes else { return .tooLarge(byteCount: data.count) }
                return .loaded(data, url)
            } catch {
                return .unreadable
            }
        }
    }

    func enhancedProvider() -> EnhancedMarkdownImageProvider {
        EnhancedMarkdownImageProvider { request in
            attributedImage(for: request)
        }
    }

    private func attributedImage(for request: EnhancedMarkdownImageRequest) -> NSAttributedString? {
        switch loadData(source: request.source) {
        case .external:
            // Returning nil deliberately invokes EnhancedMarkdownCompiler's linked-alt fallback.
            return nil
        case let .loaded(data, _):
            guard let attachment = makeAttachment(
                data: data,
                maximumDisplayWidth: request.maximumDisplayWidth
            ) else {
                return placeholder(
                    altText: request.altText,
                    source: request.source,
                    fontSize: request.fontSize
                )
            }
            return NSAttributedString(attachment: attachment)
        case .rejected, .tooLarge, .unreadable:
            return placeholder(
                altText: request.altText,
                source: request.source,
                fontSize: request.fontSize
            )
        }
    }

    private func makeAttachment(data: Data, maximumDisplayWidth: CGFloat) -> NSTextAttachment? {
        guard !Task.isCancelled else { return nil }
        let safeWidth = max(1, maximumDisplayWidth)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let thumbnailLimit = max(1, safeWidth * 2)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailLimit,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let rounded = roundedImage(thumbnail)
        else { return nil }

        let displayWidth = min(safeWidth, CGFloat(sourceWidth))
        let displaySize = NSSize(
            width: max(1, displayWidth),
            height: max(1, displayWidth * CGFloat(rounded.height) / CGFloat(rounded.width))
        )
        let image = NSImage(cgImage: rounded, size: displaySize)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: displaySize)
        return attachment
    }

    private func roundedImage(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = min(CGFloat(12), min(rect.width, rect.height) / 8)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private func placeholder(altText: String, source: String, fontSize: CGFloat) -> NSAttributedString {
        let label = altText.isEmpty ? "Image unavailable" : "Image unavailable: \(altText)"
        let result = NSMutableAttributedString(string: "[\(label)]", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttribute(.markdownRawLink, value: source, range: fullRange)
        result.addAttribute(.link, value: source, range: fullRange)
        return result
    }
}
