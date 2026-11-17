import AppKit
import MetalKit
import QuartzCore

@MainActor
final class TrinityRenderer {
	struct Diagnostics {
		var framesPerSecond = 0.0
		var gpuMilliseconds = 0.0
		var width = 0
		var height = 0
		var submittedFrames = 0
		var skippedFrames = 0
	}

	let device: MTLDevice
	private let queue: MTLCommandQueue
	private let simulation: MTLComputePipelineState
	private let glyphPipeline: MTLRenderPipelineState
	private let highPassPipeline: MTLRenderPipelineState
	private let blurPipeline: MTLRenderPipelineState
	private let compositePipeline: MTLRenderPipelineState
	private let atlas: MTLTexture
	private let inFlight = DispatchSemaphore(value: 3)
	private var symbols: [MTLTexture] = []
	private var rain: MTLTexture?
	private var primary: MTLTexture?
	private var high: [MTLTexture] = []
	private var horizontal: [MTLTexture] = []
	private var bloom: [MTLTexture] = []
	private var palette: MTLTexture?
	private var paletteHue: Double?
	private var gridDimension = 0
	private var size = SIMD2<Int>(0, 0)
	private var bloomScale = -1.0
	private var stateIndex = 0
	private var firstFrame = true
	private var animationTime = 0.0
	private var lastTimestamp: CFTimeInterval?
	private var measurementStart: CFTimeInterval?
	private var measurementFrames = 0
	private let seed = Float.random(in: 0...100)
	private(set) var diagnostics = Diagnostics()

	init(bundle: Bundle) throws {
		guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
			throw Failure("Metal is unavailable on this Mac.")
		}

		self.device = device
		self.queue = queue
		let library = try device.makeDefaultLibrary(bundle: bundle)
		guard let compute = library.makeFunction(name: "simulateRain"),
		      let vertex = library.makeFunction(name: "fullScreen") else {
			throw Failure("The bundled Metal library is incomplete.")
		}

		simulation = try device.makeComputePipelineState(function: compute)
		func pipeline(_ name: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
			guard let fragment = library.makeFunction(name: name) else { throw Failure("Missing shader: \(name)") }

			let descriptor = MTLRenderPipelineDescriptor()
			descriptor.label = name
			descriptor.vertexFunction = vertex
			descriptor.fragmentFunction = fragment
			descriptor.colorAttachments[0].pixelFormat = format
			return try device.makeRenderPipelineState(descriptor: descriptor)
		}
		glyphPipeline = try pipeline("drawGlyphs", .rgba16Float)
		highPassPipeline = try pipeline("highPass", .rgba16Float)
		blurPipeline = try pipeline("blurPass", .rgba16Float)
		compositePipeline = try pipeline("composite", .bgra8Unorm)
		guard let url = bundle.url(forResource: "matrixcode_msdf", withExtension: "png") else {
			throw Failure("The classic glyph atlas is missing.")
		}

		atlas = try MTKTextureLoader(device: device).newTexture(URL: url, options: [
			.SRGB: false,
			.origin: MTKTextureLoader.Origin.bottomLeft,
			.generateMipmaps: false
		])
	}

	func resetTiming() {
		lastTimestamp = nil
		measurementStart = nil
		measurementFrames = 0
		diagnostics.framesPerSecond = 0
	}

	private func texture(
		_ width: Int,
		_ height: Int,
		format: MTLPixelFormat = .rgba16Float,
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
			throw Failure("Metal could not allocate a \(width) × \(height) rendering texture.")
		}

		return value
	}

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
		if size != SIMD2(width, height) || bloomScale != c.bloomSize {
			let nextPrimary = try texture(width, height)
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
			guard let nextPalette = device.makeTexture(descriptor: descriptor) else { throw Failure("Cannot allocate palette.") }

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

	private static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> SIMD3<Float> {
		func channel(_ offset: Double) -> Float {
			let h = hue + offset
			let k = (h - floor(h)) * 6
			let rgb = min(1, max(0, abs(k - 3) - 1))
			return Float(lightness + (rgb - 0.5) * (1 - abs(2 * lightness - 1)) * saturation)
		}
		return SIMD3(channel(0), channel(2.0 / 3), channel(1.0 / 3))
	}

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
			throw Failure("Cannot create a Metal render encoder.")
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

	// Five-level bloom pyramid: high-pass each level from the one above, then blur it
	// horizontally and vertically. Skipped entirely when bloom is disabled.
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

	func render(to layer: CAMetalLayer, at timestamp: CFTimeInterval, configuration c: TrinityConfiguration) throws {
		guard layer.drawableSize.width > 0, layer.drawableSize.height > 0 else { return }
		guard inFlight.wait(timeout: .now()) == .success else {
			diagnostics.skippedFrames += 1
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
		guard let compute = command.makeComputeCommandEncoder() else { throw Failure("Cannot create simulation encoder.") }

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
		command.addCompletedHandler { [weak self] buffer in
			let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
			let error = buffer.error?.localizedDescription
			semaphore.signal()
			Task { @MainActor [weak self] in
				self?.diagnostics.gpuMilliseconds = milliseconds
				if let error { NSLog("Trinity GPU error: %@", error) }
			}
		}
		command.commit()
		committed = true
		stateIndex = nextIndex
		firstFrame = false
		diagnostics.width = width
		diagnostics.height = height
		diagnostics.submittedFrames += 1
		measurementFrames += 1
		if let start = measurementStart, timestamp - start >= 1 {
			diagnostics.framesPerSecond = Double(measurementFrames - 1) / (timestamp - start)
			measurementStart = timestamp
			measurementFrames = 1
		} else if measurementStart == nil { measurementStart = timestamp }
	}

	struct Failure: LocalizedError {
		let message: String
		init(_ message: String) { self.message = message }
		var errorDescription: String? { message }
	}
}
