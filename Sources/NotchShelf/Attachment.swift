import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Файл, прикреплённый к вопросу: картинка, PDF или текстовый файл.
struct Attachment: Identifiable, Equatable, Sendable {
    enum Kind: Sendable, Equatable { case image, pdf, text }

    let id = UUID()
    let name: String
    let kind: Kind
    let mediaType: String   // image/jpeg, image/png, application/pdf, text/plain
    let data: Data          // байты картинки/PDF или текст в UTF-8

    var base64: String { data.base64EncodedString() }
    var textContent: String { String(decoding: data, as: UTF8.self) }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

enum AttachmentError: LocalizedError {
    case unsupported(String)
    case tooLarge(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let n): return "«\(n)»: такой формат пока не поддерживается (можно картинки, PDF и текстовые файлы)"
        case .tooLarge(let n): return "«\(n)» слишком большой"
        case .unreadable(let n): return "Не удалось прочитать «\(n)»"
        }
    }
}

/// Готовит файлы к отправке: картинки уменьшает (длинная сторона до 1568 px — рекомендация Anthropic),
/// HEIC/TIFF и прочее перекодирует в JPEG/PNG.
enum AttachmentLoader {
    static let maxImageSide = 1568
    static let maxPDFBytes = 25 * 1024 * 1024
    static let maxTextBytes = 300 * 1024

    static func load(url: URL) -> Result<Attachment, AttachmentError> {
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension.lowercased())

        if type?.conforms(to: .image) == true {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let encoded = encodeImage(source) else { return .failure(.unreadable(name)) }
            return .success(Attachment(name: name, kind: .image, mediaType: encoded.mediaType, data: encoded.data))
        }
        if type?.conforms(to: .pdf) == true {
            guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(name)) }
            guard data.count <= maxPDFBytes else { return .failure(.tooLarge(name)) }
            return .success(Attachment(name: name, kind: .pdf, mediaType: "application/pdf", data: data))
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true
            || type?.conforms(to: .json) == true || type?.conforms(to: .xml) == true {
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1251) else { return .failure(.unreadable(name)) }
            guard data.count <= maxTextBytes else { return .failure(.tooLarge(name)) }
            return .success(Attachment(name: name, kind: .text, mediaType: "text/plain", data: Data(text.utf8)))
        }
        return .failure(.unsupported(name))
    }

    /// Картинка без файла (например, перетащенная из браузера).
    static func load(imageData: Data, name: String) -> Attachment? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let encoded = encodeImage(source) else { return nil }
        return Attachment(name: name, kind: .image, mediaType: encoded.mediaType, data: encoded.data)
    }

    private static func encodeImage(_ source: CGImageSource) -> (data: Data, mediaType: String)? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // С прозрачностью — PNG (иначе фон станет чёрным), без — компактный JPEG
        let alpha = image.alphaInfo
        let hasAlpha = alpha == .first || alpha == .last || alpha == .premultipliedFirst || alpha == .premultipliedLast
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, hasAlpha ? "image/png" : "image/jpeg")
    }
}
