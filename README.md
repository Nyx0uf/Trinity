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

In the preview app, use **Trinity Options…** (⌘,) for tuning and
**View → Enter Full Screen** (⌃⌘F) to evaluate fullscreen performance.
The diagnostics overlay appears by default; toggle it with ⌘D.
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

Release versioning and renderer details are documented in [Technical notes](TECHNICAL.md).

## Credits and license

Trinity's code was generated with Claude, a large language model (LLM).

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
