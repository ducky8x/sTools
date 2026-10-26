import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Copies a user-chosen crosshair image into sTools' own Images folder and loads it back as a CGImage.
enum CrosshairImageImport {
    /// A user-facing message explaining why an image couldn't be imported.
    struct ImportError: Error, Equatable {
        let message: String
    }

    /// Copies `url` into `directory` under a fresh name and returns the stored relative name
    /// (`Images/<uuid>.<ext>`), or a user-facing message on failure.
    static func importImage(from url: URL, into directory: URL) -> Result<String, ImportError> {
        guard loadImage(at: url) != nil else {
            return .failure(ImportError(message: "sTools can\u{2019}t read that file. Choose a PNG, JPEG or other image."))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(ImportError(message: "sTools couldn\u{2019}t create its Images folder. Check that your disk isn\u{2019}t full, then try again."))
        }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let destination = directory.appending(path: name)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return .failure(ImportError(message: "sTools couldn't copy that image."))
        }
        return .success("Images/\(name)")
    }

    /// Loads a raster image (PNG, JPEG, HEIC, TIFF, ...) from disk, or nil if it can't be read as an image.
    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
