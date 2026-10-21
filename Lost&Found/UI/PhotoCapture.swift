import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let onCapture: (UIImage) -> Void
    let onFailure: ((Error) -> Void)?

    init(onCapture: @escaping (UIImage) -> Void, onFailure: ((Error) -> Void)? = nil) {
        self.onCapture = onCapture
        self.onFailure = onFailure
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.dismiss()
            guard let image = info[.originalImage] as? UIImage else {
                parent.onFailure?(PhotoProcessor.ProcessingError.invalidImage)
                return
            }
            parent.onCapture(image)
        }
    }
}

enum PhotoProcessor {
    private static let maximumPixelDimension: CGFloat = 1600
    private static let maximumBytes = 5 * 1024 * 1024

    enum ProcessingError: LocalizedError {
        case invalidImage
        case encodingFailed
        case photoTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidImage:
                "This photo could not be opened. Please choose another image."
            case .encodingFailed:
                "This photo could not be prepared for upload. Please try another photo."
            case .photoTooLarge:
                "The prepared photo is larger than 5 MB. Please choose another photo."
            }
        }
    }

    /// Downsample the encoded source before decoding a full-resolution photo.
    static func jpeg(from data: Data) throws -> Data {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0 else {
            throw ProcessingError.invalidImage
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maximumPixelDimension),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ProcessingError.invalidImage
        }
        return try jpeg(from: UIImage(cgImage: thumbnail))
    }

    /// Drawing applies UIImage orientation and composites transparent pixels onto white.
    static func jpeg(from image: UIImage) throws -> Data {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              image.cgImage != nil || image.ciImage != nil else {
            throw ProcessingError.invalidImage
        }

        let scale = min(1, maximumPixelDimension / max(pixelWidth, pixelHeight))
        let size = CGSize(
            width: max(1, (pixelWidth * scale).rounded(.down)),
            height: max(1, (pixelHeight * scale).rounded(.down))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderedImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = renderedImage.jpegData(compressionQuality: 0.85), !jpeg.isEmpty else {
            throw ProcessingError.encodingFailed
        }
        guard jpeg.count <= maximumBytes else {
            throw ProcessingError.photoTooLarge
        }
        return jpeg
    }
}
