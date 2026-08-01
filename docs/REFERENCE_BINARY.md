# Uploaded AllFLEXing binary audit

This document records structural evidence from the uploaded Mach-O binaries and
compares it with the rebuilt SDK 26.2 artifact. File size is never used as a
proxy for feature completeness.

## Latest uploaded reference

| Property | Observed value |
|---|---|
| SHA-256 | `3d82f8fae9e4675bf95f1f772a872a98c60f4c1fae1636864e08a4162761cddd` |
| Size | 3,352,960 bytes |
| Slice | arm64 |
| File type | `MH_DYLIB` |
| `LC_ID_DYLIB` | `/usr/lib/libFLEX.dylib` |
| Minimum OS | iOS 15.0 |
| Build SDK | iOS 16.5 |
| UUID | `9f14512c-03d3-326b-bf6b-f2837ee52adc` |
| Load commands | 37 |
| Encryption | disabled (`cryptid = 0`) |

The binary has 15,839 symbol-table records, 7,170 non-debug definitions, 489
exports, and 2,037 imports. Its Objective-C inventory contains 170 defined class
symbols, 329 class-name strings, 313 imported classes, and 4,551 selectors.

The complete arm64 disassembly covers every byte in all three executable
sections. It contains 299,875 lines (17,818,905 bytes) plus a 6,019,545-byte
machine-readable index with symbol ranges, raw instruction bytes, branch
destinations, and cross-references. Their SHA-256 values are respectively
`0054e16c6a04fd435e2c756c47b1c51b432f30ca36edb189dd834cf0616d93eb`
and `a716309bc186c2b846a8d60007369c849c61f58fce2abe002c11a7622278e6aa`.

## What is genuinely unified

The latest reference exports the compatibility functions `FLXGetManager`,
`FLXRevealSEL`, and `FLXWindowClass` while defining the complete FLEX class
inventory in the same Mach-O. It does not load a second FLEXing or libFLEX
dylib. This confirms the intended composition: loader plus former libFLEX API
plus the FLEX implementation in one image.

The reference also contains a contextual runtime-hook layer that was not present
in the first uploaded binary:

- class `FLEXRuntimeHookActions`;
- `canHookMethod:target:` and `canHookBoolProperty:target:`;
- actions for forcing `TRUE`, forcing `FALSE`, clearing a hook, and copying its
  identifier;
- `flex_boolHookSwitchChanged:` integrated into `FLEXMetadataSection`;
- persistence key `flex_runtime_bool_hook_overrides_v1`;
- an exact BOOL return check for `B`, `c`, and `C` encodings;
- a two-hidden-argument check, so this older implementation accepts only BOOL
  getters with no explicit argument;
- `MSHookMessageEx` installation and one saved original IMP per key.

The rebuilt implementation keeps this contextual surface but routes it through
the stronger shared registry. It additionally supports the already validated
one-object and one-integer Objective-C BOOL profiles, separates pending,
desired, installed, and effective states, and applies a contextual switch to
exactly that target in real time. Batch configuration still has an explicit
Apply transaction.

## fishhook, Logos, and the hook provider

The reference contains local definitions for the namespaced fishhook routines:

- `flex_rebind_symbols`;
- `flex_rebind_symbols_image`;
- the lazy/non-lazy symbol pointer walkers and image callback.

It also contains generated Logos methods and constructors. fishhook is therefore
real code in that Mach-O, not merely a header or a string.

`MSHookMessageEx` is an imported symbol backed by the
`@rpath/CydiaSubstrate.framework/CydiaSubstrate` dependency. The symbol named
`MSHookFunction` in the reference's local table is located in `__bss`; it is a
runtime-resolved function pointer, not an embedded inline-hook implementation.
The provider framework still has to be present in the signed app.

The rebuilt target makes these boundaries explicit:

- namespaced fishhook C source is vendored outside the FLEX submodule and
  compiled exactly once as an in-dylib provider module;
- its iOS 15+ path uses `vm_protect` with copy-on-write protection and reports
  success only after replacing a real bind slot;
- exported `FLEXEmbeddedFishhookAvailable` and ABI-version symbols create a
  verifiable strong link to both hidden fishhook entry points;
- known FLEX metadata-row integration is compiled through Logos;
- dynamic Objective-C targets call `MSHookMessageEx` through the provider;
- C inline targets call `MSHookFunction` only after explicit ABI validation;
- provider identity is verified at runtime instead of inferred from a string.

## Why the reference is larger

The latest reference is an unoptimized debug build. It retains local function
names, object-file records, and absolute build paths. Its `__LINKEDIT` segment is
1,599,872 bytes, and its unoptimized `__text` section is 1,100,160 bytes.

The successful SDK 26.2 release artifact is 1,529,264 bytes. Its stripped
`__LINKEDIT` is 103,856 bytes, yet it defines more Objective-C classes and
selectors than the reference. The smaller release size is explained by
optimization and symbol stripping; it is not evidence that FLEX, libFLEX, or a
provider adapter was omitted.

CI verifies composition using exports, defined class inventory, load commands,
provider imports, embedded-fishhook marker symbols, runtime classes, and UI
strings. It does not enforce a target byte size.

## Sideload corrections required by the rebuilt artifact

The latest reference is useful as a behavior reference but is not the desired
final binary contract:

- it was linked with SDK 16.5 rather than SDK 26.2;
- its install name is `/usr/lib/libFLEX.dylib` rather than
  `@rpath/AllFLEXing.dylib`;
- it contains `/var/jb` and `.jbroot` rpaths;
- it targets iOS 15.0 and contains no native UIKit 26 class references;
- its hook persistence collapses runtime state into a smaller dictionary and
  does not provide the full Apply/safe-mode lifecycle.

The rebuilt target uses SDK 26.2, arm64, minimum iOS 16.3, no jailbreak rpaths,
one `@rpath/AllFLEXing.dylib`, a Feather-rewritable provider dependency, native
UIKit 26 Liquid Glass, and the shared persistent Hook Center.

## Earlier uploaded reference

The earlier SHA-256
`9aafc761197495ec6b7b95930825623ad5dc2c511be13e5e44bf9666406370d3`
is a 3,038,912-byte arm64/arm64e universal dylib. It also unifies FLEX and the
former libFLEX exports, but it lacks the latest reference's
`FLEXRuntimeHookActions` contextual layer and has no hard hook-provider
dependency. Both slices were built with SDK 16.5 and retain rootless rpaths.
