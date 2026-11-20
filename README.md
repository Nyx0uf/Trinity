# Trinity

A native Metal screensaver for **macOS 27.0 or later, Apple Silicon**. A fresh
translation of [Rezmason/matrix](https://github.com/Rezmason/matrix)'s classic
2D effect, with stationary MSDF glyphs, falling illumination, bright cursors,
five-level bloom, palette mapping, and dither.

Trinity renders at native pixel resolution by default and requests each display's
maximum refresh rate. There is no fixed 60 fps ceiling in Match Display mode.
The system and GPU ultimately determine the delivered presentation rate.
Optional 60 and 30 fps limits and a 25–100% resolution slider are available.

## Build and run

Open `Trinity.xcodeproj` with Xcode 27.2 or later.

- Choose **TrinityPreview** and Run to inspect the renderer and change options.
- Choose **Trinity** and Build to produce `Trinity.saver`. A screensaver bundle
  runs inside macOS's host, so use the preview scheme for normal Xcode debugging.

Both targets use ad-hoc signing for local use and need no development team.
No third-party packages or automated test targets are included.
Both targets run SwiftFormat and then strict SwiftLint before compiling; install
them with `brew install swiftformat swiftlint`. Without them the build only warns.
`make check` runs the same checks without building, and `make format` applies
formatting. User-facing strings are in `Resources/Localizable.xcstrings` (English).

```sh
xcodebuild -project Trinity.xcodeproj -scheme Trinity \
  -configuration Release -derivedDataPath .build build
xcodebuild -project Trinity.xcodeproj -scheme TrinityPreview \
  -configuration Release -derivedDataPath .build build
open .build/Build/Products/Release/TrinityPreview.app
```

In the preview app, use **Trinity Options…** (⌘,) for tuning, **View → Show
Diagnostics** (⌘D) for requested/measured fps, render size and GPU time, and
**View → Enter Full Screen** (⌃⌘F) to evaluate fullscreen performance.
To also log diagnostics every second, launch its executable with `--diagnostics`.
Both products log to the unified log under the subsystem `fr.whine.Trinity`:

```sh
log stream --level info --predicate 'subsystem == "fr.whine.Trinity"'
```

## Install the screensaver

Run this command from the repository root.

```sh
make install
```

This builds the Release screensaver, installs it in `~/Library/Screen Savers`,
and removes the temporary build files. Set `SCREENSAVER_INSTALL_DIR` to an
absolute path to use a different destination.

For a manual installation, double-click the built `Trinity.saver` and follow
macOS's installation dialog, or copy the bundle into your personal Screen Savers
directory.

```sh
mkdir -p "$HOME/Library/Screen Savers"
ditto .build/Build/Products/Release/Trinity.saver \
  "$HOME/Library/Screen Savers/Trinity.saver"
```

Select **Trinity** in System Settings's Screen Saver controls. Open **Options**
to tune the effect. Each Options window has its own live preview; Apply saves
the draft, Cancel discards it, and Restore Defaults resets the draft until applied.
The standalone app and screensaver share `ScreenSaverDefaults` under
`fr.whine.Trinity`. New screensaver instances load the latest saved settings.

When replacing an installed build, close the preview and System Settings first.
The system may keep older screensaver bundles loaded until its host restarts;
log out and back in if it continues displaying an older build.

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
host behavior still needs the acceptance checks below.

Missing Metal or bundled resources leave the screensaver black and produce a log
message. The preview app also presents the error. Debug builds support Metal
validation and GPU capture in Xcode.

## Verification

Verified on macOS 27.2.1, Xcode 27.2, Apple M4, one 3840×2160 60 Hz display:

- Both schemes build in Debug and Release; the saver is an arm64 Mach-O bundle.
- Ad-hoc signatures, principal class, deployment target and bundled library/atlas
  are verified.
- Classic appearance compared visually with the upstream WebGL demo: glyph
  orientation, proportions, rain, highlights, palette and bloom.
- Preview measured 60 fps in Match Display and 60 fps modes, and 30 fps in
  30 fps mode. At native 4K fullscreen, sampled Debug GPU durations were about
  3–7 ms with no skipped submissions during the observed interval.
- Fullscreen macOS screensaver host diagnosed and fixed: the remote host reports
  an occlusion state of 8192 (without `.visible`). Removing that rendering gate
  specifically for screensaver views restored 60 fps at 3840×2160, confirmed from
  120 submitted frames and GPU timestamps in a temporary diagnostic build.
- Live hue changes, Cancel, Apply, Restore Defaults, persisted settings and
  repeated Options opening checked interactively; fullscreen transitions checked.

Still requiring hardware/installed-host acceptance: 120 Hz and higher displays,
physical Retina scaling, display migration, multiple displays, actual display
sleep/wake, repeated fullscreen screensaver dismissal and long-running legacy-host
instance cleanup. The System Settings thumbnail and actual fullscreen host both
load Trinity. The fullscreen host was instrumented during the black-screen fix;
that temporary instrumentation is absent from the delivered builds.

After manual installation, run the saver and dismiss it several times, checking
that dismissed instances stop submitting GPU work in Instruments. Exercise
System Settings previews and repeated Options opening, sleep/wake, mixed-refresh
displays and portrait windows. Compare motion speed between 30, 60 and Match
Display policies. Do not infer installed-host lifecycle correctness from the app.

## Credits and license

Trinity's original code is released under the [MIT License](LICENSE), the same
permissive license used by [Rezmason/matrix][upstream]. The Metal renderer
translates the classic effect from revision `5ba90490453ceceb6812d6b1bc658a99a92411d0`,
including `js/config.js`, `js/regl/rainPass.js`, `js/regl/palettePass.js`,
`js/regl/bloomPass.js` and the relevant `shaders/glsl` sources. The port preserves
the [upstream MIT notice](Resources/Rezmason-LICENSE.txt).

Trinity bundles the upstream `assets/matrixcode_msdf.png` unchanged. Rezmason
traces its classic glyph artwork to an official Matrix product's promotional
site. Permission from the original artwork's rights holders has not been
verified. See the [bundled third-party notice](Resources/Third-Party-Notices.txt)
and [upstream provenance][glyph-provenance].

`Trinity.saver` and `TrinityPreview.app` both include the Trinity MIT license,
the upstream MIT notice and the third-party notice.

[upstream]: https://github.com/Rezmason/matrix/tree/5ba90490453ceceb6812d6b1bc658a99a92411d0
[glyph-provenance]: https://github.com/Rezmason/matrix/blob/5ba90490453ceceb6812d6b1bc658a99a92411d0/README.md#goals
