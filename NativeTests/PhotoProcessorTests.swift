import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Lost_Found

final class PhotoProcessorTests: XCTestCase {
    func testRejectsEmptyAndInvalidImages() {
        XCTAssertThrowsError(try PhotoProcessor.jpeg(from: Data()))
        XCTAssertThrowsError(try PhotoProcessor.jpeg(from: Data("not an image".utf8)))
        XCTAssertThrowsError(try PhotoProcessor.jpeg(from: UIImage()))
    }

    func testLargeUIImageAndEncodedPhotoHaveBoundedDimensionsAndFileSize() throws {
        let image = makeImage(size: CGSize(width: 4000, height: 2000)) { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 2000))
        }
        let encoded = try XCTUnwrap(image.pngData())
        for data in [try PhotoProcessor.jpeg(from: image), try PhotoProcessor.jpeg(from: encoded)] {
            let result = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(result.width, 1600)
            XCTAssertEqual(result.height, 800)
            XCTAssertLessThanOrEqual(data.count, 5 * 1024 * 1024)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        }
    }

    func testTransparentPixelsBecomeWhiteWithoutUpscaling() throws {
        let image = makeImage(size: CGSize(width: 40, height: 40)) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 40))
        }
        let data = try PhotoProcessor.jpeg(from: XCTUnwrap(image.pngData()))
        let result = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(result.width, 40)
        XCTAssertEqual(result.height, 40)
        let background = try pixel(in: result, x: 5, y: 20)
        XCTAssertGreaterThan(background[0], 245)
        XCTAssertGreaterThan(background[1], 245)
        XCTAssertGreaterThan(background[2], 245)
        XCTAssertEqual(background[3], 255)
    }

    func testUIImageOrientationIsAppliedToPixels() throws {
        let raw = try XCTUnwrap(twoColorImage().cgImage)
        let rotated = UIImage(cgImage: raw, scale: 1, orientation: .right)
        let data = try PhotoProcessor.jpeg(from: rotated)
        try assertRotatedColors(in: data)
    }

    func testEncodedEXIFOrientationIsAppliedDuringDownsampling() throws {
        let raw = try XCTUnwrap(twoColorImage().cgImage)
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, raw, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try assertRotatedColors(in: PhotoProcessor.jpeg(from: encoded as Data))
    }

    private func makeImage(size: CGSize, draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    private func twoColorImage() -> UIImage {
        makeImage(size: CGSize(width: 80, height: 40)) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
        }
    }

    private func assertRotatedColors(in data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let image = try XCTUnwrap(UIImage(data: data), file: file, line: line)
        XCTAssertEqual(image.imageOrientation, .up, file: file, line: line)
        let cgImage = try XCTUnwrap(image.cgImage, file: file, line: line)
        XCTAssertEqual(cgImage.width, 40, file: file, line: line)
        XCTAssertEqual(cgImage.height, 80, file: file, line: line)
        let top = try pixel(in: cgImage, x: 20, y: 10)
        let bottom = try pixel(in: cgImage, x: 20, y: 70)
        XCTAssertGreaterThan(top[0], 220, file: file, line: line)
        XCTAssertLessThan(top[2], 35, file: file, line: line)
        XCTAssertGreaterThan(bottom[2], 220, file: file, line: line)
        XCTAssertLessThan(bottom[0], 35, file: file, line: line)
    }

    private func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let start = (y * image.width + x) * 4
        return Array(pixels[start..<(start + 4)])
    }
}
