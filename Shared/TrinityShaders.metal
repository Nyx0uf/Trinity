// Fresh Metal translation of Rezmason/matrix's classic renderer.
// Original © 2018 Rezmason, MIT; see Resources/Rezmason-LICENSE.txt.
#include <metal_stdlib>
#include "TrinityUniforms.h"
using namespace metal;

/// Period of upstream's GLSL `mod`-based random function.
constant float pi = 3.14159265359;
/// Bilinear, clamped sampler used by every pass.
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

/// Upstream's hash: a pseudo-random value in [0, 1) for `uv`.
float randomFloat(float2 uv) {
	float d = dot(uv, float2(12.9898, 78.233));
	float sn = d - floor(d / pi) * pi; // GLSL mod, including negative inputs
	return fract(sin(sn) * 43758.5453);
}

/// Brightness from 0 to 1 of the falling illumination at grid `position` and animation `time`.
float rainBrightness(float time, float2 position, constant TrinityUniforms &u) {
	float offset = randomFloat(float2(position.x, 0)) * 1000;
	float speed = randomFloat(float2(position.x + 0.1, 0)) * 0.5 + 0.5;
	float columnTime = offset + time * u.grid.y * speed;
	float t = (position.y * 0.01 + columnTime) / u.appearance.x;
	t += 0.3 * sin(sqrt(2.0f) * t) + 0.2 * sin(sqrt(5.0f) * t);
	return 1 - fract(t);
}

/// Per-cell simulation: writes rain brightness and a cursor flag to `rain`, and advances each
/// glyph's symbol and cycle phase from `previous` into `symbols`.
kernel void simulateRain(texture2d<float, access::read> previous [[texture(0)]],
	texture2d<float, access::write> symbols [[texture(1)]],
	texture2d<float, access::write> rain [[texture(2)]],
	constant TrinityUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
	if (p.x >= symbols.get_width() || p.y >= symbols.get_height()) return;
	float2 pos = float2(p) + 0.5;
	float2 uv = pos / u.grid.x;
	float simTime = u.timing.x;
	float brightness = rainBrightness(simTime, pos, u);
	float below = rainBrightness(simTime, pos - float2(0, 1), u);
	rain.write(float4(brightness, brightness > below ? 1 : 0, 1, 1), p);
	float2 state;
	if (u.timing.z > 0) {
		state = float2(floor(57 * randomFloat(uv + u.timing.w)), randomFloat(uv + 0.5));
	} else {
		state = previous.read(p).rg;
	}
	// The WebGL shader advances by cycleSpeed each 60 Hz reference frame.
	// Accumulate elapsed animation seconds instead, independent of presentation rate.
	state.y += u.grid.w * u.timing.y * 60;
	if (state.y >= 1) {
		state.x = floor(57 * randomFloat(uv + simTime + u.timing.w));
		state.y = fract(state.y);
	}
	symbols.write(float4(state, 0, 0), p);
}

/// Rasterized full-screen position and texture coordinate with a top-left origin.
struct Raster { float4 position [[position]]; float2 uv; };
/// Emits one oversized triangle covering the viewport; draw with three vertices.
vertex Raster fullScreen(uint id [[vertex_id]]) {
	float2 p = float2((id << 1) & 2, id & 2);
	return { float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y) };
}

/// Draws each cell's MSDF glyph. Red holds trail brightness and green cursor brightness.
fragment float4 drawGlyphs(Raster in [[stage_in]],
	texture2d<float> rain [[texture(0)]], texture2d<float> symbols [[texture(1)]],
	texture2d<float> atlas [[texture(2)]], constant TrinityUniforms &u [[buffer(0)]]) {
	// Original square grid, cropped along the shorter viewport dimension.
	float2 size = u.viewport.xy;
	float2 gridUV = (float2(in.uv.x, 1 - in.uv.y) - 0.5) * size / max(size.x, size.y) + 0.5;
	float2 cellUV = fract(gridUV * u.grid.x);
	uint2 cell = min(uint2(gridUV * u.grid.x), uint2(uint(u.grid.x) - 1));
	float4 drop = rain.read(cell);
	uint index = uint(symbols.read(cell).r);
	// Atlas uses OpenGL's bottom-left origin, including glyph-local coordinates.
	float2 tile = float2(index % 8, 7 - index / 8);
	float2 atlasUV = (cellUV + tile) / 8;
	float3 msdf = atlas.sample(linearSampler, atlasUV).rgb;
	float distance = max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b));
	// Derivatives of the unwrapped coordinates avoid seams at glyph boundaries.
	float2 derivative = max(fwidth(gridUV * u.grid.x / 8), float2(1e-6));
	float2 unitRange = 4.0 / float2(atlas.get_width(), atlas.get_height());
	float pixelRange = max(0.5 * dot(unitRange, 1.0 / derivative), 1.0);
	float coverage = clamp(pixelRange * (distance - 0.5) + 0.5, 0.0, 1.0);
	float base = max(0.0f, drop.r * 1.1 - 0.5) * u.appearance.y * coverage;
	return float4(drop.g > 0 ? float2(0, base) : float2(base, 0), 0, 0);
}

/// Zeroes channels below the bloom threshold in `u.effects.w`.
fragment float4 highPass(Raster in [[stage_in]], texture2d<float> source [[texture(0)]],
	constant TrinityUniforms &u [[buffer(0)]]) {
	float4 color = source.sample(linearSampler, in.uv);
	return select(color, float4(0), color < u.effects.w);
}

/// Three-tap Gaussian blur along `step`, in normalized texture coordinates.
fragment float4 blurPass(Raster in [[stage_in]], texture2d<float> source [[texture(0)]],
	constant float2 &step [[buffer(0)]]) {
	return source.sample(linearSampler, in.uv) * 0.442
		+ (source.sample(linearSampler, in.uv + step) + source.sample(linearSampler, in.uv - step)) * 0.279;
}

/// Converts HSL (each component from 0 to 1) to RGB.
float3 hsl(float h, float s, float l) {
	float3 k = fract(h + float3(0, 2.0/3.0, 1.0/3.0)) * 6;
	float3 rgb = clamp(abs(k - 3) - 1, 0.0, 1.0);
	return l + (rgb - 0.5) * (1 - abs(2 * l - 1)) * s;
}

/// Adds the weighted bloom levels to the glyph surface, subtracts dither noise, maps trail
/// brightness through `palette` and adds the tinted cursor glow.
fragment float4 composite(Raster in [[stage_in]], texture2d<float> primary [[texture(0)]],
	texture2d<float> b0 [[texture(1)]], texture2d<float> b1 [[texture(2)]],
	texture2d<float> b2 [[texture(3)]], texture2d<float> b3 [[texture(4)]],
	texture2d<float> b4 [[texture(5)]], texture2d<float> palette [[texture(6)]],
	constant TrinityUniforms &u [[buffer(0)]]) {
	float4 brightness = primary.sample(linearSampler, in.uv);
	if (u.effects.x > 0 && u.effects.y > 0) {
		brightness += u.effects.x * (
			b0.sample(linearSampler, in.uv) * 0.96549 + b1.sample(linearSampler, in.uv) * 0.92832
			+ b2.sample(linearSampler, in.uv) * 0.88790 + b3.sample(linearSampler, in.uv) * 0.84343
			+ b4.sample(linearSampler, in.uv) * 0.79370);
	}
	float noise = fract(randomFloat(in.position.xy) + u.timing.x);
	brightness -= noise * u.effects.z / 3;
	float3 color = palette.sample(linearSampler, float2(brightness.r, 0.5)).rgb;
	color += min(hsl(fract(u.appearance.w - 0.058), 1, 0.73) * u.appearance.z * brightness.g, float3(1));
	return float4(color, 1);
}
