# AllFLEXing

AllFLEXing is a standalone FLEX debugger dylib for certificate-sideloaded iOS
apps. FLEX itself, the loader, persistent runtime toggles, the hook backends, and
the UIKit 26 Liquid Glass integration are linked into one output:

```text
.theos/obj/AllFLEXing.dylib
```

The dylib has the sideload-safe install name `@rpath/AllFLEXing.dylib`. It does
not hard-link Cydia Substrate, ElleKit, libhooker, or a second `libFLEX.dylib`.

## What changed from upstream FLEXing

Upstream used a loader tweak plus a separately installed `libFLEX.dylib`.
AllFLEXing compiles the loader directly beside FLEX's sources and uses a normal
Mach-O constructor. It therefore works when an injector adds a single
`LC_LOAD_DYLIB` command to a resigned IPA.

The runtime layer provides:

- the embedded, namespaced `flex_fishhook` already shipped by FLEX;
- optional `MSHookMessageEx` / `MSHookFunction` use when another injected
  framework exposes them;
- an Objective-C runtime fallback (`class_addMethod` / `method_setImplementation`)
  when those symbols are absent;
- hooks installed once at image load and gated by live BOOL flags;
- namespaced `NSUserDefaults` persistence inside the host app's sandbox;
- a FLEX global entry named **Hook Toggles**;
- a three-finger long press reveal gesture attached to current and future app
  windows, including scene-based apps.

## Liquid Glass

The project compiles with the iPhoneOS 26.2 SDK. On iOS 26 and later it creates
real `UIGlassEffect` and `UIGlassContainerEffect` objects and uses the native
glass button configurations. On iOS 15-25 it falls back to system material.

Glass is intentionally limited to FLEX's navigation and control layer. Tables
remain content, and the code avoids glass-on-glass composition. This follows
Apple's Liquid Glass hierarchy instead of applying blur indiscriminately to
every cell in the overlay.

## Build

Requirements:

- Theos;
- `iPhoneOS26.2.sdk` in `$THEOS/sdks`;
- GNU make, `dpkg`, and `ldid`.

```bash
git submodule update --init --recursive
make clean
make package FINALPACKAGE=1
```

The default `arm64` slice is the most compatible choice for resigned apps and
runs on both arm64 and arm64e devices. To also produce the reference binary's
fat layout:

```bash
make clean
make package FINALPACKAGE=1 ARCHS="arm64 arm64e"
```

Verify a built dylib on macOS:

```bash
scripts/verify-dylib.sh .theos/obj/AllFLEXing.dylib
```

GitHub Actions uses the same SDK acquisition and validation pattern as
`darthplagueiswise/Ryukgram-Fork` branch `experimental3`.

## Injection

Copy only `AllFLEXing.dylib` into `Payload/<App>.app/Frameworks/`, add
`@rpath/AllFLEXing.dylib` as an `LC_LOAD_DYLIB`, then re-sign the complete app.
Sideloadly, Feather, cyan, or any equivalent injector can perform those steps.

No tweak filter or jailbreak bootstrap is used at runtime. The empty package
filter exists only so Theos can also emit a `.deb` that deb-aware IPA injectors
can unpack.

## Adding hooks

Register a persistent flag and install the hook once:

```objc
FLEXHookPersistence *flags = FLEXHookPersistence.sharedManager;
[flags registerInstallOnce:@"hook.my_feature"
                     title:@"My feature"
                    detail:@"Example live-gated Objective-C hook"
              defaultValue:NO
                     block:^{
    FLEXHookMessage(SomeClass.class, @selector(someMethod),
        (IMP)replacement_someMethod, (IMP *)&original_someMethod);
}];
```

The replacement must check `FLEXFlag(@"hook.my_feature")` on every call. The
switch can then change behavior immediately without re-hooking or relaunching.
Use `FLEXSymbolRebind` for imported C symbols.

See [ALLFLEXING_BUILD.md](ALLFLEXING_BUILD.md) for architecture and timing
details and [docs/REFERENCE_BINARY.md](docs/REFERENCE_BINARY.md) for the audit of
the uploaded dylib.
