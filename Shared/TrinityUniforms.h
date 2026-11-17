#ifndef TrinityUniforms_h
#define TrinityUniforms_h
#include <simd/simd.h>

// One definition shared by Swift and Metal. Every field is 16-byte aligned.
typedef struct {
	vector_float4 timing;     // animation time, simulation delta, first frame, seed
	vector_float4 grid;       // dimension, fall speed, animation speed, cycle speed
	vector_float4 appearance; // drop length, brightness multiplier, cursor intensity, hue
	vector_float4 effects;    // bloom strength, bloom size, dither, high-pass threshold
	vector_float4 viewport;   // pixel width, pixel height, unused, unused
} TrinityUniforms;
#endif
