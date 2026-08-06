#!/usr/bin/env python3
"""Make the pinned FLEX method pretty-printer fail closed on malformed metadata."""

from __future__ import annotations

from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (
    ROOT
    / "libflex"
    / "FLEX"
    / "Classes"
    / "Utility"
    / "Runtime"
    / "Objc"
    / "Reflection"
    / "FLEXMethod.m"
)
MARKER = "AllFLEXing malformed selector/type-encoding rendering guard"


def fail(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"expected one {label} anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    if not SOURCE.is_file():
        fail("pinned FLEXMethod.m is missing")

    text = SOURCE.read_text(encoding="utf-8")
    if MARKER in text:
        print("[AllFLEXing] FLEX method rendering safety already applied")
        return

    old_pretty_name = '''- (NSString *)prettyName {
    NSString *methodTypeString = self.isInstanceMethod ? @"-" : @"+";
    NSString *readableReturnType = [FLEXRuntimeUtility readableTypeForEncoding:@(self.signature.methodReturnType ?: "")];
    
    NSString *prettyName = [NSString stringWithFormat:@"%@ (%@)", methodTypeString, readableReturnType];
    NSArray *components = [self prettyArgumentComponents];
'''
    new_pretty_name = '''- (NSString *)prettyName {
    NSString *methodTypeString = self.isInstanceMethod ? @"-" : @"+";
    NSString *readableReturnType = nil;
    @try {
        readableReturnType = [FLEXRuntimeUtility
            readableTypeForEncoding:@(self.signature.methodReturnType ?: "")];
    } @catch (__unused NSException *exception) {
        // AllFLEXing malformed selector/type-encoding rendering guard.
        return [NSString stringWithFormat:@"%@ %@", methodTypeString, self.selectorString];
    }
    
    NSString *prettyName = [NSString stringWithFormat:@"%@ (%@)", methodTypeString, readableReturnType];
    NSArray *components = [self prettyArgumentComponents];
'''
    text = replace_once(text, old_pretty_name, new_pretty_name, "prettyName")

    old_components = '''- (NSArray *)prettyArgumentComponents {
    // NSMethodSignature can't handle some type encodings
    // like ^AI@:ir* which happen to very much exist
    if (self.signature.numberOfArguments < self.numberOfArguments) {
        return nil;
    }
    
    NSMutableArray *components = [NSMutableArray new];

    NSArray *selectorComponents = [self.selectorString componentsSeparatedByString:@":"];
    NSUInteger numberOfArguments = self.numberOfArguments;
    
    for (NSUInteger argIndex = 2; argIndex < numberOfArguments; argIndex++) {
        assert(argIndex < self.signature.numberOfArguments);
        
        const char *argType = [self.signature getArgumentTypeAtIndex:argIndex] ?: "?";
        NSString *readableArgType = [FLEXRuntimeUtility readableTypeForEncoding:@(argType)];
        NSString *prettyComponent = [NSString
            stringWithFormat:@"%@:(%@) ",
            selectorComponents[argIndex - 2],
            readableArgType
        ];

        [components addObject:prettyComponent];
    }
    
    return components;
}
'''
    new_components = '''- (NSArray *)prettyArgumentComponents {
    // NSMethodSignature can't handle some type encodings
    // like ^AI@:ir* which happen to very much exist
    if (!self.signature || self.numberOfArguments < 2 ||
        self.signature.numberOfArguments < self.numberOfArguments) {
        return nil;
    }
    
    NSMutableArray *components = [NSMutableArray new];

    NSArray *selectorComponents = [self.selectorString componentsSeparatedByString:@":"];
    NSUInteger numberOfArguments = self.numberOfArguments;
    NSUInteger explicitArguments = numberOfArguments - 2;
    if (selectorComponents.count < explicitArguments) {
        // AllFLEXing malformed selector/type-encoding rendering guard.
        return nil;
    }
    
    for (NSUInteger argIndex = 2; argIndex < numberOfArguments; argIndex++) {
        if (argIndex >= self.signature.numberOfArguments ||
            argIndex - 2 >= selectorComponents.count) {
            return nil;
        }
        
        const char *argType = [self.signature getArgumentTypeAtIndex:argIndex] ?: "?";
        NSString *readableArgType = nil;
        @try {
            readableArgType = [FLEXRuntimeUtility readableTypeForEncoding:@(argType)];
        } @catch (__unused NSException *exception) {
            return nil;
        }
        NSString *prettyComponent = [NSString
            stringWithFormat:@"%@:(%@) ",
            selectorComponents[argIndex - 2],
            readableArgType
        ];

        [components addObject:prettyComponent];
    }
    
    return components;
}
'''
    text = replace_once(
        text,
        old_components,
        new_components,
        "prettyArgumentComponents",
    )

    SOURCE.write_text(text, encoding="utf-8")
    print("[AllFLEXing] applied FLEX method rendering safety")


if __name__ == "__main__":
    main()
