# AllFLEXing

AllFLEXing is one injectable iOS dylib containing the complete FLEX/libFLEX
debugger, a persistent runtime hook system, and a UIKit 26 Liquid Glass Hook
Center.

The production target is deliberately narrow:

- jailed certificate sideloading;
- Feather for tweak injection, signing, and installation;
- ElleKit as the Substrate-compatible hook provider inside the signed app;
- iPhoneOS SDK 26.2, deployment target 16.3, arm64;
- no jailbreak bootstrap, rootless paths, TrollStore, daemon, or extra
  entitlement.

The build emits:

```text
.theos/obj/AllFLEXing.dylib
```

FLEX, the former libFLEX compatibility layer, fishhook, the loader, registry,
ABI resolver, persistence, browsers, and UI are compiled into that one image.
ElleKit remains a framework supplied by Feather; it is not a second FLEX
product.

## Hook runtime

| Target | Backend | Requirement |
|---|---|---|
| Objective-C method | `MSHookMessageEx` through ElleKit | Valid `Method`, type encoding, and supported BOOL ABI |
| Imported C symbol | embedded namespaced fishhook | Confirmed lazy/non-lazy Mach-O bind slot and explicit C ABI |
| C function by address | `MSHookFunction` through ElleKit | Resolved symbol, explicit C ABI, and valid original trampoline |
| Unknown C/Swift function | inspection only | No toggle until its ABI is proven |

The runtime uses one registry for discovery, pending state, installed state,
armed/observed state, persistence, hit counters, errors, and launch reapply. Apply
re-resolves every target and fails closed when a class, selector, image, symbol,
ABI, provider, or bind slot no longer matches.

A row switch performs a targeted transaction for that entry only, so its gate
changes in real time without committing unrelated batch edits. The global
**Apply** button remains available for pending configuration/batch changes.

Hooks install once. Turning a toggle off changes an atomic gate in the
replacement, which immediately forwards to the saved original implementation.
With the gate on, the replacement returns the configured override without
executing the original first. `Armed` means installation succeeded;
`Observed` requires a real overridden call, so the UI no longer treats provider
acceptance as proof of behavior.
The product does not try to tear down an inline patch while other threads may be
executing it.

Persistence stores versioned locators and intent in the host app's normal
`NSUserDefaults` sandbox. It never stores an IMP, trampoline, or ASLR-dependent
absolute address. An interrupted apply is detected on the next launch and the
suspect target is disabled in safe mode.

dyld image additions are debounced and moved off the loader callback before any
Objective-C work occurs. Persisted targets that were unavailable at launch are
retried idempotently; installed targets are never patched a second time. A C
entry whose saved Mach-O UUID changed is reset to inspection-only until its ABI
is explicitly revalidated.

## Runtime workspace

Open FLEX and select **AllFLEXing Runtime Workspace**. On iPhone it uses a
floating tab bar; on iPad or another regular-width presentation it adapts to a
sidebar. The four concrete navigation controllers are installed directly in
the tab controller, avoiding lazy tab providers that could render an item
without changing the visible child. The workspace provides:

- verified provider and engine status;
- global toggles for Objective-C/ElleKit, fishhook, and inline ElleKit;
- staged pending changes with **Apply**, **Discard**, and
  **Apply & Restart** actions;
- installed hooks with separate Armed, Observed, forwarded, and error states;
- an Objective-C Runtime Browser for supported BOOL method ABIs;
- a C Runtime Browser that reads actual Mach-O import sections;
- a dedicated settings and recovery surface;
- manual C symbol entry for known inline targets;
- per-target ABI and backend selection;
- stale-target, apply-error, and safe-mode diagnostics.

Every entry proven hookable has a switch beside it. An unknown C ABI stays
visible but disabled until the user chooses a signature they have independently
verified.

The regular FLEX object explorer is connected to that same runtime registry.
Supported BOOL methods and BOOL properties receive a native switch directly in
their metadata row. Their **Runtime Hook** menu provides **Force TRUE**,
**Force FALSE**, **Forward Original**, **Reapply This Hook**, **Hook
Details**, and **Copy Hook ID** without replacing FLEX's existing navigation or
copy actions. This integration is generated through Logos for the known
`FLEXMetadataSection` surface; the selected target is still resolved and
installed dynamically only after exact ABI validation.

## Liquid Glass

The dylib is compiled with real UIKit 26.2 headers. Standard navigation bars,
tab/sidebar navigation, searches, menus, popovers, buttons, and switches keep
their native iOS 26 behavior. Menus are attached to their source bar items so
UIKit provides the transition and morphing behavior. The global FLEX search
uses the public integrated-toolbar placement on iOS 26, producing the floating
bottom search control and native compact/editing morph.

The FLEX hierarchy selector moves a single `UIGlassEffect` selection inside a
shared `UIGlassContainerEffect`. The explorer toolbar and its materializing
description panel are explicit components; no global view-controller hook or
recursive view-tree scan injects styling after layout.

UIKit 26 bars have legacy background appearances cleared so the system material
can activate. Custom glass geometry uses adaptive `UICornerConfiguration`;
fixed layer radii are used only by the pre-iOS-26 fallback.

Navigable menu rows and Hook Center cards are explicit reusable
`UIGlassEffect` surfaces with adaptive corners, matching the control-card
hierarchy instead of opaque grouped cells. Passive code/log rows remain content,
avoiding indiscriminate glass-on-glass composition.
Effect materialization animates the `effect` property, while merge/split
morphing animates frames inside a shared container. Standard UIKit behavior
inherits Reduce Motion, Reduce Transparency, Increased Contrast, VoiceOver, and
Dynamic Type adaptations.

## Build

Requirements:

- Theos;
- `iPhoneOS26.2.sdk` in `$THEOS/sdks`;
- GNU make, `dpkg`, and `ldid`.

```bash
git submodule update --init --recursive
./build.sh package
./build.sh verify
```

`build.sh` verifies and applies the pinned UIKit 26 presentation patch to the
exact FLEX submodule revision before compilation. A mismatched revision fails
the build instead of silently dropping the responsive UI changes.

The build uses explicit Core, HookProviders, HookRuntime, and LiquidGlassUI
manifests, but all four are source groups in the same Theos target. They do not
produce helper dylibs. HookProviders adds the vendored hidden namespaced
fishhook source exactly once and exports a small ABI marker so CI can prove it
was linked. The
Logos metadata-row integration uses the Substrate-compatible generator. The
workflow performs the same SDK validation, build, Mach-O audit, package
collection, and artifact upload automatically.

## Feather injection

Import the built `.dylib` or `.deb` as a tweak in Feather, enable ElleKit tweak
injection, sign the complete IPA with the developer certificate, and install it.
Feather places the Substrate-compatible framework in the app's `Frameworks`
directory and rewrites the tweak dependency to its `@rpath` form for the signed
bundle.

The expected app layout contains the host executable, its normal frameworks,
`AllFLEXing.dylib`, and `CydiaSubstrate.framework` backed by ElleKit. It must not
contain rootless/jailbreak rpaths.

## Validation boundary

CI proves source compilation and the static Mach-O contract. Final acceptance
also requires a Feather-signed iOS 26 device test covering Objective-C,
fishhook, inline hooks, live disable/forwarding, persistence, safe mode, UI,
morphing, rotation, and accessibility.

See `AGENTS.md` for the normative engineering contract and
`docs/REFERENCE_BINARY.md` for the uploaded binary audit.
