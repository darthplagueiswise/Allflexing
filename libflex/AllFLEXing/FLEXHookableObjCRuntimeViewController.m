#import "FLEXHookableObjCRuntimeViewController.h"

#import "FLEXHookableObjectExplorerViewController.h"
#import "FLEXLiquidGlass.h"
#import "FLEXMethod.h"
#import "FLEXObjCHookResolver.h"
#import "FLEXRuntimeClient.h"
#import "FLEXRuntimeHostIdentity.h"
#import "FLEXSearchToken.h"

#import <objc/runtime.h>

static NSString *FLEXSemanticNormalizedText(NSString *input) {
    if (input.length == 0) {
        return @"";
    }

    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSCharacterSet *uppercase = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lowercase = NSCharacterSet.lowercaseLetterCharacterSet;
    NSMutableString *result = [NSMutableString string];

    for (NSUInteger index = 0; index < input.length; index++) {
        unichar character = [input characterAtIndex:index];
        BOOL isLetter = [letters characterIsMember:character];
        BOOL isDigit = [digits characterIsMember:character];
        if (!isLetter && !isDigit) {
            if (result.length && ![result hasSuffix:@" "]) {
                [result appendString:@" "];
            }
            continue;
        }

        BOOL isUpper = [uppercase characterIsMember:character];
        BOOL boundary = NO;
        if (index > 0 && isUpper) {
            unichar previous = [input characterAtIndex:index - 1];
            BOOL previousLower = [lowercase characterIsMember:previous];
            BOOL previousDigit = [digits characterIsMember:previous];
            BOOL previousUpper = [uppercase characterIsMember:previous];
            BOOL nextLower = NO;
            if (index + 1 < input.length) {
                nextLower = [lowercase characterIsMember:[input characterAtIndex:index + 1]];
            }
            boundary = previousLower || previousDigit || (previousUpper && nextLower);
        }
        if (boundary && result.length && ![result hasSuffix:@" "]) {
            [result appendString:@" "];
        }

        NSString *piece = [NSString stringWithCharacters:&character length:1];
        [result appendString:piece.lowercaseString];
    }

    NSArray<NSString *> *parts = [result componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *nonempty = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) {
            [nonempty addObject:part];
        }
    }
    return [nonempty componentsJoinedByString:@" "];
}

static NSString *FLEXSemanticCompactText(NSString *input) {
    NSString *normalized = FLEXSemanticNormalizedText(input);
    return [normalized stringByReplacingOccurrencesOfString:@" " withString:@""];
}

static NSArray<NSString *> *FLEXSemanticQueryTerms(NSString *query) {
    NSString *normalized = FLEXSemanticNormalizedText(query);
    if (normalized.length == 0) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *terms = [NSMutableOrderedSet orderedSet];
    for (NSString *term in [normalized componentsSeparatedByString:@" "]) {
        if (term.length) {
            [terms addObject:term];
        }
    }
    return terms.array;
}

static BOOL FLEXSemanticFieldsMatchQuery(NSArray<NSString *> *fields,
                                         NSArray<NSString *> *terms) {
    NSMutableArray<NSString *> *normalizedFields = [NSMutableArray arrayWithCapacity:fields.count];
    NSMutableArray<NSString *> *compactFields = [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *field in fields) {
        [normalizedFields addObject:FLEXSemanticNormalizedText(field ?: @"")];
        [compactFields addObject:FLEXSemanticCompactText(field ?: @"")];
    }

    for (NSString *term in terms) {
        NSString *compactTerm = FLEXSemanticCompactText(term);
        BOOL matched = NO;
        for (NSUInteger index = 0; index < normalizedFields.count; index++) {
            NSString *normalizedField = normalizedFields[index];
            NSString *compactField = compactFields[index];
            if ([normalizedField rangeOfString:term].location != NSNotFound ||
                (compactTerm.length &&
                 [compactField rangeOfString:compactTerm].location != NSNotFound)) {
                matched = YES;
                break;
            }
        }
        if (!matched) {
            return NO;
        }
    }
    return YES;
}

@interface FLEXHookableObjCRuntimeViewController ()
@property (nonatomic) dispatch_queue_t semanticQueue;
@property (nonatomic, copy) NSArray<NSString *> *semanticClasses;
@property (nonatomic, copy) NSArray<NSArray<FLEXMethod *> *> *semanticMethods;
@end

@implementation FLEXHookableObjCRuntimeViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        _semanticQueue = dispatch_queue_create(
            "com.allflexing.flex-semantic-search",
            DISPATCH_QUEUE_SERIAL
        );
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hookable Objective-C";
    self.searchController.searchBar.placeholder = @"Nome, palavras ou sintaxe FLEX";

    // Plain semantic search is the default. The original symbol-only keyboard
    // row is hidden here because its unexplained punctuation was not usable.
    // Advanced FLEX key paths remain accepted when typed explicitly.
    self.searchController.searchBar.inputAccessoryView = nil;

    [FLEXRuntimeClient initializeWebKitLegacy];

    UIBarButtonItem *help = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"questionmark.circle"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showRuntimeSearchHelp:)];
    help.accessibilityLabel = @"Como pesquisar no runtime";
    self.navigationItem.rightBarButtonItem = help;

    self.toolbarItems = @[];
    [self.navigationController setToolbarHidden:YES animated:NO];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)showRuntimeSearchHelp:(UIBarButtonItem *)sender {
    (void)sender;
    NSString *message =
        @"Busca normal (recomendada)\n"
         "Digite palavras em qualquer ordem. CamelCase, snake_case, espaços e a forma compacta são equivalentes.\n\n"
         "Exemplos:\n"
         "fbconfigmanager\n"
         "fb config manager\n"
         "employee enable\n\n"
         "Sintaxe FLEX avançada\n"
         ". separa imagem, classe e método\n"
         "- antes do método = método de instância\n"
         "+ antes do método = método de classe\n"
         "* = qualquer trecho\n\n"
         "Exemplos avançados:\n"
         "*.FBConfigManager.*\n"
         "*.*.-isEnabled\n"
         "*.*.+sharedInstance";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Pesquisa Objective-C"
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Optional FLEXKeyPathSearchController delegate extension installed by the
/// pinned AllFLEXing patch. Bundle/class/method discovery still belongs to FLEX.
- (BOOL)runtimeBrowserShouldIncludeImagePath:(NSString *)path
                                  shortName:(NSString *)shortName {
    (void)shortName;
    return FLEXRuntimeImageIsAllowedHostImage(path);
}

- (BOOL)runtimeBrowserShouldIncludeMethod:(FLEXMethod *)method
                             inClassNamed:(NSString *)className {
    return [FLEXObjCHookResolver canRepresentMethod:method
                                       inClassNamed:className];
}

- (BOOL)runtimeBrowserShouldUsePlainTextSearchForQuery:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        return NO;
    }

    // A period, wildcard, escape, or leading +/- opts into the original FLEX
    // key-path grammar. Everything else is normal semantic text.
    return ![trimmed containsString:@"."] &&
           ![trimmed containsString:@"*"] &&
           ![trimmed containsString:@"\\"] &&
           ![trimmed hasPrefix:@"+"] &&
           ![trimmed hasPrefix:@"-"];
}

- (void)buildSemanticIndexIfNeeded {
    if (self.semanticClasses && self.semanticMethods) {
        return;
    }

    FLEXRuntimeClient *runtime = FLEXRuntimeClient.runtime;
    [runtime reloadLibrariesList];

    NSMutableArray<NSString *> *allowedPaths = [NSMutableArray array];
    for (NSString *shortName in runtime.imageDisplayNames) {
        NSString *path = [runtime imageNameForShortName:shortName];
        if (FLEXRuntimeImageIsAllowedHostImage(path)) {
            [allowedPaths addObject:path];
        }
    }

    NSMutableArray<NSString *> *classes = [runtime
        classesForToken:FLEXSearchToken.any
        inBundles:allowedPaths];
    NSArray<NSMutableArray<FLEXMethod *> *> *methodLists = [runtime
        methodsForToken:FLEXSearchToken.any
        instance:nil
        inClasses:classes];

    NSMutableArray<NSString *> *acceptedClasses = [NSMutableArray array];
    NSMutableArray<NSArray<FLEXMethod *> *> *acceptedMethods = [NSMutableArray array];
    NSUInteger count = MIN(classes.count, methodLists.count);
    for (NSUInteger index = 0; index < count; index++) {
        NSString *className = classes[index];
        NSMutableArray<FLEXMethod *> *hookable = [NSMutableArray array];
        for (FLEXMethod *method in methodLists[index]) {
            if ([FLEXObjCHookResolver canRepresentMethod:method
                                            inClassNamed:className]) {
                [hookable addObject:method];
            }
        }
        if (hookable.count) {
            [acceptedClasses addObject:className];
            [acceptedMethods addObject:hookable.copy];
        }
    }

    self.semanticClasses = acceptedClasses.copy;
    self.semanticMethods = acceptedMethods.copy;
}

- (void)runtimeBrowserSearchPlainTextQuery:(NSString *)query
                                completion:(void (^)(NSArray<NSString *> *,
                                                     NSArray<NSArray<FLEXMethod *> *> *))completion {
    NSString *queryCopy = query.copy;
    dispatch_async(self.semanticQueue, ^{
        [self buildSemanticIndexIfNeeded];
        NSArray<NSString *> *terms = FLEXSemanticQueryTerms(queryCopy);
        NSMutableArray<NSString *> *matchingClasses = [NSMutableArray array];
        NSMutableArray<NSArray<FLEXMethod *> *> *matchingMethods = [NSMutableArray array];

        NSUInteger count = MIN(self.semanticClasses.count, self.semanticMethods.count);
        for (NSUInteger index = 0; index < count; index++) {
            NSString *className = self.semanticClasses[index];
            const char *rawImage = class_getImageName(NSClassFromString(className));
            NSString *image = rawImage ? [NSString stringWithUTF8String:rawImage] : @"";
            NSMutableArray<FLEXMethod *> *methods = [NSMutableArray array];

            for (FLEXMethod *method in self.semanticMethods[index]) {
                NSArray<NSString *> *fields = @[
                    className ?: @"",
                    method.selectorString ?: @"",
                    method.description ?: @"",
                    method.typeEncoding ?: @"",
                    image.lastPathComponent ?: image ?: @"",
                ];
                if (FLEXSemanticFieldsMatchQuery(fields, terms)) {
                    [methods addObject:method];
                }
            }

            if (methods.count) {
                [methods sortUsingSelector:@selector(compare:)];
                [matchingClasses addObject:className];
                [matchingMethods addObject:methods.copy];
            }
        }

        if (completion) {
            completion(matchingClasses.copy, matchingMethods.copy);
        }
    });
}

- (void)didSelectClass:(Class)cls {
    NSParameterAssert(cls);
    FLEXHookableObjectExplorerViewController *explorer =
        [FLEXHookableObjectExplorerViewController exploringObject:cls
                                                   customSections:nil];
    [self.navigationController pushViewController:explorer animated:YES];
}

@end
