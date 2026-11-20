# Trinity technical notes

## Rendering and lifecycle

The two targets compile the same `Shared` sources and resources. A C header
defines the identical Swift/Metal uniform layout. `TrinityRenderer` owns GPU
resources; `TrinityMetalView` owns the layer, view-bound display link and sleep
observers; `TrinityScreenSaverView` adapts the macOS ScreenSaver interface.
The preview executable loads its own shader library, while the saver explicitly
loads the library and atlas from its own bundle rather than the host's bundle.

The classic 80×80 simulation grid is cropped along the viewport's shorter axis,
matching upstream's layout and keeping glyphs square. Density changes its grid
dimension. Glyph ages advance by elapsed animation seconds calibrated against
upstream's 60 Hz reference. Fall speed and cycling therefore do not accelerate
on high-refresh displays. Timing is reset after suspension to avoid catch-up.

Simulation textures remain on the GPU. Intermediate rain/bloom surfaces use
two-channel 16-bit floating point (trail and cursor brightness); glyph state uses
32-bit floats. The bloom pyramid has five
levels with upstream's threshold, blur and combination weights. Its result is
combined directly in the palette pass to avoid an extra full-resolution surface.
The atlas is loaded as linear data with the original bottom-left coordinate origin.

The renderer permits at most three frames in flight, skips submissions when busy,
and reallocates surfaces only when required. A display link weakly references its
view. Stop, removal from a window, teardown and display sleep invalidate it;
hidden views submit no GPU work. Standalone app windows also pause when occluded.
The screensaver host bypasses window occlusion checks because its fullscreen
`NSServiceViewControllerWindow` reports no `.visible` flag while remotely presented;
using that flag as a rendering gate caused a black fullscreen saver. The host's `animateOneFrame` timer
does not drive rendering. Trinity never terminates the host or uses a frontmost-app
allowlist. Recent macOS hosts have reported lifecycle inconsistencies; installed
host behavior still needs manual acceptance checks.

Missing Metal or bundled resources leave the screensaver black and produce a log
message. The preview app also presents the error. Debug builds support Metal
validation and GPU capture in Xcode.

## Release versions

`Trinity.saver` and `TrinityPreview.app` share one `YEAR.NUMBER_OF_RELEASE`
version and one build number in the Xcode project. From the repository root,
run `make bump-version` once before building both products for a new release.
It uses the local calendar year and advances `2026.1` to `2026.2` within that
year, or starts at `2027.1` for the first release in 2027. The shared build
number increases by one with each bump, including across years. Regular builds
and installs use the recorded version.
