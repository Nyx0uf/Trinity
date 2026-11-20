import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Completed GPU readback of a rain frame, owned until PNG encoding finishes.
nonisolated struct TrinityScreenshot: Sendable {
	/// Immutable BGRA pixels copied after the GPU completes its readback.
	let pixels: Data
	/// Image width in backing pixels.
	let width: Int
	/// Image height in backing pixels.
	let height: Int
	/// Aligned byte stride between pixel rows.
	let bytesPerRow: Int

	/// Encodes and writes a PNG away from the main actor, preserving the renderer's sRGB colors.
	@concurrent func savePNG(to url: URL) async throws {
		let encoded = NSMutableData()
		guard let provider = CGDataProvider(data: pixels as CFData),
		      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
		      let image = CGImage(
		      	width: width,
		      	height: height,
		      	bitsPerComponent: 8,
		      	bitsPerPixel: 32,
		      	bytesPerRow: bytesPerRow,
		      	space: colorSpace,
		      	bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
		      	provider: provider,
		      	decode: nil,
		      	shouldInterpolate: false,
		      	intent: .defaultIntent
		      ),
		      let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
			throw Failure()
		}

		CGImageDestinationAddImage(destination, image, nil)
		// Encode to memory so a failed write cannot leave a partial PNG on the Desktop.
		guard CGImageDestinationFinalize(destination) else {
			throw Failure()
		}

		try (encoded as Data).write(to: url, options: .atomic)
	}

	/// A PNG encoding failure with a localized description.
	private struct Failure: LocalizedError {
		/// Description presented by the preview app.
		var errorDescription: String? { String(localized: .errorScreenshotEncoding) }
	}
}
