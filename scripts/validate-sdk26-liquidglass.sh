#!/usr/bin/env bash
set -euo pipefail

: "${THEOS:?THEOS must be set}"

sdk="$THEOS/sdks/iPhoneOS26.2.sdk"
headers="$sdk/System/Library/Frameworks/UIKit.framework/Headers"

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
test -f patches/flex-uikit26-liquid-glass.patch
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
grep -q 'include modules/HookRuntime/Module.mk' libflex/Makefile
grep -q 'include modules/HookProviders/Module.mk' libflex/Makefile
grep -q 'include modules/LiquidGlassUI/Module.mk' libflex/Makefile
grep -q 'FLEX_FISHHOOK_SOURCE' libflex/Makefile
grep -q 'ALLFLEXING_EMBEDDED_FISHHOOK_SOURCES' libflex/Makefile
grep -q 'FLEX_UPSTREAM_FISHHOOK_SOURCE' libflex/Makefile
grep -q 'LOGOS_DEFAULT_GENERATOR := MobileSubstrate' libflex/Makefile
grep -Fq '$(TWEAK_NAME)_USE_MODULES := 0' libflex/Makefile
grep -Eq '\$\(TWEAK_NAME\)_LIBRARIES[[:space:]]*:=[^#]*substrate' libflex/Makefile
test -f libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q "UIGlassEffect" libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q "UIGlassContainerEffect" libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'glassContainerViewWithSpacing' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'materializeGlassView' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'FLEXGlassCellBackgroundView' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'styleTableCell' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'kFLEXGlassSearchBackgroundKey' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'FLEXGlassBaseSurfaceColor' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'FLEXGlassPanelFillColor' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'tableView.opaque = YES' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'navigationController.view.opaque = YES' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'styleTabBar' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'UITabBarController compiled with SDK 26 owns' libflex/AllFLEXing/FLEXLiquidGlass.m
test -f libflex/AllFLEXing/FLEXHookWorkspaceController.m
grep -q 'setViewControllers:self.workspaceNavigationControllers' libflex/AllFLEXing/FLEXHookWorkspaceController.m
if grep -q 'self\.tabs[[:space:]]*=' libflex/AllFLEXing/FLEXHookWorkspaceController.m; then
    echo "error: lazy UITab providers previously rendered inert runtime tabs" >&2
    exit 1
fi
grep -q 'UITabBarMinimizeBehaviorOnScrollDown' libflex/AllFLEXing/FLEXHookWorkspaceController.m
grep -q 'AllFLEXing.RuntimeWorkspace.TabBar' libflex/AllFLEXing/FLEXHookWorkspaceController.m
grep -q 'styleTabBar:self.tabBar' libflex/AllFLEXing/FLEXHookWorkspaceController.m
if grep -q 'appearance\.backgroundEffect.*glassEffect' \
    libflex/AllFLEXing/FLEXHookWorkspaceController.m; then
    echo "error: do not replace UIKit 26 native tab-bar glass with UIBarAppearance material" >&2
    exit 1
fi
grep -q 'sheet.largestUndimmedDetentIdentifier = nil' libflex/AllFLEXing/FLEXHookWorkspaceController.m
grep -q 'setContentScrollView' libflex/AllFLEXing/FLEXHookToggles.m
grep -q 'menu:\[self scopeMenu\]' libflex/AllFLEXing/FLEXRuntimeBrowserController.m
grep -q 'UIContentUnavailableConfiguration' libflex/AllFLEXing/FLEXRuntimeBrowserController.m
grep -q 'UIListContentConfiguration' libflex/AllFLEXing/FLEXHookToggles.m
grep -q '#import <substrate.h>' libflex/AllFLEXing/FLEXHooking.m
grep -q 'MSHookMessageEx' libflex/AllFLEXing/FLEXHooking.m
grep -q 'MSHookFunction' libflex/AllFLEXing/FLEXHooking.m
grep -q 'FLEXHookRegistry' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'upsertDiscoveredEntry' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'FLEXRuntimeScanner' libflex/AllFLEXing/FLEXRuntimeScanner.m
grep -q 'objectiveCEntryForClass' libflex/AllFLEXing/FLEXRuntimeScanner.m
grep -q 'FLEXRuntimeImagesDidChangeNotification' libflex/AllFLEXing/FLEXRuntimeScanner.m
test -f libflex/AllFLEXing/FLEXRuntimeHookActions.m
test -f libflex/AllFLEXing/FLEXRuntimeHookIntegration.xm
grep -q '%hook FLEXMetadataSection' libflex/AllFLEXing/FLEXRuntimeHookIntegration.xm
grep -q 'FLEXEmbeddedFishhookAvailable' libflex/AllFLEXing/FLEXSymbolRebind.m
grep -q 'FLEXMSHookMessageProviderAvailable' libflex/AllFLEXing/FLEXHooking.m
grep -q 'FLEXMSHookFunctionProviderAvailable' libflex/AllFLEXing/FLEXHooking.m
grep -q 'applyEntryIdentifier' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'runtime-toggle-applied' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'recordOverrideHit' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'observedCount' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'failClosedEntryIdentifier' libflex/AllFLEXing/FLEXRuntimeHookActions.m
grep -q 'UIApplicationDidBecomeActiveNotification' libflex/AllFLEXing/AllFLEXingLoader.m
grep -q 'cornerConfiguration' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'configureWithDefaultBackground' libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q 'hidesSharedBackground' libflex/AllFLEXing/FLEXHookToggles.m
grep -q 'vm_protect' libflex/AllFLEXing/flex_fishhook.c
grep -q 'VM_PROT_COPY' libflex/AllFLEXing/flex_fishhook.c
grep -q '\[toggle sizeToFit\]' libflex/AllFLEXing/FLEXRuntimeHookActions.m
if grep -q 'UIStackView \*accessory' libflex/AllFLEXing/FLEXRuntimeHookActions.m; then
    echo "error: contextual hook rows must not restore the clipped accessory stack" >&2
    exit 1
fi
if grep -q 'mprotect[[:space:]]*(' libflex/AllFLEXing/flex_fishhook.c; then
    echo "error: legacy mprotect fishhook path is not allowed" >&2
    exit 1
fi

if grep -Eq '(navigationBar|toolbar|bar)\.standardAppearance[[:space:]]*=[[:space:]]*nil' \
    libflex/AllFLEXing/FLEXLiquidGlass.m; then
    echo "error: UIKit 26 standard bar appearances are nonnull" >&2
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

echo "SDK 26.2, provider modules, Logos row integration, Liquid Glass, registry, and Substrate-compatible build contract: OK"
