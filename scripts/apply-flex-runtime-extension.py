#!/usr/bin/env python3
"""Apply AllFLEXing's filtered semantic search extension to pinned FLEX.

The submodule remains the source of Objective-C discovery, tokenization,
reflection models, caches, grouping and navigation. This script only adds
optional delegate predicates and a plain-text result bridge to the exact pinned
FLEXKeyPathSearchController sources.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FLEX_ROOT = ROOT / "libflex" / "FLEX"
HEADER = FLEX_ROOT / "Classes/GlobalStateExplorers/RuntimeBrowser/FLEXKeyPathSearchController.h"
SOURCE = FLEX_ROOT / "Classes/GlobalStateExplorers/RuntimeBrowser/FLEXKeyPathSearchController.m"
MARKER = "runtimeBrowserSearchPlainTextQuery"


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"error: {message}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"expected exactly one {label} anchor, found {count}")
    return text.replace(old, new, 1)


def apply_header(text: str) -> str:
    text = replace_once(
        text,
        '#import "FLEXRuntimeBrowserToolbar.h"\n#import "FLEXMethod.h"\n\n',
        '#import "FLEXRuntimeBrowserToolbar.h"\n#import "FLEXMethod.h"\n\n'
        'typedef void (^FLEXRuntimePlainSearchCompletion)(\n'
        '    NSArray<NSString *> *classes,\n'
        '    NSArray<NSArray<FLEXMethod *> *> *methods);\n\n',
        "header typedef",
    )
    text = replace_once(
        text,
        '- (void)didSelectClass:(Class)cls;\n\n@end\n',
        '- (void)didSelectClass:(Class)cls;\n\n'
        '@optional\n'
        '/// Optional filtering/search hooks. FLEX still owns tokenization,\n'
        '/// runtime discovery, reflection models, caching, grouping and table navigation.\n'
        '- (BOOL)runtimeBrowserShouldIncludeImagePath:(NSString *)path\n'
        '                                  shortName:(NSString *)shortName;\n'
        '- (BOOL)runtimeBrowserShouldIncludeMethod:(FLEXMethod *)method\n'
        '                             inClassNamed:(NSString *)className;\n'
        '- (BOOL)runtimeBrowserShouldUsePlainTextSearchForQuery:(NSString *)query;\n'
        '- (void)runtimeBrowserSearchPlainTextQuery:(NSString *)query\n'
        '                                completion:(FLEXRuntimePlainSearchCompletion)completion;\n\n'
        '@end\n',
        "delegate extension",
    )
    return text


def apply_source(text: str) -> str:
    text = replace_once(
        text,
        '#import "FLEXRuntimeController.h"\n',
        '#import "FLEXRuntimeController.h"\n#import "FLEXSearchToken.h"\n',
        "FLEXSearchToken import",
    )
    text = replace_once(
        text,
        '@property (nonatomic) NSArray<NSArray<FLEXMethod *> *> *classesToMethods;\n@end\n',
        '@property (nonatomic) NSArray<NSArray<FLEXMethod *> *> *classesToMethods;\n'
        '@property (nonatomic) BOOL plainTextMode;\n'
        '@property (nonatomic) NSUInteger plainSearchGeneration;\n'
        '@end\n',
        "plain-search properties",
    )
    text = replace_once(
        text,
        '+ (instancetype)delegate:(id<FLEXKeyPathSearchControllerDelegate>)delegate {\n'
        '    FLEXKeyPathSearchController *controller = [self new];\n'
        '    controller->_bundlesOrClasses = [FLEXRuntimeController allBundleNames];\n'
        '    controller->_delegate         = delegate;\n'
        '    controller->_emptySuggestion  = NSBundle.mainBundle.executablePath.lastPathComponent;\n',
        '+ (instancetype)delegate:(id<FLEXKeyPathSearchControllerDelegate>)delegate {\n'
        '    FLEXKeyPathSearchController *controller = [self new];\n'
        '    controller->_delegate         = delegate;\n'
        '    controller->_emptySuggestion  = NSBundle.mainBundle.executablePath.lastPathComponent;\n'
        '    controller->_bundlesOrClasses = [controller filteredBundleNames:\n'
        '        [FLEXRuntimeController allBundleNames]\n'
        '    ];\n',
        "delegate initialization",
    )

    helpers = r'''
- (NSArray<NSString *> *)filteredBundleNames:(NSArray<NSString *> *)bundleNames {
    if (![self.delegate respondsToSelector:@selector(runtimeBrowserShouldIncludeImagePath:shortName:)]) {
        return bundleNames;
    }

    return [bundleNames flex_filtered:^BOOL(NSString *shortName, NSUInteger idx) {
        NSString *path = [FLEXRuntimeController imagePathWithShortName:shortName];
        return [self.delegate runtimeBrowserShouldIncludeImagePath:path shortName:shortName];
    }];
}

- (void)applyDelegateMethodFilter:(NSMutableArray<NSArray<FLEXMethod *> *> *)methods
                          classes:(NSMutableArray<NSString *> *)classes {
    if (![self.delegate respondsToSelector:@selector(runtimeBrowserShouldIncludeMethod:inClassNamed:)]) {
        return;
    }

    NSUInteger count = MIN(methods.count, classes.count);
    for (NSUInteger idx = 0; idx < count; idx++) {
        NSString *className = classes[idx];
        NSArray<FLEXMethod *> *filtered = [methods[idx] flex_filtered:^BOOL(
            FLEXMethod *method, NSUInteger methodIndex
        ) {
            return [self.delegate runtimeBrowserShouldIncludeMethod:method
                                                        inClassNamed:className];
        }];
        methods[idx] = filtered;
    }
}

- (void)showOnlyClassesWithAcceptedMethods:(NSArray<NSString *> *)classNames {
    NSMutableArray<NSString *> *classes = classNames.mutableCopy;
    NSMutableArray<NSArray<FLEXMethod *> *> *methods = [[FLEXRuntimeController
n        methodsForToken:FLEXSearchToken.any
        instance:nil
        inClasses:classes
    ] mutableCopy];

    self.bundlesOrClasses = nil;
    [self setNonEmptyMethodLists:methods withClasses:classes];
}

- (BOOL)delegateHandlesPlainTextQuery:(NSString *)query {
    return query.length &&
        [self.delegate respondsToSelector:@selector(runtimeBrowserShouldUsePlainTextSearchForQuery:)] &&
        [self.delegate respondsToSelector:@selector(runtimeBrowserSearchPlainTextQuery:completion:)] &&
        [self.delegate runtimeBrowserShouldUsePlainTextSearchForQuery:query];
}

- (void)performPlainTextSearch:(NSString *)query {
    NSUInteger generation = ++self.plainSearchGeneration;
    self.plainTextMode = YES;
    self.keyPath = nil;

    __weak typeof(self) weakSelf = self;
    [self.delegate runtimeBrowserSearchPlainTextQuery:query completion:^(
        NSArray<NSString *> *classes,
        NSArray<NSArray<FLEXMethod *> *> *methods
    ) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.plainSearchGeneration ||
                ![self.delegate.searchController.searchBar.text isEqualToString:query]) {
                return;
            }

            self.bundlesOrClasses = nil;
            self.classes = classes ?: @[];
            self.filteredClasses = self.classes;
            self.classesToMethods = methods ?: @[];
            [self updateToolbarButtons];
            [self.delegate.tableView reloadData];
        });
    }];
}

'''.replace("[FLEXRuntimeController\nn", "[FLEXRuntimeController\n")
    text = replace_once(
        text,
        '- (void)scrollViewDidScroll:(UIScrollView *)scrollView {\n',
        helpers + '- (void)scrollViewDidScroll:(UIScrollView *)scrollView {\n',
        "runtime helper insertion",
    )

    text = replace_once(
        text,
        '            } else { // We\'re looking at bundles or classes\n'
        '                self.bundlesOrClasses = models;\n'
        '                self.classesToMethods = nil;\n'
        '            }\n',
        '            } else { // We\'re looking at bundles or classes\n'
        '                if (keyPath.classKey &&\n'
        '                    [self.delegate respondsToSelector:\n'
        '                        @selector(runtimeBrowserShouldIncludeMethod:inClassNamed:)]) {\n'
        '                    [self showOnlyClassesWithAcceptedMethods:models];\n'
        '                } else {\n'
        '                    self.bundlesOrClasses = [self filteredBundleNames:models];\n'
        '                    self.classesToMethods = nil;\n'
        '                }\n'
        '            }\n',
        "bundle/class result filtering",
    )
    text = replace_once(
        text,
        '- (void)updateToolbarButtons {\n'
        '    // Update toolbar buttons\n'
        '    [self.toolbar setKeyPath:self.keyPath suggestions:self.suggestions];\n'
        '}\n',
        '- (void)updateToolbarButtons {\n'
        '    if (self.plainTextMode) {\n'
        '        [self.toolbar setKeyPath:FLEXRuntimeKeyPath.empty suggestions:@[]];\n'
        '    } else {\n'
        '        [self.toolbar setKeyPath:self.keyPath suggestions:self.suggestions];\n'
        '    }\n'
        '}\n',
        "toolbar mode",
    )
    text = replace_once(
        text,
        '- (void)setNonEmptyMethodLists:(NSMutableArray<NSArray<FLEXMethod *> *> *)methods\n'
        '                   withClasses:(NSMutableArray<NSString *> *)classes {\n'
        '    // Remove sections with no methods\n',
        '- (void)setNonEmptyMethodLists:(NSMutableArray<NSArray<FLEXMethod *> *> *)methods\n'
        '                   withClasses:(NSMutableArray<NSString *> *)classes {\n'
        '    [self applyDelegateMethodFilter:methods classes:classes];\n\n'
        '    // Remove sections with no methods\n',
        "method result filtering",
    )

    old_should_change = r'''- (BOOL)searchBar:(UISearchBar *)searchBar shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    // Check if character is even legal
    if (![FLEXRuntimeKeyPathTokenizer allowedInKeyPath:text]) {
        return NO;
    }
    
    BOOL terminatedToken = NO;
    BOOL isAppending = range.length == 0 && range.location == searchBar.text.length;
    if (isAppending && [text isEqualToString:@"."]) {
        terminatedToken = YES;
    }

    // Actually parse input
    @try {
        text = [searchBar.text stringByReplacingCharactersInRange:range withString:text] ?: text;
        self.keyPath = [FLEXRuntimeKeyPathTokenizer tokenizeString:text];
        if (self.keyPath.classKey.isAbsolute && terminatedToken) {
            [self didSelectAbsoluteClass:self.keyPath.classKey.string];
        }
    } @catch (id e) {
        return NO;
    }

    return YES;
}
'''
    new_should_change = r'''- (BOOL)searchBar:(UISearchBar *)searchBar shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    NSString *proposed = [searchBar.text stringByReplacingCharactersInRange:range
                                                                  withString:text] ?: text;
    if ([self delegateHandlesPlainTextQuery:proposed]) {
        self.plainTextMode = YES;
        self.keyPath = nil;
        return YES;
    }

    self.plainTextMode = NO;
    if (![FLEXRuntimeKeyPathTokenizer allowedInKeyPath:text]) {
        return NO;
    }

    BOOL terminatedToken = NO;
    BOOL isAppending = range.length == 0 && range.location == searchBar.text.length;
    if (isAppending && [text isEqualToString:@"."]) {
        terminatedToken = YES;
    }

    @try {
        self.keyPath = [FLEXRuntimeKeyPathTokenizer tokenizeString:proposed];
        if (self.keyPath.classKey.isAbsolute && terminatedToken) {
            [self didSelectAbsoluteClass:self.keyPath.classKey.string];
        }
    } @catch (id e) {
        return NO;
    }

    return YES;
}
'''
    text = replace_once(text, old_should_change, new_should_change, "search input mode")

    text = replace_once(
        text,
        '- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {\n'
        '    [_timer invalidate];\n\n'
        '    // Schedule update timer\n'
        '    if (searchText.length) {\n',
        '- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {\n'
        '    [_timer invalidate];\n\n'
        '    if ([self delegateHandlesPlainTextQuery:searchText]) {\n'
        '        self.timer = [NSTimer flex_fireSecondsFromNow:0.15 block:^{\n'
        '            [self performPlainTextSearch:searchText];\n'
        '        }];\n'
        '        return;\n'
        '    }\n\n'
        '    self.plainTextMode = NO;\n'
        '    if (searchText.length) {\n',
        "semantic debounce",
    )
    text = replace_once(
        text,
        '    else {\n'
        '        _bundlesOrClasses = [FLEXRuntimeController allBundleNames];\n',
        '    else {\n'
        '        self.plainSearchGeneration++;\n'
        '        _bundlesOrClasses = [self filteredBundleNames:\n'
        '            [FLEXRuntimeController allBundleNames]\n'
        '        ];\n',
        "empty-query reset",
    )
    text = replace_once(
        text,
        '- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {\n'
        '    self.keyPath = FLEXRuntimeKeyPath.empty;\n'
        '    [self updateTable];\n'
        '}\n',
        '- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {\n'
        '    self.plainTextMode = NO;\n'
        '    self.plainSearchGeneration++;\n'
        '    self.keyPath = FLEXRuntimeKeyPath.empty;\n'
        '    [self updateTable];\n'
        '}\n',
        "cancel reset",
    )
    text = replace_once(
        text,
        '- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {\n'
        '    searchBar.text = self.keyPath.description;\n'
        '}\n',
        '- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {\n'
        '    if (!self.plainTextMode) {\n'
        '        searchBar.text = self.keyPath.description;\n'
        '    }\n'
        '}\n',
        "search edit restoration",
    )
    text = replace_once(
        text,
        '- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {\n'
        '    [_timer invalidate];\n'
        '    [searchBar resignFirstResponder];\n'
        '    [self updateTable];\n'
        '}\n',
        '- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {\n'
        '    [_timer invalidate];\n'
        '    [searchBar resignFirstResponder];\n'
        '    if ([self delegateHandlesPlainTextQuery:searchBar.text]) {\n'
        '        [self performPlainTextSearch:searchBar.text];\n'
        '    } else {\n'
        '        [self updateTable];\n'
        '    }\n'
        '}\n',
        "search submit mode",
    )
    return text


def main() -> None:
    if not HEADER.is_file() or not SOURCE.is_file():
        fail("pinned FLEX Runtime Browser sources are missing")

    header = HEADER.read_text(encoding="utf-8")
    source = SOURCE.read_text(encoding="utf-8")

    if MARKER in header and MARKER in source:
        print("[AllFLEXing] FLEX hookable semantic runtime extension already applied")
        return
    if MARKER in header or MARKER in source:
        fail("FLEX runtime extension is only partially applied")

    header = apply_header(header)
    source = apply_source(source)

    HEADER.write_text(header, encoding="utf-8")
    SOURCE.write_text(source, encoding="utf-8")
    print("[AllFLEXing] applied FLEX hookable semantic runtime extension")


if __name__ == "__main__":
    main()
