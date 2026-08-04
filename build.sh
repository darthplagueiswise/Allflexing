#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

if [ -d /opt/homebrew/opt/make/libexec/gnubin ]; then
	PATH="/opt/homebrew/opt/make/libexec/gnubin:$PATH"
fi

readonly PRODUCT_NAME="AllFLEXing"
readonly RELEASE_DIR="$PROJECT_ROOT/release"
readonly FLEX_UI_PATCH="$PROJECT_ROOT/patches/flex-uikit26-liquid-glass.patch"
readonly FLEX_KEYCHAIN_SOURCE="$PROJECT_ROOT/libflex/FLEX/Classes/GlobalStateExplorers/Keychain/FLEXKeychainViewController.m"

log() {
	printf '[AllFLEXing] %s\n' "$*"
}

die() {
	printf '[AllFLEXing] error: %s\n' "$*" >&2
	exit 1
}

ensure_theos() {
	if [ -n "${THEOS:-}" ]; then
		return
	fi
	if [ -d "${HOME}/theos" ]; then
		export THEOS="${HOME}/theos"
		return
	fi
	die "THEOS is not set and ${HOME}/theos does not exist"
}

sanitize_flex_upstream_examples() {
	[ -f "$FLEX_KEYCHAIN_SOURCE" ] || die "FLEX Keychain source is missing"
	python3 - "$FLEX_KEYCHAIN_SOURCE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = 'make.textField(@"Service name, i.e. Instagram");'
new = 'make.textField(@"Service name, e.g. app service");'

if old in text:
    path.write_text(text.replace(old, new), encoding="utf-8")
elif new not in text:
    raise SystemExit("unexpected FLEX Keychain placeholder source")
PY

	if grep -Eqi 'Instagram|RyukGram|com\.burbn|FBSharedFramework' "$FLEX_KEYCHAIN_SOURCE"; then
		die "fixed host-app example remains in FLEX Keychain source"
	fi
	log "sanitized fixed host-app examples from upstream FLEX"
}

prepare_flex_ui() {
	[ -f "$FLEX_UI_PATCH" ] || die "missing pinned FLEX UIKit 26 patch"
	[ -d "$PROJECT_ROOT/libflex/FLEX" ] || die "FLEX submodule is missing"

	if git -C "$PROJECT_ROOT/libflex/FLEX" apply --reverse --check "$FLEX_UI_PATCH" >/dev/null 2>&1; then
		log "pinned FLEX UIKit 26 patch is already applied"
	else
		if ! git -C "$PROJECT_ROOT/libflex/FLEX" apply --check "$FLEX_UI_PATCH"; then
			die "FLEX submodule does not match the pinned Liquid Glass patch base"
		fi
		git -C "$PROJECT_ROOT/libflex/FLEX" apply "$FLEX_UI_PATCH"
		log "applied pinned FLEX UIKit 26 presentation patch"
	fi

	sanitize_flex_upstream_examples
}

clean_build() {
	make clean >/dev/null 2>&1 || true
	rm -rf "$PROJECT_ROOT/.theos" "$PROJECT_ROOT/libflex/.theos"
}

find_dylib() {
	local candidate
	for candidate in \
		"$PROJECT_ROOT/.theos/obj/$PRODUCT_NAME.dylib" \
		"$PROJECT_ROOT/.theos/obj/debug/$PRODUCT_NAME.dylib" \
		"$PROJECT_ROOT/libflex/.theos/obj/$PRODUCT_NAME.dylib" \
		"$PROJECT_ROOT/libflex/.theos/obj/debug/$PRODUCT_NAME.dylib"; do
		if [ -f "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	find "$PROJECT_ROOT/.theos" "$PROJECT_ROOT/libflex/.theos" \
		-type f -name "$PRODUCT_NAME.dylib" -print 2>/dev/null | head -n 1 || true
}

stage_artifacts() {
	local dylib
	local deb
	dylib="$(find_dylib)"
	[ -n "$dylib" ] && [ -f "$dylib" ] || die "$PRODUCT_NAME.dylib was not produced"

	mkdir -p "$RELEASE_DIR"
	rm -f "$RELEASE_DIR/$PRODUCT_NAME.dylib" "$RELEASE_DIR/$PRODUCT_NAME.deb"
	cp "$dylib" "$RELEASE_DIR/$PRODUCT_NAME.dylib"

	deb="$(find "$PROJECT_ROOT" -type f -path '*/packages/*.deb' -print | sort | tail -n 1)"
	if [ -n "$deb" ] && [ -f "$deb" ]; then
		cp "$deb" "$RELEASE_DIR/$PRODUCT_NAME.deb"
	fi

	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$RELEASE_DIR/$PRODUCT_NAME.dylib"
		[ ! -f "$RELEASE_DIR/$PRODUCT_NAME.deb" ] || \
			shasum -a 256 "$RELEASE_DIR/$PRODUCT_NAME.deb"
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$RELEASE_DIR/$PRODUCT_NAME.dylib"
		[ ! -f "$RELEASE_DIR/$PRODUCT_NAME.deb" ] || \
			sha256sum "$RELEASE_DIR/$PRODUCT_NAME.deb"
	fi
}

build_product() {
	local package="$1"
	local incremental="$2"
	prepare_flex_ui
	if [ "$incremental" != "1" ]; then
		clean_build
	fi

	if [ "$package" = "1" ]; then
		log "building unified SDK 26.2 arm64 package"
		make package FINALPACKAGE=1
	else
		log "building unified SDK 26.2 arm64 dylib"
		make FINALPACKAGE=1
	fi
	stage_artifacts
}

verify_product() {
	local dylib
	dylib="$(find_dylib)"
	[ -n "$dylib" ] && [ -f "$dylib" ] || die "$PRODUCT_NAME.dylib is missing"
	bash scripts/verify-dylib.sh "$dylib"
}

usage() {
	cat <<'EOF'
Usage: ./build.sh <dylib|package|verify|clean> [--fast]

  dylib       Build the single AllFLEXing.dylib for Feather injection.
  package     Build the dylib and deb, then stage both in release/.
  verify      Verify the existing Mach-O SDK, architecture, hooks, and UI.
  clean       Remove only this project's Theos build outputs.
  --fast      Keep incremental objects for dylib/package builds.
EOF
}

main() {
	ensure_theos
	local command="${1:-}"
	local incremental=0
	if [ "${2:-}" = "--fast" ]; then
		incremental=1
	elif [ -n "${2:-}" ]; then
		die "unknown option: ${2}"
	fi

	case "$command" in
		dylib) build_product 0 "$incremental" ;;
		package) build_product 1 "$incremental" ;;
		verify) verify_product ;;
		clean) clean_build ;;
		*) usage; exit 1 ;;
	esac
}

main "$@"
