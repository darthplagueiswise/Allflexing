# AllFLEXing build and runtime architecture

## Output contract

The project builds one `AllFLEXing.dylib` containing:

- the complete pinned FLEX source tree;
- the former libFLEX compatibility exports;
- the scene/window-aware reveal loader;
- the persistent hook registry and safe-mode recovery;
- the Objective-C and C Runtime Browsers;
- namespaced fishhook and typed C replacement slots;
- Logos-backed toggles and actions on hookable FLEX metadata rows;
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
5. Static AllFLEXing hooks and the Logos metadata-row adapter install once.
6. A one-shot `UIApplicationDidBecomeActive` observer is installed on main.
7. First activation re-resolves persisted late targets, removes the observer,
   and registers the Hook Center, reveal gesture, and visual layer.
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
- message and inline-function capabilities are measured independently;
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
A row switch resolves the class, selector, `Method`, and current type encoding
again in a transaction scoped to that entry.
The original IMP is kept exactly once. An ON gate returns the forced value
without executing the original first; an OFF gate calls the original. Total
replacement calls and calls actually overridden are counted separately. A safe
direct getter probe fails closed if a provider accepts installation but dispatch
does not cross the replacement.

The same resolver is used contextually by the normal FLEX object explorer.
Hookable BOOL methods and BOOL properties receive a native switch beside their
row plus a `Runtime Hook` menu containing Force TRUE, Force FALSE, Forward
Original, Apply, details, and Copy Hook ID. The contextual UI upserts into the
same registry as the Runtime Browser; it never creates a parallel hook store.

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
counter. Generic pointer-return stubs can force only `NULL`; fabricating a
non-null pointer is intentionally unsupported.

Auto selects fishhook when the selected image has a confirmed import slot. It
selects `MSHookFunction` only when no bind slot applies and the symbol resolves
to an address. Unknown signatures remain inspection-only.

## Registry state

Every runtime target uses one shared `FLEXHookEntry` with separate:

- pending intent;
- persisted desired intent;
- physical installation state;
- effective runtime gate;
- Armed state versus runtime-observed overridden calls;
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

The build is divided into four source manifests:

- Core: loader and persistence;
- HookProviders: Substrate-compatible bridge, namespaced fishhook, fishhook
  adapter, and typed C slots;
- HookRuntime: registry, scanner, ABI resolver, contextual actions, and the
  static Logos metadata-row integration;
- LiquidGlassUI: adaptive workspace, Hook Center, settings, entry details,
  Runtime Browsers, and explicit Liquid Glass components.

These are build-time groups only. The upstream fishhook source is removed from
the broad FLEX source glob and the vendored provider copy is added exactly once
by HookProviders. Every group,
including the `.xm` Logos source, links into the single `AllFLEXing.dylib`
target.

## Live toggles

Changing a runtime switch stages and immediately applies only its stable entry
ID. The global Apply action handles any remaining batch edits. Installation is
performed only when necessary. Once installed, all replacements remain in place
for that process:

- ON returns the configured forced value;
- OFF calls the saved original implementation immediately;
- disabling a whole engine gates all installed entries using that provider;
- physical unhooking is not attempted while other threads may execute a target.

`Apply & Restart` saves and then closes the app after explicit confirmation.
Stock iOS cannot relaunch a jailed app, so the user opens it again manually.

## Liquid Glass hierarchy

- The runtime workspace uses UIKit tabs in compact width and the adaptive
  tab/sidebar mode in regular width. It installs concrete navigation-controller
  children directly; it does not depend on lazy `UITab` providers.
- Standard UIKit 26 bars, search, menus, popovers, switches, and toolbar actions
  provide the primary control layer and automatic morphing from source items.
- The FLEX explorer toolbar owns one explicit `UIGlassEffect`; its description
  surface materializes and dematerializes by animating `effect`.
- The hierarchy selector moves one `UIGlassEffect` inside one
  `UIGlassContainerEffect`, producing a bounded selection morph without putting
  glass behind every label.
- Effect materialization animates `effect`, not just alpha.
- Merge/split morphing animates frames inside the shared container.
- Navigable FLEX menu rows and Hook Center cards receive bounded reusable
  `UIGlassEffect` surfaces; passive code/log rows remain content.
- The content canvas remains an opaque adaptive system surface behind those
  effects. A clear table must never expose the host application through the
  FLEX overlay window.
- Navigation, toolbar, and tab-bar chrome stays system-owned when running the
  SDK 26 build. In particular, no custom `UIBarAppearance.backgroundEffect`
  replaces the native floating tab bar and its interactive/minimize behavior.
- The global menu uses the iOS 26 integrated search placement in its toolbar,
  yielding the native floating search control and its compact/editing morph.
- Standard bars clear legacy appearances and custom effects use adaptive
  `UICornerConfiguration` on iOS 26.
- Custom cell accessories receive an explicit fitting frame before assignment,
  preventing switches from overlapping metadata text.
- Action sheets are anchored to their source cell/item for native transitions.
- Tool sheets keep the default modal dimming layer. FLEXWindow resolves nested
  presentations through visible navigation/tab children and owns both the
  deepest presented frame and its modal dimming container, so workspace tabs
  cannot pass touches to the host window.
- Reduce Motion suppresses optional toolbar and custom material morphing
  animations.
- No global `UIViewController` lifecycle hook or recursive view-tree scan is
  allowed. The pinned FLEX presentation patch is applied idempotently before
  compilation and fails closed if the submodule revision no longer matches.

## Local commands

```bash
git submodule update --init --recursive
./build.sh package
./build.sh verify
```

Static success is necessary but not sufficient. A Feather-signed iOS 26 device
test remains the final validation for provider identity, hook behavior,
persistence, restart flow, UI, morphing, and accessibility.
