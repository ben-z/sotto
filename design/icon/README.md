# Sotto icon artwork

The approved identity is the right-facing paper songbird in terracotta **#E9957D** on graphite **#242426**. Dark appearance retains terracotta on **#171719**. The status-bar artwork is monochrome. The bird, open beak, and quotation-shaped wing connect quiet voice with written notes.

## Versioned files

| Location | Contents |
|---|---|
| `source/geometry.json` | Primary and small-size Bézier paths and palette; source of truth |
| `source/composer.json` | Native appearance settings; source of truth |
| `source/build.swift` | Offline vector/raster export implementation |
| `masters/` | Editable SVG logos and full-bleed app compositions |
| `composer-layers/` | Aligned SVG layers, including the recommended combined silhouette |
| `Sotto.icon/` | Native Icon Composer document for current Apple platforms |
| `status/svg/` | Editable status glyphs with idle, recording, busy, and error states |
| `integration/SottoStatusArtwork.swift` | AppKit loading helper, not yet wired into the executable |
| Root `Resources/Sotto.icns` | Classic macOS app icon |
| Root `Resources/SottoStatus/` | Eight shipping status PNGs, 1× and 2× |
| Root `iOS/Assets.xcassets/` | Default, dark, and tinted 1024px app-icon sources |

Generated files required by the app are committed alongside the editable sources. Update both in the same commit. ZIP releases, compiler products, and exploratory renders are not tracked. No Git LFS or third-party rendering dependency is required.

## Regenerate or verify

From the repository root:

```sh
python3 design/icon/source/rebuild.py
python3 design/icon/source/rebuild.py --check
```

Requires macOS, Swift with AppKit, and `iconutil`. Missing prerequisites fail the command. Temporary exports are generated outside the checkout and removed when the command ends. `--check` compares committed assets byte-for-byte and does not write the checkout. Pixel validation and Swift helper type-checking run before exports are copied or compared. These checks do not require Icon Composer or an iOS simulator.

Edit `source/geometry.json` for shapes/colors and `source/composer.json` for native appearances. If you edit `Sotto.icon` in Icon Composer, copy its updated `icon.json` into `source/composer.json` before regenerating. Regeneration intentionally restores the source-defined native document. Include a before/after visual preview in the PR when changing artwork.

## Export and design details

- The symbol uses two closed paths without embedded raster images, fonts, or external references.
- The small-size variant strengthens the wing, widens the negative-space channel, and simplifies delicate beak details.
- Classic macOS `.icns` includes all ten standard slots from 16px through 1024px, with an inset rounded tile and transparent exterior.
- iOS inputs are full-bleed 1024×1024 sRGB PNGs without alpha channels. The tinted source is grayscale. The system applies masking.
- The native `.icon` uses an unmasked background and combined foreground, with foreground translucency and extra shadows disabled. Native tint and clear appearances remain system-controlled.
- Every status state uses a 26×18 pt canvas with the bird at the same position. A dot denotes recording, ellipsis denotes pending work, and an exclamation mark denotes error. Preparing and transcribing share the pending image but have distinct accessible descriptions.
- Status PNGs are strictly black and transparent. The helper sets `isTemplate = true`, caches 1×/2× representations, and updates accessible descriptions without a timer. It throws if required assets are missing.

## Integration status

This commit versions artwork only. The current `scripts/build.sh`, macOS status item, and iOS project have not been changed to consume these files.

For the lightweight macOS route, copy `Resources/Sotto.icns` and `Resources/SottoStatus` into the built bundle's `Contents/Resources` before signing, add `CFBundleIconFile = Sotto.icns` to the generated plist, and use the included status helper in the state-change handler. Keep the existing recording indicator and textual menu status; the tiny status dot should not be the only recording feedback.

For iOS, add `iOS/Assets.xcassets` to the target's resources and set `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Alternatively, add `Sotto.icon` and set the icon source to `Sotto`. Choose one icon-source route per target.

Classic and native macOS assets compiled successfully with Xcode 26.2 during preparation. Native default/dark/tinted/clear renditions were visually reviewed. The status loader passed AppKit loading and missing-resource checks. The full kit's pixel checks passed.

**iOS compilation is not verified:** both native and catalog checks failed on the preparation machine because Xcode had no available iOS simulator runtime, including when targeting `iphoneos`. The iOS files pass image-format checks. A compatible runtime and final target build are still required. Actual menu-bar interaction and assistive-technology behavior also need a check after integration.

References: [Apple app-icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons), [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer), [AppKit template images](https://developer.apple.com/documentation/appkit/nsimage/istemplate).
