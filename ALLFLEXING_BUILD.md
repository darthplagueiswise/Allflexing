# AllFLEXing build and runtime architecture

## Output contract

The project builds one `AllFLEXing.dylib` containing:

- the complete pinned FLEX source tree;
- the former libFLEX compatibility exports;
- the scene/window-aware reveal loader;
- the persistent hook registry and safe-mode recovery;
- the Objective-C and C Runtime Browsers;
- namespaced fishhook and typed C replacement slots;
- the Hook Center and UIKit 26 Liquid Glass integration.

| Property | Required value |
|---|---|
| File type | `MH_DYLIB` |
| Install name | `@rpath/AllFLEXing.dylib` |
| SDK | iPhoneOS 26.2 |
| Minimum OS | iOS 16.3 |
| Architecture | arm64 |
| Hook framework | Feather-rewritable `CydiaSubstrate.framework` |
| Runtime provider | ElleKit inside the signed app |
| Jailbreak/rootless rpaths | none |

The CydiaSubstrate-compatible load dependency is intentional. Feather supplies
that framework using ElleKit and relocates it into the signed app. This does not
split FLEX/libFLEX back into multiple dylibs.

## Build flow

1. The workflow checks out the source and submodules.
2. It installs GNU make, `dpkg`, and `ldid`.
3. It initializes Theos.
4. It restores or downloads exactly `iPhoneOS26.2.sdk`.
5. It validates the real UIKit 26 glass headers, target strings, registry, and
   Substrate-compatible source contract.
6. It invokes `./build.sh package`, which enforces a clean
   `FINALPACKAGE=1` build and stages deterministic artifacts.
7. It audits the dylib's SDK, minimum OS, install name, provider imports,
   classrefs, classes, exports, and absence of jailbreak rpaths.
8. It uploads the dylib and deb artifacts.

## Load and injection timing

1. dyld maps the host app, `CydiaSubstrate.framework`, and
   `@rpath/AllFLEXing.dylib`.
2. The single AllFLEXing constructor registers feature/engine defaults.
3. The registry loads versioned persisted locators and detects an interrupted
   prior apply.
4. It re-resolves and reinstalls only exact persisted targets that remain safe.
5. Static AllFLEXing hooks install once.
6. UI initialization is dispatched to the main queue.
7. Once scenes/windows exist, FLEX registers the Hook Center and reveal gesture.
8. Runtime scans occur only when requested and run off the main thread.
9. dyld image additions are debounced; the callback schedules work and returns
   without scanning or touching UIKit.

The constructor does not enumerate the runtime broadly or create UIKit views.

## Provider detection

The build takes strong references to `MSHookMessageEx` and `MSHookFunction`, so
the expected framework is an actual Mach-O dependency rather than an optimistic
`dlsym` probe. At runtime:

- `dladdr` identifies the image implementing the MSHook API;
- the ElleKit-specific `EKEnableThreadSafety` export must resolve from that same
  Mach-O base before the UI labels the provider as ElleKit;
- otherwise the UI reports a generic Substrate-compatible provider;
- unavailable providers disable dependent targets and return a concrete error.

## Objective-C ABI path

The scanner enumerates direct instance and class methods. A toggle is created
only when:

- the return type is a BOOL-compatible encoding;
- there are zero explicit arguments, or one supported object/integer argument;
- the selector is not an initializer, setter, deallocator, or unsafe runtime
  primitive;
- the provider is available and its engine is enabled.

Each signature receives a separate `imp_implementationWithBlock` replacement.
Apply resolves the class, selector, `Method`, and current type encoding again.
The original IMP is kept exactly once, hit counts are recorded, and an OFF gate
returns the native result.

## C ABI path

The C Runtime Browser parses `LC_SYMTAB`, `LC_DYSYMTAB`, and lazy/non-lazy
symbol pointer sections for each selected image. It does not infer ABI from a
name.

Supported initial typed slot pools are:

- `bool(void)`;
- `bool(void *)`;
- `int64_t(void)`;
- `void *(void)`.

Each profile has eight static arm64-compatible replacement slots. Every slot
holds an original pointer/trampoline, atomic enable/force state, and atomic hit
counter.

Auto selects fishhook when the selected image has a confirmed import slot. It
selects `MSHookFunction` only when no bind slot applies and the symbol resolves
to an address. Unknown signatures remain inspection-only.

## Registry state

Every runtime target uses one shared `FLEXHookEntry` with separate:

- pending intent;
- persisted desired intent;
- physical installation state;
- effective runtime gate;
- availability/hookability;
- ABI and backend;
- locator and image identity;
- original pointer (memory only);
- hit count and last error.

Apply is serialized. Before each installation, the registry writes an in-flight
record and synchronizes it. Successful or failed completion clears that marker.
If the process ends during the narrow install window, the next launch enters
safe mode and disables only the suspect target.

Persisted locators include class/selector/type encoding for Objective-C or
symbol/image/UUID/bind count for C. Absolute runtime pointers are never saved.
If a C image UUID changes, the saved ABI and backend are invalidated and the
entry becomes inspection-only until explicitly classified again.

## Source module manifests

The build is divided into three source manifests:

- Core: loader and persistence;
- HookRuntime: provider bridge, registry, scanner, resolver, fishhook adapter,
  and typed C slots;
- LiquidGlassUI: Hook Center, entry details, Runtime Browsers, autostyle, and
  Liquid Glass components.

These are build-time groups only. The namespaced fishhook source is compiled
exactly once through the pinned FLEX source tree, and every group links into the
single `AllFLEXing.dylib` target.

## Live toggles

Changing a switch stages a value. Apply revalidates and installs only when
necessary. Once installed, all replacements remain in place for that process:

- ON returns the configured forced value;
- OFF calls the saved original implementation immediately;
- disabling a whole engine gates all installed entries using that provider;
- physical unhooking is not attempted while other threads may execute a target.

`Apply & Restart` saves and then closes the app after explicit confirmation.
Stock iOS cannot relaunch a jailed app, so the user opens it again manually.

## Liquid Glass hierarchy

- Standard UIKit 26 bars, search, menus, popovers, switches, and toolbar actions
  provide the primary control layer.
- Custom FLEX toolbar elements use `UIGlassEffect` inside one
  `UIGlassContainerEffect`.
- Effect materialization animates `effect`, not just alpha.
- Merge/split morphing animates frames inside the shared container.
- Runtime tables/cells remain content and do not receive a glass panel each.
- Action sheets are anchored to their source cell/item for native transitions.
- Reduce Motion suppresses optional toolbar and custom material morphing
  animations.

## Local commands

```bash
git submodule update --init --recursive
./build.sh package
./build.sh verify
```

Static success is necessary but not sufficient. A Feather-signed iOS 26 device
test remains the final validation for provider identity, hook behavior,
persistence, restart flow, UI, morphing, and accessibility.
