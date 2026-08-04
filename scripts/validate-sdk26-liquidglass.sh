#!/usr/bin/env bash
set -euo pipefail

: "${THEOS:?THEOS must be set}"

sdk="$THEOS/sdks/iPhoneOS26.2.sdk"
headers="$sdk/System/Library/Frameworks/UIKit.framework/Headers"
glass="libflex/AllFLEXing/FLEXLiquidGlass.m"
workspace="libflex/AllFLEXing/FLEXHookWorkspaceController.m"
browser="libflex/AllFLEXing/FLEXRuntimeBrowserController.m"
hook_center="libflex/AllFLEXing/FLEXHookToggles.m"
detail="libflex/AllFLEXing/FLEXHookEntryDetailController.m"
actions="libflex/AllFLEXing/FLEXRuntimeHookActions.m"

test -d "$headers" || {
    echo "error: missing UIKit headers in $sdk" >&2
    exit 1
}

for token in \
    UIGlassEffect \
    UIGlassContainerEffect \
    UIGlassEffectStyleRegular \
    glassButtonConfiguration \
    prominentGlassButtonConfiguration \
    UICornerConfiguration \
    cornerConfiguration \
    hidesSharedBackground \
    UIScrollEdgeEffect \
    UIScrollEdgeEffectStyle \
    softStyle \
    hardStyle \
    topEdgeEffect \
    bottomEdgeEffect; do
    grep -R "$token" "$headers" >/dev/null || {
        echo "error: SDK 26.2 UIKit is missing $token" >&2
        exit 1
    }
done

grep -q "iphone:clang:26.2:16.3" Makefile
grep -q "iphone:clang:26.2:16.3" libflex/Makefile
grep -q '^ARCHS := arm64$' Makefile
grep -q '^ARCHS := arm64$' libflex/Makefile
test -f build.sh
grep -q 'make package FINALPACKAGE=1' build.sh
grep -q 'prepare_flex_ui' build.sh
grep -q 'flex-uikit26-liquid-glass.patch' build.sh
test -f patches/flex-uikit26-liquid-glass.patch

for token in \
    FLEXScopeCarousel.m \
    FLEXExplorerToolbar.m \
    FLEXNavigationController.m \
    FLEXGlobalsViewController.m \
    FLEXWindow.m \
    searchBarPlacementBarButtonItem \
    flex_pointIsInsidePresentedHierarchy \
    ownsModalBackdrop \
    'largestUndimmedDetentIdentifier = nil'; do
    grep -q "$token" patches/flex-uikit26-liquid-glass.patch || {
        echo "error: pinned upstream FLEX patch is missing $token" >&2
        exit 1
    }
done
if grep -q '^+.*largestUndimmedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge' \
    patches/flex-uikit26-liquid-glass.patch; then
    echo "error: FLEX tool sheets must not expose an interactive undimmed host" >&2
    exit 1
fi

for module in HookRuntime HookProviders LiquidGlassUI; do
    grep -q "include modules/$module/Module.mk" libflex/Makefile
done

grep -q 'FLEX_FISHHOOK_SOURCE' libflex/Makefile
grep -q 'ALLFLEXING_EMBEDDED_FISHHOOK_SOURCES' libflex/Makefile
grep -q 'FLEX_UPSTREAM_FISHHOOK_SOURCE' libflex/Makefile
grep -q 'LOGOS_DEFAULT_GENERATOR := MobileSubstrate' libflex/Makefile
grep -Fq '$(TWEAK_NAME)_USE_MODULES := 0' libflex/Makefile
grep -Eq '\$\(TWEAK_NAME\)_LIBRARIES[[:space:]]*:=[^#]*substrate' libflex/Makefile

# Native SDK 26 Liquid Glass contract.
test -f "$glass"
for token in \
    'AllFLEXing native UIKit 26 Liquid Glass and scroll-edge ABI 2' \
    UIGlassEffect \
    UIGlassContainerEffect \
    glassContainerViewWithSpacing \
    materializeGlassView \
    glassButtonConfiguration \
    prominentGlassButtonConfiguration \
    UICornerConfiguration \
    'applyScrollEdgeEffectsToScrollView' \
    'topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle' \
    'bottomEdgeEffect.style = UIScrollEdgeEffectStyle.hardStyle' \
    'tableView.opaque = YES' \
    'navigationController.view.opaque = YES' \
    'styleTabBar' \
    'UITabBarController compiled with SDK 26 owns'; do
    grep -Fq "$token" "$glass" || {
        echo "error: native Liquid Glass contract is missing $token" >&2
        exit 1
    }
done

# Per-row and search-field visual effect views caused the double-blur and slow
# scrolling. UIKit 26 owns these surfaces now.
for obsolete in \
    FLEXGlassCellBackgroundView \
    kFLEXGlassCellBackgroundKey \
    kFLEXGlassSearchBackgroundKey; do
    if grep -Fq "$obsolete" "$glass"; then
        echo "error: obsolete custom glass layer returned: $obsolete" >&2
        exit 1
    fi
done
grep -Fq 'Do not put a separate UIGlassEffect behind every reusable row' "$glass"
grep -Fq 'A second visual-effect view here creates the' "$glass"

if grep -Eq '(navigationBar|toolbar|bar)\.standardAppearance[[:space:]]*=[[:space:]]*nil' \
    "$glass"; then
    echo "error: UIKit 26 standard bar appearances are nonnull" >&2
    exit 1
fi

# Concrete owner controllers, not +load categories, provide compact grouped UI.
for file in "$browser" "$hook_center" "$detail"; do
    test -f "$file"
    if grep -q '+ (void)load' "$file"; then
        echo "error: concrete controller still installs itself through +load: $file" >&2
        exit 1
    fi
done
grep -q 'FLEXRuntimeGroupEntries' "$browser"
grep -q 'FLEXRuntimeGroupEntries' "$hook_center"
grep -q 'FLEXConfigureCompactRuntimeTable' "$browser"
grep -q 'FLEXConfigureCompactRuntimeTable' "$hook_center"
grep -q 'FLEXConfigureCompactRuntimeTable' "$detail"
grep -q 'No patch, swizzle or hook is installed until Apply is pressed' "$hook_center"
grep -q 'Apply This Hook' "$actions"

# Workspace is a concrete UIKit child hierarchy with UI-first deterministic presentation.
grep -q 'setViewControllers:self.workspaceNavigationControllers' "$workspace"
grep -q 'AllFLEXing UI-first Runtime Workspace presentation ABI 2' "$workspace"
grep -q 'UISceneActivationStateForegroundActive' "$workspace"
grep -q 'gFLEXWorkspacePresentationInFlight' "$workspace"
grep -q 'gFLEXWorkspaceOwnedWindow' "$workspace"
grep -q 'AllFLEXing.RuntimeWorkspace.TabBar' "$workspace"
grep -q 'UITabBarMinimizeBehaviorOnScrollDown' "$workspace"
grep -q 'sheet.largestUndimmedDetentIdentifier = nil' "$workspace"
if grep -q 'self\.tabs[[:space:]]*=' "$workspace"; then
    echo "error: lazy UITab providers may render inert runtime tabs" >&2
    exit 1
fi
if grep -q 'appearance\.backgroundEffect.*glassEffect' "$workspace"; then
    echo "error: do not cover native tab-bar glass with UIBarAppearance material" >&2
    exit 1
fi

# Runtime and provider integration remains linked and operational.
grep -q '#import <substrate.h>' libflex/AllFLEXing/FLEXHooking.m
grep -q 'MSHookMessageEx' libflex/AllFLEXing/FLEXHooking.m
grep -q 'MSHookFunction' libflex/AllFLEXing/FLEXHooking.m
grep -q 'FLEXEmbeddedFishhookAvailable' libflex/AllFLEXing/FLEXSymbolRebind.m
grep -q 'FLEXMSHookMessageProviderAvailable' libflex/AllFLEXing/FLEXHooking.m
grep -q 'FLEXMSHookFunctionProviderAvailable' libflex/AllFLEXing/FLEXHooking.m
grep -q 'applyEntryIdentifier' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'runtime-toggle-applied' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'recordOverrideHit' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'observedCount' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'vm_protect' libflex/AllFLEXing/flex_fishhook.c
grep -q 'VM_PROT_COPY' libflex/AllFLEXing/flex_fishhook.c
if grep -q 'mprotect[[:space:]]*(' libflex/AllFLEXing/flex_fishhook.c; then
    echo "error: legacy mprotect fishhook path is not allowed" >&2
    exit 1
fi

if test -e libflex/AllFLEXing/FLEXGlassAutostyle.m || \
   grep -Rq 'FLEXWalkViewTree\|UIViewController.class.*viewDidAppear' libflex/AllFLEXing; then
    echo "error: global FLEX view-tree autostyle must not return" >&2
    exit 1
fi

if grep -q 'GENERATOR[[:space:]]*:=[[:space:]]*internal' libflex/Makefile; then
    echo "error: internal Logos generator cannot provide the required C hook backend" >&2
    exit 1
fi

echo "SDK 26.2 native Liquid Glass, scroll edges, concrete owners and UI-first Workspace: OK"
