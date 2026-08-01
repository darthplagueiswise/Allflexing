# Uploaded AllFLEXing.dylib audit

This audit treats the uploaded Mach-O as the source of truth. No `.deb` was
attached, so package layout, control metadata, and injector-specific scripts
could not be verified.

## Identity

| Property | Observed value |
|---|---|
| SHA-256 | `9aafc761197495ec6b7b95930825623ad5dc2c511be13e5e44bf9666406370d3` |
| Size | 3,038,912 bytes |
| Slices | arm64 and arm64e (subtype 2, pointer authentication) |
| File type | dynamically linked shared library |
| `LC_ID_DYLIB` | `@rpath/AllFLEXing.dylib` |
| Minimum OS | iOS 15.0 |
| Build SDK | iOS 16.5 |
| Linker version | 609.0.0 |
| Encryption | disabled (`cryptid = 0`) |

The uploaded binary is therefore **not** an SDK 26.2 build. It uses runtime
class/selector lookup to reach Liquid Glass-shaped APIs while retaining an SDK
16.5 load command. This repository's new build pipeline changes the actual
`LC_BUILD_VERSION` SDK to 26.2.

## Integration evidence

The arm64 slice exports 499 symbols, including 174 Objective-C classes. Five
classes are specific to the unified layer:

- `AllFLEXingReveal`
- `FLEXHookPersistence`
- `FLEXHookToggles`
- `FLEXLiquidGlass`
- `FLEXSymbolRebind`

It also exports `FLEXFlag`, `FLXGetManager`, `FLXRevealSEL`, and
`FLXWindowClass`. The other classes match the pinned FLEX tree, confirming that
FLEX is compiled into the same image rather than loaded from a second dylib.

The custom Objective-C metadata exposes the following relevant methods:

- persistence: `registerFlag:title:defaultValue:`, `boolForFlag:`,
  `setBool:forFlag:`, `registerInstallOnce:title:defaultValue:block:`, and
  `replayInstallOnce`;
- UI: `glassEffectInteractive:tint:`, `containerEffectWithSpacing:`,
  `styleNavigationController:`, `styleTableView:`, `styleCell:`,
  `styleSearchBar:`, `styleButton:`, and `applyToViewController:`;
- C rebinding: `rebindSymbol:replacement:original:`;
- reveal: `handle:` and a singleton `shared` method.

Imports of `_dyld_register_func_for_add_image` and related dyld functions, plus
the embedded `flex_fishhook` source in the pinned FLEX commit, confirm that
fishhook is compiled into the image.

## Dependencies and sideload caveats

The uploaded reference binary does **not** contain an `LC_LOAD_DYLIB` for Cydia
Substrate, ElleKit, or libhooker. The strings `/usr/lib/libsubstrate.dylib` and
`MSHookFunction` come from FLEX's system-log controller, which probes them
dynamically; they are not hard dependencies of that reference image.

The rebuilt product intentionally differs here: it links the
Substrate-compatible `CydiaSubstrate.framework` contract that Feather rewrites
and supplies with ElleKit inside a certificate-signed app. That dependency is
not a jailbreak bootstrap and must resolve from the app's `Frameworks` rpath.

It does retain four rootless rpaths:

```text
/var/jb/Library/Frameworks
/var/jb/usr/lib
@loader_path/.jbroot/Library/Frameworks
@loader_path/.jbroot/usr/lib
```

Those paths are unnecessary for a standalone resigned app. The rebuilt target
omits the rootless package scheme and the CI verifier rejects these rpaths.

Linked system libraries/frameworks are Objective-C, Foundation, CoreFoundation,
CoreGraphics, UIKit, ImageIO, QuartzCore, SceneKit, Security, WebKit,
AVFoundation, UserNotifications, sqlite3, zlib, libc++, and libSystem.

## Code signature

Both slices contain a CodeDirectory with no entitlements. The arm64 identifier
is `AllFLEXing.dylib.0b01dd7e.unsigned`. The containing app still needs to be
re-signed after the dylib and its load command are inserted.
