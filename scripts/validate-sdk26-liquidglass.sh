#!/usr/bin/env bash
set -euo pipefail

: "${THEOS:?THEOS must be set}"

sdk="$THEOS/sdks/iPhoneOS26.2.sdk"
headers="$sdk/System/Library/Frameworks/UIKit.framework/Headers"
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/libflex/AllFLEXing"

test -d "$headers" || {
    echo "error: missing UIKit headers in $sdk" >&2
    exit 1
}

grep -R "UIGlassEffect" "$headers" >/dev/null
grep -R "UIGlassContainerEffect" "$headers" >/dev/null
grep -R "UIGlassEffectStyleRegular" "$headers" >/dev/null
grep -R "glassButtonConfiguration" "$headers" >/dev/null
grep -R "prominentGlassButtonConfiguration" "$headers" >/dev/null
grep -R "UICornerConfiguration" "$headers" >/dev/null
grep -R "cornerConfiguration" "$headers" >/dev/null
grep -R "hidesSharedBackground" "$headers" >/dev/null

grep -q "iphone:clang:26.2:16.3" Makefile
grep -q "iphone:clang:26.2:16.3" libflex/Makefile
grep -q '^ARCHS := arm64$' Makefile
grep -q '^ARCHS := arm64$' libflex/Makefile
test -f build.sh
grep -q 'make package FINALPACKAGE=1' build.sh
grep -q 'prepare_flex_ui' build.sh
grep -q 'flex-uikit26-liquid-glass.patch' build.sh
grep -q 'apply-flex-method-rendering-safety.py' build.sh
if grep -q 'apply-flex-runtime-extension-v2.py' build.sh; then
    echo "error: native FLEX Runtime Browser presentation transformer returned" >&2
    exit 1
fi

test -f patches/flex-uikit26-liquid-glass.patch
test ! -e patches/flex-hookable-runtime-filter.patch
test ! -e patches/flex-semantic-runtime-search.patch
test ! -e scripts/apply-flex-runtime-extension-v2.py
grep -q 'FLEXScopeCarousel.m' patches/flex-uikit26-liquid-glass.patch
grep -q 'FLEXExplorerToolbar.m' patches/flex-uikit26-liquid-glass.patch
grep -q 'FLEXNavigationController.m' patches/flex-uikit26-liquid-glass.patch
grep -q 'FLEXGlobalsViewController.m' patches/flex-uikit26-liquid-glass.patch
grep -q 'FLEXWindow.m' patches/flex-uikit26-liquid-glass.patch
grep -q 'searchBarPlacementBarButtonItem' patches/flex-uikit26-liquid-glass.patch
grep -q 'flex_pointIsInsidePresentedHierarchy' patches/flex-uikit26-liquid-glass.patch
grep -q 'ownsModalBackdrop' patches/flex-uikit26-liquid-glass.patch
grep -q 'largestUndimmedDetentIdentifier = nil' patches/flex-uikit26-liquid-glass.patch
if grep -q '^+.*largestUndimmedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge' \
    patches/flex-uikit26-liquid-glass.patch; then
    echo "error: FLEX tool sheets must not expose an interactive undimmed host" >&2
    exit 1
fi

# FLEX supplies the optimized Objective-C discovery/reflection backend. The
# product UI is an AllFLEXing-owned direct list of eligible methods and resolved
# Objective-C ABIs, not FLEX's class/key-path browser presentation.
test -f "$src/FLEXObjCHookResolver.m"
test -f "$src/FLEXHookableObjCRuntimeViewController.h"
test -f "$src/FLEXHookableObjCRuntimeViewController.m"
test ! -e "$src/FLEXHookableObjectExplorerViewController.h"
test ! -e "$src/FLEXHookableObjectExplorerViewController.m"
grep -q 'UITableViewController' "$src/FLEXHookableObjCRuntimeViewController.h"
grep -q 'FLEXRuntimeClient' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'classesForToken:FLEXSearchToken.any' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'methodsForToken:FLEXSearchToken.any' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'entryForMethod:method' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'entry.abi != FLEXHookABIUnknown' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'mergeDiscoveredEntries:discovered' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'surface:FLEXHookSurfaceObjectiveC' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'ABI resolved:' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'Class, selector, ABI or image' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'applyEntryIdentifier:identifier' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'FLEXObjCSemanticCompactText' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'method.objc_method' "$src/FLEXObjCHookResolver.m"
grep -q "\*returnCode != 'B'" "$src/FLEXObjCHookResolver.m"
if grep -Eq 'FLEXObjcRuntimeViewController|runtimeBrowserSearchPlainTextQuery|didSelectClass:|FLEXHookableObjectExplorerViewController' \
    "$src/FLEXHookableObjCRuntimeViewController.h" \
    "$src/FLEXHookableObjCRuntimeViewController.m"; then
    echo "error: native FLEX browser presentation leaked back into the Objective-C product UI" >&2
    exit 1
fi
if grep -q 'method.description' "$src/FLEXHookableObjCRuntimeViewController.m"; then
    echo "error: Objective-C list must not invoke FLEX pretty rendering during scan/filter" >&2
    exit 1
fi

# C ABI selection belongs to the dedicated symbol patcher because C signatures
# cannot be inferred from a symbol name.
grep -q 'C Symbol Patcher' "$src/FLEXRuntimeBrowserController.m"
grep -q 'Symbol, image or ABI' "$src/FLEXRuntimeBrowserController.m"
grep -q 'C signatures are not inferable' "$src/FLEXRuntimeBrowserController.m"
grep -q 'FLEXHookABIName(entry.abi)' "$src/FLEXRuntimeBrowserController.m"
grep -q 'choose the exact ABI' "$src/FLEXRuntimeBrowserController.m"
grep -q 'title:@"C Patcher"' "$src/FLEXHookWorkspaceController.m"

# The custom scanner is C/Mach-O only. Reintroducing a parallel Objective-C
# catalogue is a build failure.
grep -q 'scanCImportsIncludingSystemImages' "$src/FLEXRuntimeScanner.m"
grep -q 'FLEXRuntimeImagesDidChangeNotification' "$src/FLEXRuntimeScanner.m"
if grep -Eq 'objc_copyClassList|scanObjectiveCRuntime|objectiveCEntryForClass|class_copyMethodList' \
    "$src/FLEXRuntimeScanner.m" "$src/FLEXRuntimeScanner.h"; then
    echo "error: custom Objective-C runtime scanner/catalogue returned" >&2
    exit 1
fi
if grep -Eq 'FLEXRuntimeBrowserKindObjectiveC|scanObjectiveCRuntime' \
    "$src/FLEXRuntimeBrowserController.m" "$src/FLEXRuntimeBrowserController.h"; then
    echo "error: C Symbol Patcher must remain C-only" >&2
    exit 1
fi

# Row controls stage and apply exactly their own stable registry identifier.
grep -q 'Apply This Hook' "$src/FLEXRuntimeHookActions.m"
grep -q 'stageEnabled' "$src/FLEXRuntimeHookActions.m"
grep -q 'applyEntryIdentifier:identifier' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'applyEntryIdentifier:identifier' "$src/FLEXRuntimeBrowserController.m"
python3 - "$src/FLEXRuntimeHookActions.m" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding='utf-8')
match = re.search(r'- \(void\)switchChanged:\(UISwitch \*\)toggle \{(.*?)\n\}', text, re.S)
if not match:
    raise SystemExit('switchChanged implementation not found')
body = match.group(1)
if 'applyPending' in body:
    raise SystemExit('runtime row switch still applies unrelated pending entries')
if 'Reapply This Hook' in text:
    raise SystemExit('legacy immediate/reapply wording remains')
PY

grep -q 'include modules/HookRuntime/Module.mk' libflex/Makefile
grep -q 'include modules/HookProviders/Module.mk' libflex/Makefile
grep -q 'include modules/LiquidGlassUI/Module.mk' libflex/Makefile
grep -q 'FLEX_FISHHOOK_SOURCE' libflex/Makefile
grep -q 'ALLFLEXING_EMBEDDED_FISHHOOK_SOURCES' libflex/Makefile
grep -q 'FLEX_UPSTREAM_FISHHOOK_SOURCE' libflex/Makefile
grep -q 'LOGOS_DEFAULT_GENERATOR := MobileSubstrate' libflex/Makefile
grep -Fq '$(TWEAK_NAME)_USE_MODULES := 0' libflex/Makefile
grep -Eq '\$\(TWEAK_NAME\)_LIBRARIES[[:space:]]*:=[^#]*substrate' libflex/Makefile
if grep -q 'FLEXHookableObjectExplorerViewController.m' libflex/modules/HookRuntime/Module.mk; then
    echo "error: obsolete class-explorer presentation remains in HookRuntime manifest" >&2
    exit 1
fi

test -f "$src/FLEXLiquidGlass.m"
grep -q "UIGlassEffect" "$src/FLEXLiquidGlass.m"
grep -q "UIGlassContainerEffect" "$src/FLEXLiquidGlass.m"
grep -q 'glassContainerViewWithSpacing' "$src/FLEXLiquidGlass.m"
grep -q 'materializeGlassView' "$src/FLEXLiquidGlass.m"
grep -q 'FLEXGlassCellBackgroundView' "$src/FLEXLiquidGlass.m"
grep -q 'styleTableCell' "$src/FLEXLiquidGlass.m"
grep -q 'kFLEXGlassSearchBackgroundKey' "$src/FLEXLiquidGlass.m"
grep -q 'FLEXGlassBaseSurfaceColor' "$src/FLEXLiquidGlass.m"
grep -q 'FLEXGlassPanelFillColor' "$src/FLEXLiquidGlass.m"
grep -q 'tableView.opaque = YES' "$src/FLEXLiquidGlass.m"
grep -q 'navigationController.view.opaque = YES' "$src/FLEXLiquidGlass.m"
grep -q 'styleTabBar' "$src/FLEXLiquidGlass.m"
grep -q 'UITabBarController compiled with SDK 26 owns' "$src/FLEXLiquidGlass.m"

test -f "$src/FLEXHookWorkspaceController.m"
grep -q 'setViewControllers:self.workspaceNavigationControllers' "$src/FLEXHookWorkspaceController.m"
if grep -q 'self\.tabs[[:space:]]*=' "$src/FLEXHookWorkspaceController.m"; then
    echo "error: lazy UITab providers previously rendered inert runtime tabs" >&2
    exit 1
fi
grep -q 'UITabBarMinimizeBehaviorOnScrollDown' "$src/FLEXHookWorkspaceController.m"
grep -q 'AllFLEXing.RuntimeWorkspace.TabBar' "$src/FLEXHookWorkspaceController.m"
grep -q 'styleTabBar:self.tabBar' "$src/FLEXHookWorkspaceController.m"
if grep -q 'appearance\.backgroundEffect.*glassEffect' "$src/FLEXHookWorkspaceController.m"; then
    echo "error: do not replace UIKit 26 native tab-bar glass with UIBarAppearance material" >&2
    exit 1
fi
grep -q 'sheet.largestUndimmedDetentIdentifier = nil' "$src/FLEXHookWorkspaceController.m"
grep -q 'setContentScrollView' "$src/FLEXHookToggles.m"
grep -q 'menu:\[self scopeMenu\]' "$src/FLEXRuntimeBrowserController.m"
grep -q 'UIContentUnavailableConfiguration' "$src/FLEXRuntimeBrowserController.m"
grep -q 'UIContentUnavailableConfiguration' "$src/FLEXHookableObjCRuntimeViewController.m"
grep -q 'UIListContentConfiguration' "$src/FLEXHookToggles.m"
grep -q '#import <substrate.h>' "$src/FLEXHooking.m"
grep -q 'MSHookMessageEx' "$src/FLEXHooking.m"
grep -q 'MSHookFunction' "$src/FLEXHooking.m"
grep -q 'FLEXHookRegistry' "$src/FLEXHookRegistry.m"
grep -q 'upsertDiscoveredEntry' "$src/FLEXHookRegistry.m"
test -f "$src/FLEXRuntimeHookActions.m"
test -f "$src/FLEXRuntimeHookIntegration.xm"
grep -q '%hook FLEXMetadataSection' "$src/FLEXRuntimeHookIntegration.xm"
grep -q 'FLEXEmbeddedFishhookAvailable' "$src/FLEXSymbolRebind.m"
grep -q 'FLEXMSHookMessageProviderAvailable' "$src/FLEXHooking.m"
grep -q 'FLEXMSHookFunctionProviderAvailable' "$src/FLEXHooking.m"
grep -q 'applyEntryIdentifier' "$src/FLEXHookRegistry.m"
grep -q 'recordOverrideHit' "$src/FLEXHookRegistry.m"
grep -q 'observedCount' "$src/FLEXHookRegistry.m"
grep -q 'UIApplicationDidBecomeActiveNotification' "$src/AllFLEXingLoader.m"
grep -q 'cornerConfiguration' "$src/FLEXLiquidGlass.m"
grep -q 'configureWithDefaultBackground' "$src/FLEXLiquidGlass.m"
grep -q 'hidesSharedBackground' "$src/FLEXHookToggles.m"
grep -q 'vm_protect' "$src/flex_fishhook.c"
grep -q 'VM_PROT_COPY' "$src/flex_fishhook.c"
grep -q '\[toggle sizeToFit\]' "$src/FLEXRuntimeHookActions.m"
if grep -q 'UIStackView \*accessory' "$src/FLEXRuntimeHookActions.m"; then
    echo "error: contextual hook rows must not restore the clipped accessory stack" >&2
    exit 1
fi
if grep -q 'mprotect[[:space:]]*(' "$src/flex_fishhook.c"; then
    echo "error: legacy mprotect fishhook path is not allowed" >&2
    exit 1
fi
if grep -Eq '(navigationBar|toolbar|bar)\.standardAppearance[[:space:]]*=[[:space:]]*nil' \
    "$src/FLEXLiquidGlass.m"; then
    echo "error: UIKit 26 standard bar appearances are nonnull" >&2
    exit 1
fi
if test -e "$src/FLEXGlassAutostyle.m" || \
   grep -Rq 'FLEXWalkViewTree\|UIViewController.class.*viewDidAppear' "$src"; then
    echo "error: global FLEX view-tree autostyle must not return" >&2
    exit 1
fi
if grep -q 'GENERATOR[[:space:]]*:=[[:space:]]*internal' libflex/Makefile; then
    echo "error: internal Logos generator cannot provide the required C hook backend" >&2
    exit 1
fi

echo "SDK 26.2, FLEX-backed direct ABI-resolved Objective-C functions, explicit C Symbol Patcher, per-target Apply, Liquid Glass, and provider contract: OK"
