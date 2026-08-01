# AllFLEXing build and runtime architecture

## Output contract

The project produces one injectable image named `AllFLEXing.dylib` containing:

- the complete pinned FLEX source tree;
- the reveal loader and scene/window lifecycle handling;
- UIKit 26 Liquid Glass integration and pre-iOS 26 material fallback;
- persistent live BOOL flags and the in-FLEX toggle controller;
- FLEX's namespaced `flex_fishhook` implementation;
- a sideload-safe Objective-C message-hook abstraction.

The Mach-O contract is:

| Property | Required value |
|---|---|
| File type | `MH_DYLIB` |
| Install name | `@rpath/AllFLEXing.dylib` |
| SDK | iPhoneOS 26.2 |
| Minimum OS | iOS 15.0 |
| Default architecture | arm64 |
| External hook dependency | none |
| Rootless `/var/jb` rpaths | none |

`arm64` is the certificate-sideload default because it also runs on arm64e
hardware. Pass `ARCHS="arm64 arm64e"` when a fat reference artifact is useful.

## Hook timing

1. dyld maps `AllFLEXing.dylib` because the host executable contains an
   `LC_LOAD_DYLIB` for `@rpath/AllFLEXing.dylib`.
2. `AllFLEXingBootstrap` runs as a Mach-O constructor.
3. Flags and install-once blocks are registered synchronously.
4. Objective-C hooks are installed before the first main-runloop turn.
5. Hook replacements consult `FLEXFlag(...)` on each call. Changing a switch
   changes behavior without installing another IMP chain.
6. UI work is dispatched to the main queue. The global entry and reveal gesture
   are attached once UIKit is ready.
7. Window and scene notifications attach the reveal recognizer to windows that
   appear after launch.

This split avoids both common races: installing behavior hooks too late and
touching UIKit view state from an early constructor.

## Hook backends

### Objective-C messages

`FLEXHookMessage` checks whether `MSHookMessageEx` is already exported in the
process. If so, it uses that implementation. It never hard-links or forcibly
loads Substrate/ElleKit. If the symbol is absent, it creates a local override
with `class_addMethod` for inherited methods or replaces the class's own IMP
with `method_setImplementation`.

The fallback retains the original IMP and works in an ordinarily resigned app;
it does not require a jailbreak bootstrap or special entitlement.

### C symbols

`FLEXSymbolRebind` calls the `flex_rebind_symbols` implementation already present
under `FLEX/Classes/Utility/Runtime`. There is deliberately no second fishhook
copy, which avoids duplicate symbols and keeps FLEX's own system-log rebinding
on the same registry.

`FLEXHookFunctionIfAvailable` exposes optional `MSHookFunction` use for callers
that intentionally inject a provider. It returns `NO` in the standalone case;
fishhook is the portable default.

## Persistence

Flags use `NSUserDefaults.standardUserDefaults` with keys prefixed by
`com.allflexing.flags.`. A sideloaded app already has a unique sandbox and
preferences domain, so a custom suite or app-group entitlement adds failure
modes without improving isolation.

Registered defaults live in the in-memory cache until a user changes them.
Writes update the cache and defaults together, then post
`FLEXHookFlagsDidChangeNotification` on the main thread.

## Liquid Glass hierarchy

On iOS 26+, `FLEXLiquidGlass` uses public SDK 26 APIs:

- UIKit's default SDK 26 appearances for navigation bars and toolbars;
- `UIGlassEffect` for search and custom floating panels;
- `UIGlassContainerEffect` as the supported grouping primitive for future
  multi-element control clusters;
- `UIButtonConfiguration.glassButtonConfiguration` for standalone controls.

Tables and cells remain in the content layer. A FLEX toolbar receives one glass
panel, and its child controls are not given another glass surface. This prevents
glass-on-glass composition and preserves hierarchy and legibility.

On iOS 15-25, the same APIs return a system thin-material fallback.

## Build and validation

```bash
git submodule update --init --recursive
make clean
make package FINALPACKAGE=1
scripts/verify-dylib.sh libflex/.theos/obj/AllFLEXing.dylib
```

The GitHub workflow downloads `iPhoneOS26.2.sdk` with the same sparse-checkout
pattern used by `Ryukgram-Fork/experimental3`, validates the public glass headers,
builds the package, and fails if the dylib gains a hook-framework dependency or
a rootless rpath.
