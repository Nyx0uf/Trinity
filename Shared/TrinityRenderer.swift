import AppKit
import MetalKit
import QuartzCore
import Synchronization

/// Owns every Metal resource and encodes one frame of the classic effect per `render` call.
///
/// Each frame runs the rain simulation compute pass, draws glyphs into a 16-bit float surface,
/// builds a five-level bloom pyramid, then maps brightness through the palette into the drawable.
/// Surfaces are reallocated only when the render size, density or bloom size change.
@MainActor
final class TrinityRenderer {
	/// Frame statistics reported by the preview app's diagnostics overlay.
	struct Diagnostics {
		/// Frames submitted per second, measured over roughly one-second windows; 0 until measured.
		var framesPerSecond = 0.0
		/// GPU duration of the most recently completed frame, in milliseconds.
		var gpuMilliseconds = 0.0
		/// Render width in pixels, after the resolution scale.
		var width = 0
		/// Render height in pixels, after the resolution scale.
		var height = 0
		/// Frames committed to the GPU since the renderer was created.
		var submittedFrames = 0
		/// Frames dropped because three were already in flight.
		var skippedFrames = 0
	}

	/// The system default Metal device, also assigned to the presenting layer.
	let device: MTLDevice
	/// Command queue for every frame.
	private let queue: MTLCommandQueue
	/// Compute pipeline advancing glyph symbols and rain brightness (`simulateRain`).
	private let simulation: MTLComputePipelineState
	/// Draws MSDF glyphs into `primary` (`drawGlyphs`).
	private let glyphPipeline: MTLRenderPipelineState
	/// Keeps pixels above the bloom threshold (`highPass`).
	private let highPassPipeline: MTLRenderPipelineState
	/// One-dimensional blur, horizontal or vertical depending on its step (`blurPass`).
	private let blurPipeline: MTLRenderPipelineState
	/// Combines glyphs and bloom, then applies the palette and dither (`composite`).
	private let compositePipeline: MTLRenderPipelineState
	/// The classic MSDF glyph atlas, loaded as linear data with a bottom-left origin.
	private let atlas: MTLTexture
	/// Limits frames in flight to three. Waited on without blocking; signaled by completion handlers.
	private let inFlight = DispatchSemaphore(value: 3)
	/// Ping-pong glyph state textures (symbol index, cycle phase), `gridDimension` square.
	private var symbols: [MTLTexture] = []
	/// Per-cell rain brightness and cursor flag, rewritten every frame.
	private var rain: MTLTexture?
	/// Full-resolution glyph brightness surface.
	private var primary: MTLTexture?
	/// High-pass result for each bloom level.
	private var high: [MTLTexture] = []
	/// Horizontally blurred intermediate for each bloom level.
	private var horizontal: [MTLTexture] = []
	/// Final blurred result for each bloom level, sampled by the composite pass.
	private var bloom: [MTLTexture] = []
	/// 2048-entry palette for the current hue.
	private var palette: MTLTexture?
	/// Hue `palette` was built for; nil before the first frame.
	private var paletteHue: Double?
	/// Simulation grid dimension the state textures were allocated for; 0 before the first frame.
	private var gridDimension = 0
	/// Render size in pixels the surfaces were allocated for.
	private var size = SIMD2<Int>(0, 0)
	/// Bloom size the bloom surfaces were allocated for; negative before the first frame.
	private var bloomScale = -1.0
	/// Index of the `symbols` texture holding the previous frame's state.
	private var stateIndex = 0
	/// True until the first frame after (re)allocating the grid, which seeds random symbols.
	private var firstFrame = true
	/// Accumulated animation time in seconds, scaled by the animation speed.
	private var animationTime = 0.0
	/// Display-link target timestamp of the previous frame; nil after a timing reset.
	private var lastTimestamp: CFTimeInterval?
	/// Start of the current frame-rate measurement window.
	private var measurementStart: CFTimeInterval?
	/// Frames counted in the current measurement window, including the one that opened it.
	private var measurementFrames = 0
	/// Format of the glyph and bloom surfaces. The shaders use only red (trail brightness) and
	/// green (cursor brightness), so two half-float channels halve memory and bandwidth compared
	/// with four; fragment outputs beyond these channels are discarded.
	private static let surfaceFormat = MTLPixelFormat.rg16Float
	/// Per-renderer random seed so instances on different displays differ.
	private let seed = Float.random(in: 0...100)
	/// Statistics updated on the main actor; `diagnostics` adds the GPU time.
	private var counters = Diagnostics()
	/// Duration of the most recently completed command buffer, in milliseconds. Written by
	/// Metal's completion handler off the main actor and read only when diagnostics are requested,
	/// so completing a frame needs no main-actor hop.
	private let gpuMilliseconds = GPUTime()

	/// Uniforms of the last submitted frame; nil until there is an image to capture.
	private var screenshotUniforms: TrinityUniforms?
	/// Backing-pixel dimensions of the last submitted drawable.
	private var screenshotSize = SIMD2<Int>(0, 0)

	/// Frame statistics for the preview app's diagnostics overlay.
	var diagnostics: Diagnostics {
		var value = counters
		value.gpuMilliseconds = gpuMilliseconds.value.withLock { $0 }
		return value
	}

	/// Creates the device, pipelines and atlas from `bundle`, which must be Trinity's own
	/// bundle: inside the screensaver host, the main bundle belongs to the host.
	init(bundle: Bundle) throws {
		guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
			throw Failure(.errorMetalUnavailable)
		}

		self.device = device
		self.queue = queue
		let library = try device.makeDefaultLibrary(bundle: bundle)
		guard let compute = library.makeFunction(name: "simulateRain"),
		      let vertex = library.makeFunction(name: "fullScreen") else {
			throw Failure(.errorShaderLibraryIncomplete)
		}

		simulation = try device.makeComputePipelineState(function: compute)
		func pipeline(_ name: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
			guard let fragment = library.makeFunction(name: name) else { throw Failure(.errorMissingShader(name)) }

			let descriptor = MTLRenderPipelineDescriptor()
			descriptor.label = name
			descriptor.vertexFunction = vertex
			descriptor.fragmentFunction = fragment
			descriptor.colorAttachments[0].pixelFormat = format
			return try device.makeRenderPipelineState(descriptor: descriptor)
		}
		glyphPipeline = try pipeline("drawGlyphs", Self.surfaceFormat)
		highPassPipeline = try pipeline("highPass", Self.surfaceFormat)
		blurPipeline = try pipeline("blurPass", Self.surfaceFormat)
		compositePipeline = try pipeline("composite", .bgra8Unorm)
		guard let url = bundle.url(forResource: "matrixcode_msdf", withExtension: "png") else {
			throw Failure(.errorGlyphAtlasMissing)
		}

		atlas = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
			.SRGB: false,
			.origin: MTKTextureLoader.Origin.bottomLeft,
			.generateMipmaps: false
		])
	}

	/// Forgets the previous timestamp and frame-rate window so the next frame advances by zero
	/// instead of catching up after a pause, suspension or frame-rate change.
	func resetTiming() {
		lastTimestamp = nil
		measurementStart = nil
		measurementFrames = 0
		counters.framesPerSecond = 0
	}

	/// Allocates a private 2D texture of at least 1 × 1 pixels.
	private func texture(
		_ width: Int,
		_ height: Int,
		format: MTLPixelFormat = surfaceFormat,
		usage: MTLTextureUsage = [.shaderRead, .renderTarget]
	) throws -> MTLTexture {
		let descriptor = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: format,
			width: max(1, width),
			height: max(1, height),
			mipmapped: false
		)
		descriptor.usage = usage
		descriptor.storageMode = .private
		guard let value = device.makeTexture(descriptor: descriptor) else {
			throw Failure(.errorTextureAllocation(width, height))
		}

		return value
	}

	/// Reallocates whatever the configuration or render size invalidated: the simulation grid,
	/// the full-resolution and bloom surfaces, and the palette. Existing resources are replaced only
	/// after every new allocation succeeds.
	private func prepare(width: Int, height: Int, configuration c: TrinityConfiguration) throws {
		let dimension = Int(c.columns)
		if gridDimension != dimension {
			let next = try (0..<2).map { _ in
				try texture(dimension, dimension, format: .rgba32Float, usage: [.shaderRead, .shaderWrite])
			}
			let nextRain = try texture(dimension, dimension, format: .rgba32Float, usage: [.shaderRead, .shaderWrite])
			symbols = next
			rain = nextRain
			gridDimension = dimension
			firstFrame = true
			stateIndex = 0
		}
		let sizeChanged = size != SIMD2(width, height)
		if sizeChanged || bloomScale != c.bloomSize {
			// The glyph surface depends only on the render size; bloom size changes keep it.
			var nextPrimary = primary
			if sizeChanged || nextPrimary == nil { nextPrimary = try texture(width, height) }
			var nextHigh: [MTLTexture] = []
			var nextHorizontal: [MTLTexture] = []
			var nextBloom: [MTLTexture] = []
			for level in 0..<5 {
				let scale = c.bloomSize / pow(2, Double(level))
				let w = max(1, Int(Double(width) * scale))
				let h = max(1, Int(Double(height) * scale))
				nextHigh.append(try texture(w, h))
				nextHorizontal.append(try texture(w, h))
				nextBloom.append(try texture(w, h))
			}
			primary = nextPrimary
			high = nextHigh
			horizontal = nextHorizontal
			bloom = nextBloom
			size = SIMD2(width, height)
			bloomScale = c.bloomSize
		}
		if paletteHue != c.hue {
			// Match the original 2048-entry RGB-interpolated HSL palette.
			let descriptor = MTLTextureDescriptor.texture2DDescriptor(
				pixelFormat: .rgba32Float,
				width: 2048,
				height: 1,
				mipmapped: false
			)
			descriptor.storageMode = .shared
			guard let nextPalette = device.makeTexture(descriptor: descriptor) else { throw Failure(.errorPaletteAllocation) }

			let stops: [(Int, SIMD3<Float>)] = [0.0, 0.2, 0.7, 0.8].map { lightness in
				return (Int(lightness * 2047), Self.hsl(c.hue, 0.9, lightness))
			}
			let lastColor = stops[stops.count - 1].1
			var pixels = [SIMD4<Float>](repeating: .zero, count: 2048)
			for index in pixels.indices {
				var rgb = lastColor
				for pair in zip(stops, stops.dropFirst()) where index >= pair.0.0 && index < pair.1.0 {
					let fraction = Float(index - pair.0.0) / Float(pair.1.0 - pair.0.0)
					rgb = pair.0.1 * (1 - fraction) + pair.1.1 * fraction
				}
				pixels[index] = SIMD4(rgb.x, rgb.y, rgb.z, 1)
			}
			pixels.withUnsafeBytes { bytes in
				guard let baseAddress = bytes.baseAddress else { return }

				nextPalette.replace(
					region: MTLRegionMake2D(0, 0, 2048, 1),
					mipmapLevel: 0,
					withBytes: baseAddress,
					bytesPerRow: 2048 * MemoryLayout<SIMD4<Float>>.stride
				)
			}
			palette = nextPalette
			paletteHue = c.hue
		}
	}

	/// Converts HSL (each component from 0 to 1) to RGB, matching the shaders' `hsl` function.
	private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> SIMD3<Float> {
		func channel(_ offset: Double) -> Float {
			let h = hue + offset
			let k = (h - floor(h)) * 6
			let rgb = min(1, max(0, abs(k - 3) - 1))
			return Float(lightness + (rgb - 0.5) * (1 - abs(2 * lightness - 1)) * saturation)
		}
		return SIMD3(channel(0), channel(2.0 / 3), channel(1.0 / 3))
	}

	/// Encodes one full-screen fragment pass into `destination`. Sources bind to consecutive
	/// texture indices; buffer 0 receives `step` when given, otherwise the frame uniforms.
	private func pass(
		_ command: MTLCommandBuffer,
		pipeline: MTLRenderPipelineState,
		destination: MTLTexture,
		sources: [MTLTexture],
		uniforms: inout TrinityUniforms,
		step: SIMD2<Float>? = nil
	) throws {
		let descriptor = MTLRenderPassDescriptor()
		descriptor.colorAttachments[0].texture = destination
		descriptor.colorAttachments[0].loadAction = .dontCare
		descriptor.colorAttachments[0].storeAction = .store
		guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
			throw Failure(.errorRenderEncoder)
		}

		encoder.label = pipeline.label
		encoder.setRenderPipelineState(pipeline)
		for (index, source) in sources.enumerated() { encoder.setFragmentTexture(source, index: index) }
		if var step {
			encoder.setFragmentBytes(&step, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
		} else {
			encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TrinityUniforms>.stride, index: 0)
		}
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		encoder.endEncoding()
	}

	/// Encodes the five-level bloom pyramid: high-pass each level from the one above, then blur it
	/// horizontally and vertically. Skipped entirely when bloom is disabled.
	private func encodeBloom(
		_ command: MTLCommandBuffer,
		from primary: MTLTexture,
		configuration c: TrinityConfiguration,
		uniforms: inout TrinityUniforms
	) throws {
		guard c.bloomStrength > 0, c.bloomSize > 0 else { return }

		for level in 0..<5 {
			try pass(
				command,
				pipeline: highPassPipeline,
				destination: high[level],
				sources: [level == 0 ? primary : high[level - 1]],
				uniforms: &uniforms
			)
			try pass(
				command,
				pipeline: blurPipeline,
				destination: horizontal[level],
				sources: [high[level]],
				uniforms: &uniforms,
				step: SIMD2(1 / Float(high[level].width), 0)
			)
			try pass(
				command,
				pipeline: blurPipeline,
				destination: bloom[level],
				sources: [horizontal[level]],
				uniforms: &uniforms,
				step: SIMD2(0, 1 / Float(high[level].height))
			)
		}
	}

	/// Encodes, presents and commits one frame to `layer`, advancing the animation by the time
	/// since the previous `timestamp`, clamped to 0.1 s. Skips the frame without blocking when three
	/// are already in flight, and does nothing while the drawable is empty or unavailable.
	func render(to layer: CAMetalLayer, at timestamp: CFTimeInterval, configuration c: TrinityConfiguration) throws {
		guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return }
		guard inFlight.wait(timeout: .now()) == .success else {
			counters.skippedFrames += 1
			return
		}

		var committed = false
		defer { if !committed { inFlight.signal() } }
		guard let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else { return }

		let width = max(1, Int(layer.drawableSize.width * c.resolution))
		let height = max(1, Int(layer.drawableSize.height * c.resolution))
		try prepare(width: width, height: height, configuration: c)
		guard let rain, let primary, let palette else { return }

		let delta = min(0.1, max(0, lastTimestamp.map { timestamp - $0 } ?? 0)) * c.animationSpeed
		animationTime += delta
		lastTimestamp = timestamp
		var uniforms = TrinityUniforms()
		uniforms.timing = SIMD4(Float(animationTime), Float(delta), firstFrame ? 1 : 0, seed)
		uniforms.grid = SIMD4(Float(gridDimension), Float(c.fallSpeed), Float(c.animationSpeed), Float(c.cycleSpeed))
		uniforms.appearance = SIMD4(Float(c.trailLength), Float(c.brightness), Float(c.cursorIntensity), Float(c.hue))
		uniforms.effects = SIMD4(Float(c.bloomStrength), Float(c.bloomSize), Float(c.dither), 0.1)
		uniforms.viewport = SIMD4(Float(width), Float(height), 0, 0)
		guard let compute = command.makeComputeCommandEncoder() else { throw Failure(.errorSimulationEncoder) }

		compute.label = "Classic rain and glyph simulation"
		compute.setComputePipelineState(simulation)
		compute.setTexture(symbols[stateIndex], index: 0)
		compute.setTexture(symbols[1 - stateIndex], index: 1)
		compute.setTexture(rain, index: 2)
		compute.setBytes(&uniforms, length: MemoryLayout<TrinityUniforms>.stride, index: 0)
		compute.dispatchThreads(
			MTLSize(width: gridDimension, height: gridDimension, depth: 1),
			threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
		)
		compute.endEncoding()
		let nextIndex = 1 - stateIndex
		try pass(
			command,
			pipeline: glyphPipeline,
			destination: primary,
			sources: [rain, symbols[nextIndex], atlas],
			uniforms: &uniforms
		)
		try encodeBloom(command, from: primary, configuration: c, uniforms: &uniforms)
		try pass(
			command,
			pipeline: compositePipeline,
			destination: drawable.texture,
			sources: [primary] + bloom + [palette],
			uniforms: &uniforms
		)
		command.present(drawable)
		let semaphore = inFlight
		let gpuTime = gpuMilliseconds
		command.addCompletedHandler { buffer in
			gpuTime.value.withLock { $0 = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000 }
			semaphore.signal()
			if let error = buffer.error {
				TrinityLog.rendering.error("GPU command buffer failed: \(error.localizedDescription, privacy: .public)")
			}
		}
		command.commit()
		screenshotUniforms = uniforms
		screenshotSize = SIMD2(drawable.texture.width, drawable.texture.height)
		committed = true
		stateIndex = nextIndex
		firstFrame = false
		counters.width = width
		counters.height = height
		counters.submittedFrames += 1
		measurementFrames += 1
		if let start = measurementStart, timestamp - start >= 1 {
			counters.framesPerSecond = Double(measurementFrames - 1) / (timestamp - start)
			measurementStart = timestamp
			measurementFrames = 1
		} else if measurementStart == nil { measurementStart = timestamp }
	}

	/// Captures the most recently submitted rain frame at the drawable's backing resolution.
	/// Reuses the composite pass without advancing the simulation or capturing AppKit overlays.
	func screenshot() async throws -> TrinityScreenshot {
		guard var uniforms = screenshotUniforms, let primary, let palette,
		      let command = queue.makeCommandBuffer() else {
			throw Failure(.errorScreenshotUnavailable)
		}

		let width = screenshotSize.x
		let height = screenshotSize.y
		let destination = try texture(width, height, format: .bgra8Unorm, usage: .renderTarget)
		let bytesPerRow = (width * 4 + 255) / 256 * 256
		guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared) else {
			throw Failure(.errorScreenshotCapture)
		}

		try pass(command, pipeline: compositePipeline, destination: destination, sources: [primary] + bloom + [palette], uniforms: &uniforms)
		guard let blit = command.makeBlitCommandEncoder() else { throw Failure(.errorScreenshotCapture) }

		blit.copy(
			from: destination,
			sourceSlice: 0,
			sourceLevel: 0,
			sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
			sourceSize: MTLSize(width: width, height: height, depth: 1),
			to: buffer,
			destinationOffset: 0,
			destinationBytesPerRow: bytesPerRow,
			destinationBytesPerImage: bytesPerRow * height
		)
		blit.endEncoding()
		let readback = ScreenshotReadback(buffer: buffer)
		return try await withCheckedThrowingContinuation { continuation in
			command.addCompletedHandler { completed in
				if let error = completed.error {
					continuation.resume(throwing: error)
				} else {
					let pixels = readback.pixels(count: bytesPerRow * height)
					continuation.resume(returning: TrinityScreenshot(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow))
				}
			}
			command.commit()
		}
	}

	/// Transfers a Metal buffer to its completion handler, which alone reads the completed pixels.
	/// Metal's buffer protocol is not Sendable. This wrapper is safe because the command owns the
	/// only GPU write, and the CPU reads only after that command's completion fence has fired.
	nonisolated private struct ScreenshotReadback: @unchecked Sendable {
		/// Retains the readback allocation until the completion handler copies it.
		let buffer: MTLBuffer

		/// Copies completed bytes into immutable, Sendable storage; never called before GPU completion.
		func pixels(count: Int) -> Data { Data(bytes: buffer.contents(), count: count) }
	}

	/// Lock-protected GPU duration shared between the renderer and Metal's completion handlers.
	nonisolated final class GPUTime: Sendable {
		/// Milliseconds the last completed command buffer spent on the GPU.
		let value = Mutex(0.0)
	}

	/// A rendering setup or encoding error with a localized, user-presentable description.
	struct Failure: LocalizedError {
		/// The localized description shown by the preview app's alert.
		let message: LocalizedStringResource

		/// Creates a failure described by `message`.
		init(_ message: LocalizedStringResource) { self.message = message }

		/// The resolved message.
		var errorDescription: String? { String(localized: message) }
	}
}
