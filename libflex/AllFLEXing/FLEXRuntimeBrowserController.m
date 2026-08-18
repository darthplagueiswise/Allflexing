#import "FLEXRuntimeBrowserController.h"

#import "FLEXCHookEngine.h"
#import "FLEXCompactRuntimeUI.h"
#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeImageSession.h"
#import "FLEXRuntimeScanner.h"

#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <string.h>

const char *FLEXLiveRuntimeBrowserABIVersion =
    "AllFLEXing live class-first runtime browser ABI 1";

static const void *kFLEXRuntimeBrowserEntryKey =
    &kFLEXRuntimeBrowserEntryKey;

static dispatch_queue_t FLEXRuntimeBrowserWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.live-runtime-browser",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
}

static NSString *FLEXRuntimeCanonicalPath(NSString *path) {
    if (!path.length) return @"";
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    NSString *standardized = resolved.stringByStandardizingPath;
    return standardized.length ? standardized : path;
}

static BOOL FLEXRuntimeClassBelongsToImage(Class targetClass,
                                            FLEXRuntimeImageDescriptor *image) {
    if (!targetClass || !image.path.length) return NO;
    const char *rawImage = class_getImageName(targetClass);
    if (!rawImage) return NO;
    NSString *classImage = FLEXRuntimeCanonicalPath(
        [NSString stringWithUTF8String:rawImage]
    );
    return classImage.length &&
        [classImage isEqualToString:FLEXRuntimeCanonicalPath(image.path)];
}

static const char *FLEXRuntimeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXRuntimeExactObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXRuntimeSkipQualifiers(returnType) != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return FLEXHookABIObjCBoolNoArguments;
    if (count != 3) return FLEXHookABIUnknown;

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *code = FLEXRuntimeSkipQualifiers(argumentType);
    if (*code == '@' || *code == '#' || *code == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *code)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static NSString *FLEXRuntimeObjectiveCIdentifier(
    FLEXRuntimeImageDescriptor *image,
    NSString *className,
    NSString *selectorName,
    BOOL classMethod
) {
    return [NSString stringWithFormat:@"objc|%@|%@|%@|%@",
        image.path.lastPathComponent ?: @"image",
        className ?: @"",
        classMethod ? @"+" : @"-",
        selectorName ?: @""];
}

static FLEXHookEntry *FLEXRuntimeEntryForMethod(
    Class targetClass,
    Method method,
    BOOL classMethod,
    FLEXRuntimeImageDescriptor *image
) {
    if (!targetClass || !method || !image) return nil;
    const char *rawClassName = class_getName(targetClass);
    SEL selector = method_getName(method);
    const char *rawSelectorName = selector ? sel_getName(selector) : NULL;
    if (!rawClassName || !rawSelectorName) return nil;

    NSString *className = [NSString stringWithUTF8String:rawClassName];
    NSString *selectorName = [NSString stringWithUTF8String:rawSelectorName];
    const char *rawEncoding = method_getTypeEncoding(method);
    NSString *encoding = rawEncoding
        ? [NSString stringWithUTF8String:rawEncoding] : @"";
    FLEXHookABI abi = FLEXRuntimeExactObjectiveCABI(method);
    BOOL provider = FLEXMSHookMessageProviderAvailable();

    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = FLEXRuntimeObjectiveCIdentifier(
        image, className, selectorName, classMethod);
    entry.title = [NSString stringWithFormat:@"%@[%@ %@]",
        classMethod ? @"+" : @"-", className, selectorName];
    entry.imageName = image.displayName;
    entry.surface = FLEXHookSurfaceObjectiveC;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.abi = abi;
    entry.available = YES;
    entry.hookable = provider && abi != FLEXHookABIUnknown;
    entry.stale = NO;
    entry.detail = abi == FLEXHookABIUnknown
        ? [NSString stringWithFormat:@"%@ · inspect only",
            encoding.length ? encoding : @"type encoding unavailable"]
        : [NSString stringWithFormat:@"%@ · %@",
            FLEXHookABIName(abi),
            encoding.length ? encoding : @"type encoding unavailable"];
    entry.locator = @{
        @"source": @"live-objc-runtime",
        @"class": className ?: @"",
        @"selector": selectorName ?: @"",
        @"classMethod": @(classMethod),
        @"encoding": encoding ?: @"",
        @"image": image.path ?: @"",
        @"imageUUID": image.uuid ?: @"",
        @"methodAddress": @((uintptr_t)method_getImplementation(method)),
        @"backendEvidence": provider
            ? @"MSHookMessageEx-live-provider"
            : @"MSHookMessageEx-provider-unavailable",
        @"abiEvidence": abi == FLEXHookABIUnknown
            ? @"unresolved"
            : @"objc-type-encoding-live",
    };
    if (!provider && abi != FLEXHookABIUnknown) {
        entry.lastError = @"MSHookMessageEx provider unavailable";
    }

    FLEXHookEntry *existing = [FLEXHookRegistry.sharedRegistry
        entryForIdentifier:entry.identifier];
    if (existing) {
        NSString *existingImage = [existing.locator[@"image"]
            isKindOfClass:NSString.class] ? existing.locator[@"image"] : @"";
        if (!existingImage.length ||
            [FLEXRuntimeCanonicalPath(existingImage)
                isEqualToString:FLEXRuntimeCanonicalPath(image.path)]) {
            return existing;
        }
    }
    return entry;
}

static NSArray<NSString *> *FLEXRuntimeLiveClassNames(
    FLEXRuntimeImageDescriptor *image,
    BOOL (^cancelled)(void)
) {
    if (!image || !image.headerAddress) return @[];
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)image.headerAddress;
    if (!header || header->magic != MH_MAGIC_64) return @[];

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    objc_enumerateClasses(
        (const void *)header,
        NULL,
        NULL,
        Nil,
        ^(Class targetClass, BOOL *stop) {
            if (cancelled && cancelled()) {
                *stop = YES;
                return;
            }
            const char *rawName = class_getName(targetClass);
            if (!rawName || rawName[0] == '\0') return;
            NSString *name = [NSString stringWithUTF8String:rawName];
            if (name.length) [names addObject:name];
        }
    );
    [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return names.copy;
}

static NSString *FLEXRuntimeNormalizedText(NSString *source) {
    if (!source.length) return @"";
    NSMutableString *spaced = [NSMutableString stringWithCapacity:source.length + 8];
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSCharacterSet *upper = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;

    for (NSUInteger index = 0; index < source.length; index++) {
        unichar current = [source characterAtIndex:index];
        BOOL alphanumeric = [letters characterIsMember:current] ||
                            [digits characterIsMember:current];
        if (!alphanumeric) {
            if (spaced.length &&
                [spaced characterAtIndex:spaced.length - 1] != ' ') {
                [spaced appendString:@" "];
            }
            continue;
        }
        if ([upper characterIsMember:current] && index > 0 && spaced.length &&
            [spaced characterAtIndex:spaced.length - 1] != ' ') {
            unichar previous = [source characterAtIndex:index - 1];
            BOOL boundary = [lower characterIsMember:previous] ||
                            [digits characterIsMember:previous];
            if (!boundary && index + 1 < source.length) {
                unichar next = [source characterAtIndex:index + 1];
                boundary = [upper characterIsMember:previous] &&
                           [lower characterIsMember:next];
            }
            if (boundary) [spaced appendString:@" "];
        }
        [spaced appendFormat:@"%C", current];
    }

    NSString *folded = [spaced stringByFoldingWithOptions:
        (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch |
         NSWidthInsensitiveSearch)
        locale:NSLocale.currentLocale];
    NSArray<NSString *> *parts = [folded.lowercaseString
        componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) [tokens addObject:part];
    }
    return [tokens componentsJoinedByString:@" "];
}

static NSArray<NSString *> *FLEXRuntimeQueryTokens(NSString *query) {
    NSString *normalized = FLEXRuntimeNormalizedText(query);
    return normalized.length
        ? [normalized componentsSeparatedByString:@" "] : @[];
}

static BOOL FLEXRuntimeValuesMatchTokens(NSArray<NSString *> *tokens,
                                         NSArray<NSString *> *values) {
    if (!tokens.count) return YES;
    NSMutableArray<NSString *> *normalizedValues =
        [NSMutableArray arrayWithCapacity:values.count];
    for (NSString *value in values) {
        NSString *normalized = FLEXRuntimeNormalizedText(value ?: @"");
        if (normalized.length) [normalizedValues addObject:normalized];
    }
    for (NSString *token in tokens) {
        BOOL matched = NO;
        for (NSString *candidate in normalizedValues) {
            if ([candidate containsString:token]) {
                matched = YES;
                break;
            }
        }
        if (!matched) return NO;
    }
    return YES;
}

typedef NS_ENUM(NSInteger, FLEXRuntimeSearchHitKind) {
    FLEXRuntimeSearchHitKindClass = 0,
    FLEXRuntimeSearchHitKindMethod,
    FLEXRuntimeSearchHitKindProperty,
};

@interface FLEXRuntimePropertyRecord : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *attributes;
@property (nonatomic) BOOL classProperty;
@end
@implementation FLEXRuntimePropertyRecord
@end

@interface FLEXRuntimeSearchHit : NSObject
@property (nonatomic) FLEXRuntimeSearchHitKind kind;
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic) FLEXHookEntry *entry;
@property (nonatomic) FLEXRuntimePropertyRecord *property;
@end
@implementation FLEXRuntimeSearchHit
@end

@interface FLEXRuntimeSearchGroup : NSObject
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSArray<FLEXRuntimeSearchHit *> *hits;
@end
@implementation FLEXRuntimeSearchGroup
@end

@interface FLEXRuntimeGlassHeaderView : UITableViewHeaderFooterView
@property (nonatomic) UIView *panel;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *detailLabel;
- (void)configureTitle:(NSString *)title detail:(NSString *)detail;
@end

@implementation FLEXRuntimeGlassHeaderView

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (!self) return nil;

    self.contentView.backgroundColor = UIColor.clearColor;
    _panel = [UIView new];
    _panel.translatesAutoresizingMaskIntoConstraints = NO;
    [FLEXLiquidGlass stylePanelView:_panel interactive:NO radius:16.0];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _titleLabel.numberOfLines = 0;
    _detailLabel = [UILabel new];
    _detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _detailLabel.textColor = UIColor.secondaryLabelColor;
    _detailLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[_titleLabel, _detailLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    [self.contentView addSubview:_panel];
    [_panel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [_panel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                             constant:4.0],
        [_panel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                              constant:-4.0],
        [_panel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                         constant:3.0],
        [_panel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                            constant:-3.0],
        [stack.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor
                                            constant:12.0],
        [stack.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor
                                             constant:-12.0],
        [stack.topAnchor constraintEqualToAnchor:_panel.topAnchor
                                        constant:8.0],
        [stack.bottomAnchor constraintEqualToAnchor:_panel.bottomAnchor
                                           constant:-8.0],
    ]];
    return self;
}

- (void)configureTitle:(NSString *)title detail:(NSString *)detail {
    self.titleLabel.text = title;
    self.detailLabel.text = detail;
    self.detailLabel.hidden = !detail.length;
    [FLEXLiquidGlass stylePanelView:self.panel interactive:NO radius:16.0];
}

@end

static NSArray<FLEXHookEntry *> *FLEXRuntimeMethodsForClass(
    NSString *className,
    BOOL classMethods,
    FLEXRuntimeImageDescriptor *image
) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass || !FLEXRuntimeClassBelongsToImage(targetClass, image)) {
        return @[];
    }
    Class owner = classMethods ? object_getClass(targetClass) : targetClass;
    if (!owner) return @[];

    unsigned int count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    NSMutableArray<FLEXHookEntry *> *entries =
        [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        FLEXHookEntry *entry = FLEXRuntimeEntryForMethod(
            targetClass, methods[index], classMethods, image);
        if (entry) [entries addObject:entry];
    }
    if (methods) free(methods);
    [entries sortUsingComparator:^NSComparisonResult(
        FLEXHookEntry *left,
        FLEXHookEntry *right
    ) {
        NSString *l = [left.locator[@"selector"] isKindOfClass:NSString.class]
            ? left.locator[@"selector"] : left.title;
        NSString *r = [right.locator[@"selector"] isKindOfClass:NSString.class]
            ? right.locator[@"selector"] : right.title;
        return [l localizedCaseInsensitiveCompare:r];
    }];
    return entries.copy;
}

static NSArray<FLEXRuntimePropertyRecord *> *FLEXRuntimePropertiesForClass(
    NSString *className,
    BOOL classProperties,
    FLEXRuntimeImageDescriptor *image
) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass || !FLEXRuntimeClassBelongsToImage(targetClass, image)) {
        return @[];
    }
    Class owner = classProperties ? object_getClass(targetClass) : targetClass;
    if (!owner) return @[];

    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(owner, &count);
    NSMutableArray<FLEXRuntimePropertyRecord *> *records =
        [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        const char *rawName = property_getName(properties[index]);
        const char *rawAttributes = property_getAttributes(properties[index]);
        if (!rawName) continue;
        FLEXRuntimePropertyRecord *record = [FLEXRuntimePropertyRecord new];
        record.name = [NSString stringWithUTF8String:rawName];
        record.attributes = rawAttributes
            ? [NSString stringWithUTF8String:rawAttributes] : @"";
        record.classProperty = classProperties;
        [records addObject:record];
    }
    if (properties) free(properties);
    [records sortUsingComparator:^NSComparisonResult(
        FLEXRuntimePropertyRecord *left,
        FLEXRuntimePropertyRecord *right
    ) {
        return [left.name localizedCaseInsensitiveCompare:right.name];
    }];
    return records.copy;
}

static void FLEXRuntimeApplyGlassSurface(UIViewController *controller,
                                         UITableView *tableView,
                                         UISearchBar *searchBar) {
    [FLEXLiquidGlass applyToViewController:controller];
    [FLEXLiquidGlass styleSearchBar:searchBar];
    FLEXConfigureCompactRuntimeTable(tableView);
    if (FLEXLiquidGlass.isGlassAvailable && FLEXLiquidGlass.isEnabled) {
        controller.view.backgroundColor = UIColor.systemBackgroundColor;
        tableView.backgroundColor = UIColor.clearColor;
        tableView.opaque = NO;
        tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    }
}

@interface FLEXRuntimeClassDetailController : UITableViewController
    <UISearchResultsUpdating>
@property (nonatomic, copy) NSString *className;
@property (nonatomic) FLEXRuntimeImageDescriptor *image;
@property (nonatomic) UISearchController *memberSearchController;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *instanceMethods;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *classMethods;
@property (nonatomic, copy) NSArray<FLEXRuntimePropertyRecord *> *instanceProperties;
@property (nonatomic, copy) NSArray<FLEXRuntimePropertyRecord *> *classProperties;
@property (nonatomic, copy) NSArray *visibleSections;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL loading;
@end

@implementation FLEXRuntimeClassDetailController

- (instancetype)initWithClassName:(NSString *)className
                            image:(FLEXRuntimeImageDescriptor *)image {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _className = className.copy;
        _image = [image copy];
        _instanceMethods = @[];
        _classMethods = @[];
        _instanceProperties = @[];
        _classProperties = @[];
        _visibleSections = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.className;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:FLEXRuntimeGlassHeaderView.class
           forHeaderFooterViewReuseIdentifier:@"FLEXRuntimeGlassHeader"];
    self.tableView.estimatedRowHeight = 62.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    self.memberSearchController = [[UISearchController alloc]
        initWithSearchResultsController:nil];
    self.memberSearchController.obscuresBackgroundDuringPresentation = NO;
    self.memberSearchController.searchResultsUpdater = self;
    self.memberSearchController.searchBar.placeholder = @"Filter live members";
    self.navigationItem.searchController = self.memberSearchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadLiveMembers)];
    if (@available(iOS 26.0, *)) {
        self.navigationItem.subtitle = self.image.displayName;
    }
    FLEXRuntimeApplyGlassSurface(
        self, self.tableView, self.memberSearchController.searchBar);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    FLEXRuntimeApplyGlassSurface(
        self, self.tableView, self.memberSearchController.searchBar);
    [self reloadLiveMembers];
}

- (void)reloadLiveMembers {
    NSUInteger generation = ++self.generation;
    self.loading = YES;
    NSString *className = self.className.copy;
    FLEXRuntimeImageDescriptor *image = [self.image copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(FLEXRuntimeBrowserWorkQueue(), ^{
        NSArray *instanceMethods = FLEXRuntimeMethodsForClass(className, NO, image);
        NSArray *classMethods = FLEXRuntimeMethodsForClass(className, YES, image);
        NSArray *instanceProperties = FLEXRuntimePropertiesForClass(className, NO, image);
        NSArray *classProperties = FLEXRuntimePropertiesForClass(className, YES, image);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.generation) return;
            self.instanceMethods = instanceMethods;
            self.classMethods = classMethods;
            self.instanceProperties = instanceProperties;
            self.classProperties = classProperties;
            self.loading = NO;
            [self rebuildVisibleSections];
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    [self rebuildVisibleSections];
}

- (BOOL)object:(id)object matchesTokens:(NSArray<NSString *> *)tokens {
    if (!tokens.count) return YES;
    if ([object isKindOfClass:FLEXHookEntry.class]) {
        FLEXHookEntry *entry = object;
        NSString *selector = [entry.locator[@"selector"] isKindOfClass:NSString.class]
            ? entry.locator[@"selector"] : entry.title;
        NSString *encoding = [entry.locator[@"encoding"] isKindOfClass:NSString.class]
            ? entry.locator[@"encoding"] : entry.detail;
        return FLEXRuntimeValuesMatchTokens(tokens, @[
            self.className ?: @"", selector ?: @"", encoding ?: @""]);
    }
    if ([object isKindOfClass:FLEXRuntimePropertyRecord.class]) {
        FLEXRuntimePropertyRecord *property = object;
        return FLEXRuntimeValuesMatchTokens(tokens, @[
            self.className ?: @",", property.name ?: @"",
            property.attributes ?: @""]);
    }
    return NO;
}

- (NSArray *)filteredArray:(NSArray *)source tokens:(NSArray<NSString *> *)tokens {
    if (!tokens.count) return source ?: @[];
    NSMutableArray *filtered = [NSMutableArray array];
    for (id object in source ?: @[]) {
        if ([self object:object matchesTokens:tokens]) [filtered addObject:object];
    }
    return filtered.copy;
}

- (void)rebuildVisibleSections {
    NSArray<NSString *> *tokens = FLEXRuntimeQueryTokens(
        self.memberSearchController.searchBar.text ?: @"");
    NSArray *instanceMethods = [self filteredArray:self.instanceMethods tokens:tokens];
    NSArray *classMethods = [self filteredArray:self.classMethods tokens:tokens];
    NSArray *instanceProperties = [self filteredArray:self.instanceProperties tokens:tokens];
    NSArray *classProperties = [self filteredArray:self.classProperties tokens:tokens];

    NSMutableArray *sections = [NSMutableArray array];
    if (instanceMethods.count) {
        [sections addObject:@{
            @"title": @"Instance methods",
            @"detail": [NSString stringWithFormat:@"%lu live method%@",
                (unsigned long)instanceMethods.count,
                instanceMethods.count == 1 ? @"" : @"s"],
            @"kind": @"method",
            @"items": instanceMethods,
        }];
    }
    if (classMethods.count) {
        [sections addObject:@{
            @"title": @"Class methods",
            @"detail": [NSString stringWithFormat:@"%lu live method%@",
                (unsigned long)classMethods.count,
                classMethods.count == 1 ? @"" : @"s"],
            @"kind": @"method",
            @"items": classMethods,
        }];
    }
    if (instanceProperties.count) {
        [sections addObject:@{
            @"title": @"Properties",
            @"detail": [NSString stringWithFormat:@"%lu runtime propert%@",
                (unsigned long)instanceProperties.count,
                instanceProperties.count == 1 ? @"y" : @"ies"],
            @"kind": @"property",
            @"items": instanceProperties,
        }];
    }
    if (classProperties.count) {
        [sections addObject:@{
            @"title": @"Class properties",
            @"detail": [NSString stringWithFormat:@"%lu runtime propert%@",
                (unsigned long)classProperties.count,
                classProperties.count == 1 ? @"y" : @"ies"],
            @"kind": @"property",
            @"items": classProperties,
        }];
    }
    self.visibleSections = sections.copy;
    [self.tableView reloadData];
    [self updateUnavailableConfiguration];
}

- (void)updateUnavailableConfiguration {
    if (@available(iOS 17.0, *)) {
        if (self.visibleSections.count) {
            self.contentUnavailableConfiguration = nil;
            return;
        }
        if (self.loading) {
            UIContentUnavailableConfiguration *configuration =
                [UIContentUnavailableConfiguration loadingConfiguration];
            configuration.text = @"Reading live class members";
            configuration.secondaryText =
                @"Methods and properties are enumerated from the Objective-C runtime now; nothing is preclassified.";
            self.contentUnavailableConfiguration = configuration;
            return;
        }
        UIContentUnavailableConfiguration *configuration =
            self.memberSearchController.searchBar.text.length
                ? [UIContentUnavailableConfiguration searchConfiguration]
                : [UIContentUnavailableConfiguration emptyConfiguration];
        configuration.text = self.memberSearchController.searchBar.text.length
            ? @"No live member matches" : @"No runtime members";
        self.contentUnavailableConfiguration = configuration;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.visibleSections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.visibleSections.count) return 0;
    return [self.visibleSections[(NSUInteger)section][@"items"] count];
}

- (UIView *)tableView:(UITableView *)tableView
 viewForHeaderInSection:(NSInteger)section {
    FLEXRuntimeGlassHeaderView *header = [tableView
        dequeueReusableHeaderFooterViewWithIdentifier:@"FLEXRuntimeGlassHeader"];
    NSDictionary *descriptor = self.visibleSections[(NSUInteger)section];
    [header configureTitle:descriptor[@"title"] detail:descriptor[@"detail"]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView
 heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"FLEXLiveClassMemberCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }
    NSDictionary *section = self.visibleSections[indexPath.section];
    NSArray *items = section[@"items"];
    NSString *kind = section[@"kind"];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if ([kind isEqualToString:@"method"]) {
        FLEXHookEntry *entry = items[indexPath.row];
        NSString *selector = [entry.locator[@"selector"] isKindOfClass:NSString.class]
            ? entry.locator[@"selector"] : FLEXRuntimeMemberTitleForEntry(entry);
        BOOL classMethod = [entry.locator[@"classMethod"] boolValue];
        FLEXConfigureCompactRuntimeContent(
            cell,
            [NSString stringWithFormat:@"%@ %@",
                classMethod ? @"+" : @"-", selector],
            entry.detail,
            entry.hookable ? @"switch.2" : @"function",
            entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor
        );
        if (entry.hookable || entry.pendingEnabled) {
            UISwitch *toggle = [UISwitch new];
            toggle.on = entry.pendingEnabled;
            objc_setAssociatedObject(
                toggle,
                kFLEXRuntimeBrowserEntryKey,
                entry,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
            [toggle addTarget:self
                       action:@selector(toggleChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        } else {
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    } else {
        FLEXRuntimePropertyRecord *property = items[indexPath.row];
        FLEXConfigureCompactRuntimeContent(
            cell,
            property.name,
            property.attributes.length ? property.attributes : @"Runtime property",
            @"p.square",
            UIColor.secondaryLabelColor
        );
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    FLEXStyleCompactRuntimeCell(
        cell,
        FLEXCompactPositionForRow(indexPath.row, items.count)
    );
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *section = self.visibleSections[indexPath.section];
    NSArray *items = section[@"items"];
    if ([section[@"kind"] isEqualToString:@"method"]) {
        FLEXHookEntry *entry = items[indexPath.row];
        FLEXHookEntry *canonical = [FLEXHookRegistry.sharedRegistry
            upsertDiscoveredEntry:entry];
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc]
                initWithEntry:canonical ?: entry];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }
    FLEXRuntimePropertyRecord *property = items[indexPath.row];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:property.name
                         message:property.attributes.length
                            ? property.attributes : @"No runtime attributes"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Done"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleChanged:(UISwitch *)toggle {
    FLEXHookEntry *discovered = objc_getAssociatedObject(
        toggle, kFLEXRuntimeBrowserEntryKey);
    if (!discovered) return;
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    FLEXHookEntry *entry = [registry upsertDiscoveredEntry:discovered];
    BOOL requested = toggle.isOn;
    if (requested && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:entry.identifier];
    }
    [registry stageEnabled:requested forEntryIdentifier:entry.identifier];
    FLEXHookEntry *resolved = [registry entryForIdentifier:entry.identifier];
    BOOL accepted = resolved && resolved.pendingEnabled == requested;
    [toggle setOn:accepted ? requested : !requested animated:YES];
    [accepted ? UISelectionFeedbackGenerator.new : UINotificationFeedbackGenerator.new
        respondsToSelector:@selector(selectionChanged)];
    if (accepted) {
        [UISelectionFeedbackGenerator.new selectionChanged];
    } else {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
    }
    // Intentionally stage only. The Hook Center remains the single explicit
    // Apply owner, so browsing the live runtime never mutates code on toggle.
}

@end

@interface FLEXRuntimeBrowserController () <UISearchResultsUpdating>
@property (nonatomic) FLEXRuntimeBrowserKind kind;
@property (nonatomic) BOOL scanning;
@property (nonatomic) BOOL searching;
@property (nonatomic) BOOL initialLoadStarted;
@property (nonatomic) UISearchController *searchController;
@property (nonatomic) FLEXRuntimeImageDescriptor *selectedImage;
@property (nonatomic) FLEXRuntimeImageSession *session;
@property (nonatomic, copy) NSArray<NSString *> *liveClassNames;
@property (nonatomic, copy) NSArray<FLEXRuntimeSearchGroup *> *searchGroups;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *cEntries;
@property (nonatomic, copy) NSArray<FLEXRuntimeEntryGroup *> *cGroups;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) UIBarButtonItem *scopeItem;
@property (nonatomic) UIBarButtonItem *reloadItem;
@property (nonatomic) UIBarButtonItem *spinnerItem;
@property (nonatomic) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSString *statusText;
@end

@implementation FLEXRuntimeBrowserController

- (instancetype)initWithKind:(FLEXRuntimeBrowserKind)kind {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _kind = kind;
        _liveClassNames = @[];
        _searchGroups = @[];
        _cEntries = @[];
        _cGroups = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.kind == FLEXRuntimeBrowserKindObjectiveC
        ? @"Objective-C Runtime" : @"C Runtime";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [self.tableView registerClass:FLEXRuntimeGlassHeaderView.class
           forHeaderFooterViewReuseIdentifier:@"FLEXRuntimeGlassHeader"];
    self.tableView.estimatedRowHeight = 64.0;
    self.tableView.rowHeight = UITableViewAutomaticDimension;

    self.searchController = [[UISearchController alloc]
        initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = self.kind == FLEXRuntimeBrowserKindObjectiveC
        ? @"Search live classes, methods and properties"
        : @"Filter live Mach-O symbols";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];

    self.reloadItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadLiveRuntime)];
    self.scopeItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Image"
                 menu:[self scopeMenu]];
    self.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinnerItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
    [self installNavigationItems];

    self.selectedImage = FLEXRuntimeImageSession.loadedAppImages.firstObject;
    [self updateScopeItem];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(runtimeImagesChanged:)
               name:FLEXRuntimeImagesDidChangeNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];

    FLEXRuntimeApplyGlassSurface(
        self, self.tableView, self.searchController.searchBar);
    [self updateUnavailableConfigurationWithError:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    FLEXRuntimeApplyGlassSurface(
        self, self.tableView, self.searchController.searchBar);
    if (self.initialLoadStarted && self.selectedImage && !self.scanning) {
        [self reloadLiveRuntime];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.initialLoadStarted || !self.selectedImage) return;
    self.initialLoadStarted = YES;
    [self reloadLiveRuntime];
}

- (void)dealloc {
    [self.session cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)installNavigationItems {
    self.navigationItem.rightBarButtonItems = self.scanning || self.searching
        ? @[self.spinnerItem, self.reloadItem, self.scopeItem]
        : @[self.reloadItem, self.scopeItem];
    self.reloadItem.enabled = !self.scanning;
    self.scopeItem.enabled = YES;
}

- (void)setBusy:(BOOL)busy searching:(BOOL)searching {
    self.scanning = busy;
    self.searching = searching;
    if (busy || searching) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
    [self installNavigationItems];
}

- (void)updateScopeItem {
    self.scopeItem.title = self.selectedImage.displayName ?: @"Image";
    self.scopeItem.menu = [self scopeMenu];
}

- (UIMenu *)scopeMenu {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (FLEXRuntimeImageDescriptor *image in
         FLEXRuntimeImageSession.loadedAppImages) {
        NSString *subtitle = image.mainExecutable
            ? @"Main executable"
            : [image.path stringByAbbreviatingWithTildeInPath];
        UIAction *action = [UIAction actionWithTitle:image.displayName
                                           subtitle:subtitle
                                              image:[UIImage systemImageNamed:
                                                  image.mainExecutable
                                                    ? @"terminal"
                                                    : @"shippingbox"]
                                         identifier:nil
                                            handler:^(__unused UIAction *menuAction) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if ([self.selectedImage.path isEqualToString:image.path] &&
                [self.selectedImage.uuid isEqualToString:image.uuid]) {
                return;
            }
            self.selectedImage = [image copy];
            [self updateScopeItem];
            [self reloadLiveRuntime];
        }];
        action.state = [self.selectedImage.path isEqualToString:image.path]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    if (!actions.count) {
        UIAction *empty = [UIAction actionWithTitle:@"No app image is loaded"
                                             image:[UIImage systemImageNamed:
                                                 @"exclamationmark.triangle"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {}];
        empty.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:empty];
    }
    return [UIMenu menuWithTitle:@"Live runtime image"
                           image:nil
                      identifier:nil
                         options:UIMenuOptionsDisplayInline
                        children:actions];
}

- (void)runtimeImagesChanged:(NSNotification *)notification {
    (void)notification;
    NSArray<FLEXRuntimeImageDescriptor *> *images =
        FLEXRuntimeImageSession.loadedAppImages;
    FLEXRuntimeImageDescriptor *matching = nil;
    for (FLEXRuntimeImageDescriptor *image in images) {
        if ([image.path isEqualToString:self.selectedImage.path]) {
            matching = image;
            break;
        }
    }
    self.selectedImage = matching ?: images.firstObject;
    [self updateScopeItem];
    if (self.viewIfLoaded.window && self.selectedImage) {
        [self reloadLiveRuntime];
    }
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    if (self.kind == FLEXRuntimeBrowserKindC && self.cEntries.count) {
        NSMutableArray *updated = [NSMutableArray arrayWithCapacity:self.cEntries.count];
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        for (FLEXHookEntry *entry in self.cEntries) {
            [updated addObject:[registry entryForIdentifier:entry.identifier] ?: entry];
        }
        self.cEntries = updated.copy;
        [self filterCEntriesForQuery:self.searchController.searchBar.text ?: @""];
    } else {
        [self.tableView reloadData];
    }
}

- (void)reloadLiveRuntime {
    if (!self.selectedImage || self.scanning) return;
    [self.session cancel];
    NSUInteger generation = ++self.generation;
    self.statusText = self.kind == FLEXRuntimeBrowserKindObjectiveC
        ? @"Reading live classes"
        : @"Reading current Mach-O image";
    [self setBusy:YES searching:NO];
    [self updateNavigationStatus];

    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        FLEXRuntimeImageDescriptor *image = [self.selectedImage copy];
        __weak typeof(self) weakSelf = self;
        dispatch_async(FLEXRuntimeBrowserWorkQueue(), ^{
            NSArray<NSString *> *names = FLEXRuntimeLiveClassNames(
                image,
                ^BOOL{
                    __strong typeof(weakSelf) self = weakSelf;
                    return !self || generation != self.generation;
                }
            );
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.generation) return;
                self.liveClassNames = names;
                self.searchGroups = @[];
                [self setBusy:NO searching:NO];
                [self.tableView reloadData];
                [self updateNavigationStatus];
                [self updateUnavailableConfigurationWithError:nil];
                if (self.searchController.searchBar.text.length) {
                    [self scheduleObjectiveCSearch:
                        self.searchController.searchBar.text immediate:YES];
                }
            });
        });
        return;
    }

    self.session = [[FLEXRuntimeImageSession alloc]
        initWithImage:self.selectedImage];
    __weak typeof(self) weakSelf = self;
    [self.session scanKind:FLEXRuntimeBrowserKindC
                  progress:^(NSString *phase, NSUInteger completed, NSUInteger total) {
        (void)completed;
        (void)total;
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.generation) return;
        self.statusText = phase ?: @"Reading current Mach-O image";
        [self updateNavigationStatus];
    } completion:^(FLEXRuntimeImageSnapshot *snapshot, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.generation) return;
        [self setBusy:NO searching:NO];
        if (!snapshot || error) {
            self.cEntries = @[];
            self.cGroups = @[];
            [self.tableView reloadData];
            [self updateNavigationStatus];
            [self updateUnavailableConfigurationWithError:error];
            return;
        }
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        NSMutableArray *entries = [NSMutableArray arrayWithCapacity:snapshot.entries.count];
        for (FLEXHookEntry *entry in snapshot.entries) {
            [entries addObject:[registry entryForIdentifier:entry.identifier] ?: entry];
        }
        self.cEntries = entries.copy;
        [self filterCEntriesForQuery:self.searchController.searchBar.text ?: @""];
    }];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text ?: @"";
    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        [self scheduleObjectiveCSearch:text immediate:NO];
    } else {
        [self scheduleCSearch:text];
    }
}

- (void)scheduleObjectiveCSearch:(NSString *)text immediate:(BOOL)immediate {
    NSString *query = text.copy ?: @"";
    if (!query.length) {
        ++self.generation;
        self.searchGroups = @[];
        [self setBusy:NO searching:NO];
        [self.tableView reloadData];
        [self updateNavigationStatus];
        [self updateUnavailableConfigurationWithError:nil];
        return;
    }

    NSUInteger generation = ++self.generation;
    FLEXRuntimeImageDescriptor *image = [self.selectedImage copy];
    NSArray<NSString *> *classNames = self.liveClassNames.copy;
    NSArray<NSString *> *tokens = FLEXRuntimeQueryTokens(query);
    NSTimeInterval delay = immediate ? 0.0 : 0.14;
    [self setBusy:NO searching:YES];
    self.statusText = @"Searching live Objective-C runtime";
    [self updateNavigationStatus];
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        FLEXRuntimeBrowserWorkQueue(),
        ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.generation) return;
            NSMutableArray<FLEXRuntimeSearchGroup *> *groups = [NSMutableArray array];

            for (NSString *className in classNames) {
                if (generation != strongSelf.generation) return;
                @autoreleasepool {
                    NSMutableArray<FLEXRuntimeSearchHit *> *hits = [NSMutableArray array];
                    BOOL classMatches = FLEXRuntimeValuesMatchTokens(
                        tokens, @[className]);
                    if (classMatches) {
                        FLEXRuntimeSearchHit *hit = [FLEXRuntimeSearchHit new];
                        hit.kind = FLEXRuntimeSearchHitKindClass;
                        hit.className = className;
                        hit.title = className;
                        hit.detail = @"Live Objective-C class";
                        [hits addObject:hit];
                    }

                    Class targetClass = NSClassFromString(className);
                    if (!targetClass ||
                        !FLEXRuntimeClassBelongsToImage(targetClass, image)) {
                        continue;
                    }

                    for (NSUInteger pass = 0; pass < 2; pass++) {
                        BOOL classMethod = pass == 1;
                        Class owner = classMethod
                            ? object_getClass(targetClass) : targetClass;
                        if (!owner) continue;
                        unsigned int methodCount = 0;
                        Method *methods = class_copyMethodList(owner, &methodCount);
                        for (unsigned int methodIndex = 0;
                             methodIndex < methodCount;
                             methodIndex++) {
                            if (generation != strongSelf.generation) {
                                if (methods) free(methods);
                                return;
                            }
                            Method method = methods[methodIndex];
                            SEL selector = method_getName(method);
                            const char *rawSelector = selector
                                ? sel_getName(selector) : NULL;
                            if (!rawSelector) continue;
                            NSString *selectorName =
                                [NSString stringWithUTF8String:rawSelector];
                            const char *rawEncoding = method_getTypeEncoding(method);
                            NSString *encoding = rawEncoding
                                ? [NSString stringWithUTF8String:rawEncoding] : @"";
                            if (!FLEXRuntimeValuesMatchTokens(tokens, @[
                                    className, selectorName ?: @"", encoding ?: @""])) {
                                continue;
                            }
                            FLEXHookEntry *entry = FLEXRuntimeEntryForMethod(
                                targetClass, method, classMethod, image);
                            if (!entry) continue;
                            FLEXRuntimeSearchHit *hit = [FLEXRuntimeSearchHit new];
                            hit.kind = FLEXRuntimeSearchHitKindMethod;
                            hit.className = className;
                            hit.entry = entry;
                            hit.title = FLEXRuntimeMemberTitleForEntry(entry);
                            hit.detail = entry.detail;
                            [hits addObject:hit];
                        }
                        if (methods) free(methods);
                    }

                    for (NSUInteger pass = 0; pass < 2; pass++) {
                        BOOL classProperty = pass == 1;
                        Class owner = classProperty
                            ? object_getClass(targetClass) : targetClass;
                        if (!owner) continue;
                        unsigned int propertyCount = 0;
                        objc_property_t *properties =
                            class_copyPropertyList(owner, &propertyCount);
                        for (unsigned int propertyIndex = 0;
                             propertyIndex < propertyCount;
                             propertyIndex++) {
                            if (generation != strongSelf.generation) {
                                if (properties) free(properties);
                                return;
                            }
                            const char *rawName = property_getName(properties[propertyIndex]);
                            const char *rawAttributes =
                                property_getAttributes(properties[propertyIndex]);
                            if (!rawName) continue;
                            NSString *name = [NSString stringWithUTF8String:rawName];
                            NSString *attributes = rawAttributes
                                ? [NSString stringWithUTF8String:rawAttributes] : @"";
                            if (!FLEXRuntimeValuesMatchTokens(tokens, @[
                                    className, name ?: @"", attributes ?: @""])) {
                                continue;
                            }
                            FLEXRuntimePropertyRecord *property =
                                [FLEXRuntimePropertyRecord new];
                            property.name = name;
                            property.attributes = attributes;
                            property.classProperty = classProperty;
                            FLEXRuntimeSearchHit *hit = [FLEXRuntimeSearchHit new];
                            hit.kind = FLEXRuntimeSearchHitKindProperty;
                            hit.className = className;
                            hit.property = property;
                            hit.title = [NSString stringWithFormat:@"%@ %@",
                                classProperty ? @"+" : @"@property", name];
                            hit.detail = attributes;
                            [hits addObject:hit];
                        }
                        if (properties) free(properties);
                    }

                    if (hits.count) {
                        FLEXRuntimeSearchGroup *group = [FLEXRuntimeSearchGroup new];
                        group.className = className;
                        group.hits = hits.copy;
                        [groups addObject:group];
                    }
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.generation) return;
                self.searchGroups = groups.copy;
                [self setBusy:NO searching:NO];
                [self.tableView reloadData];
                [self updateNavigationStatus];
                [self updateUnavailableConfigurationWithError:nil];
            });
        }
    );
}

- (void)scheduleCSearch:(NSString *)text {
    NSString *query = text.copy ?: @"";
    NSUInteger generation = ++self.generation;
    NSArray<FLEXHookEntry *> *entries = self.cEntries.copy;
    NSArray<NSString *> *tokens = FLEXRuntimeQueryTokens(query);
    [self setBusy:NO searching:query.length > 0];
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
        FLEXRuntimeBrowserWorkQueue(),
        ^{
            NSMutableArray<FLEXHookEntry *> *filtered = [NSMutableArray array];
            for (FLEXHookEntry *entry in entries) {
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.generation) return;
                NSString *symbol = [entry.locator[@"symbol"] isKindOfClass:NSString.class]
                    ? entry.locator[@"symbol"] : entry.title;
                if (FLEXRuntimeValuesMatchTokens(tokens, @[
                        symbol ?: @"", entry.detail ?: @"", entry.imageName ?: @""])) {
                    [filtered addObject:entry];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.generation) return;
                self.cGroups = FLEXRuntimeGroupEntries(filtered);
                [self setBusy:NO searching:NO];
                [self.tableView reloadData];
                [self updateNavigationStatus];
                [self updateUnavailableConfigurationWithError:nil];
            });
        }
    );
}

- (void)filterCEntriesForQuery:(NSString *)query {
    NSArray<NSString *> *tokens = FLEXRuntimeQueryTokens(query ?: @"");
    NSMutableArray<FLEXHookEntry *> *filtered = [NSMutableArray array];
    for (FLEXHookEntry *entry in self.cEntries) {
        NSString *symbol = [entry.locator[@"symbol"] isKindOfClass:NSString.class]
            ? entry.locator[@"symbol"] : entry.title;
        if (FLEXRuntimeValuesMatchTokens(tokens, @[
                symbol ?: @"", entry.detail ?: @"", entry.imageName ?: @""])) {
            [filtered addObject:entry];
        }
    }
    self.cGroups = FLEXRuntimeGroupEntries(filtered);
    [self.tableView reloadData];
    [self updateNavigationStatus];
    [self updateUnavailableConfigurationWithError:nil];
}

- (BOOL)objectiveCSearchActive {
    return self.kind == FLEXRuntimeBrowserKindObjectiveC &&
        self.searchController.searchBar.text.length > 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        return self.objectiveCSearchActive ? self.searchGroups.count
            : (self.liveClassNames.count ? 1 : 0);
    }
    return self.cGroups.count;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        if (!self.objectiveCSearchActive) return self.liveClassNames.count;
        if (section < 0 || section >= (NSInteger)self.searchGroups.count) return 0;
        return self.searchGroups[(NSUInteger)section].hits.count;
    }
    if (section < 0 || section >= (NSInteger)self.cGroups.count) return 0;
    return self.cGroups[(NSUInteger)section].entries.count;
}

- (UIView *)tableView:(UITableView *)tableView
 viewForHeaderInSection:(NSInteger)section {
    FLEXRuntimeGlassHeaderView *header = [tableView
        dequeueReusableHeaderFooterViewWithIdentifier:@"FLEXRuntimeGlassHeader"];
    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        if (self.objectiveCSearchActive) {
            FLEXRuntimeSearchGroup *group = self.searchGroups[(NSUInteger)section];
            [header configureTitle:group.className
                            detail:[NSString stringWithFormat:@"%lu live match%@",
                (unsigned long)group.hits.count,
                group.hits.count == 1 ? @"" : @"es"]];
        } else {
            [header configureTitle:@"Classes"
                            detail:[NSString stringWithFormat:@"%lu loaded in %@",
                (unsigned long)self.liveClassNames.count,
                self.selectedImage.displayName ?: @"selected image"]];
        }
        return header;
    }
    FLEXRuntimeEntryGroup *group = self.cGroups[(NSUInteger)section];
    [header configureTitle:group.title
                    detail:[NSString stringWithFormat:@"%lu live symbol%@",
        (unsigned long)group.entries.count,
        group.entries.count == 1 ? @"" : @"s"]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView
 heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"FLEXLiveRuntimeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
          reuseIdentifier:identifier];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        if (!self.objectiveCSearchActive) {
            NSString *className = self.liveClassNames[indexPath.row];
            FLEXConfigureCompactRuntimeContent(
                cell,
                className,
                @"Live Objective-C class · tap to enumerate current methods and properties",
                @"curlybraces.square",
                self.view.tintColor
            );
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            FLEXStyleCompactRuntimeCell(
                cell,
                FLEXCompactPositionForRow(indexPath.row, self.liveClassNames.count)
            );
            return cell;
        }

        FLEXRuntimeSearchGroup *group = self.searchGroups[indexPath.section];
        FLEXRuntimeSearchHit *hit = group.hits[indexPath.row];
        if (hit.kind == FLEXRuntimeSearchHitKindClass) {
            FLEXConfigureCompactRuntimeContent(
                cell, hit.title, hit.detail,
                @"curlybraces.square", self.view.tintColor);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (hit.kind == FLEXRuntimeSearchHitKindProperty) {
            FLEXConfigureCompactRuntimeContent(
                cell, hit.title, hit.detail,
                @"p.square", UIColor.secondaryLabelColor);
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            FLEXHookEntry *entry = hit.entry;
            FLEXConfigureCompactRuntimeContent(
                cell,
                FLEXRuntimeMemberTitleForEntry(entry),
                entry.detail,
                entry.hookable ? @"switch.2" : @"function",
                entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor
            );
            if (entry.hookable || entry.pendingEnabled) {
                UISwitch *toggle = [UISwitch new];
                toggle.on = entry.pendingEnabled;
                objc_setAssociatedObject(
                    toggle,
                    kFLEXRuntimeBrowserEntryKey,
                    entry,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
                [toggle addTarget:self
                           action:@selector(toggleChanged:)
                 forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = toggle;
            } else {
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
        }
        FLEXStyleCompactRuntimeCell(
            cell,
            FLEXCompactPositionForRow(indexPath.row, group.hits.count)
        );
        return cell;
    }

    FLEXRuntimeEntryGroup *group = self.cGroups[indexPath.section];
    FLEXHookEntry *entry = group.entries[indexPath.row];
    FLEXConfigureCompactRuntimeContent(
        cell,
        FLEXRuntimeMemberTitleForEntry(entry),
        entry.detail,
        entry.hookable ? @"switch.2" : @"function",
        entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor
    );
    if (entry.hookable || entry.pendingEnabled) {
        UISwitch *toggle = [UISwitch new];
        toggle.on = entry.pendingEnabled;
        objc_setAssociatedObject(
            toggle,
            kFLEXRuntimeBrowserEntryKey,
            entry,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
        [toggle addTarget:self
                   action:@selector(toggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    FLEXStyleCompactRuntimeCell(
        cell,
        FLEXCompactPositionForRow(indexPath.row, group.entries.count)
    );
    return cell;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        if (!self.objectiveCSearchActive) {
            NSString *className = self.liveClassNames[indexPath.row];
            FLEXRuntimeClassDetailController *detail =
                [[FLEXRuntimeClassDetailController alloc]
                    initWithClassName:className image:self.selectedImage];
            [self.navigationController pushViewController:detail animated:YES];
            return;
        }
        FLEXRuntimeSearchHit *hit =
            self.searchGroups[indexPath.section].hits[indexPath.row];
        if (hit.kind == FLEXRuntimeSearchHitKindClass) {
            FLEXRuntimeClassDetailController *detail =
                [[FLEXRuntimeClassDetailController alloc]
                    initWithClassName:hit.className image:self.selectedImage];
            [self.navigationController pushViewController:detail animated:YES];
            return;
        }
        if (hit.kind == FLEXRuntimeSearchHitKindProperty) {
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:hit.property.name
                                 message:hit.property.attributes.length
                                    ? hit.property.attributes : @"No runtime attributes"
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Done"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        FLEXHookEntry *canonical = [FLEXHookRegistry.sharedRegistry
            upsertDiscoveredEntry:hit.entry];
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc]
                initWithEntry:canonical ?: hit.entry];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }

    FLEXHookEntry *entry = self.cGroups[indexPath.section].entries[indexPath.row];
    FLEXHookEntry *canonical = [FLEXHookRegistry.sharedRegistry
        upsertDiscoveredEntry:entry];
    if (entry.surface != FLEXHookSurfaceObjectiveC && !entry.hookable) {
        [FLEXCHookEngine refreshAvailabilityForEntry:canonical ?: entry];
    }
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc]
            initWithEntry:canonical ?: entry];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)toggleChanged:(UISwitch *)toggle {
    FLEXHookEntry *discovered = objc_getAssociatedObject(
        toggle, kFLEXRuntimeBrowserEntryKey);
    if (!discovered) return;
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    FLEXHookEntry *entry = [registry upsertDiscoveredEntry:discovered];
    BOOL requested = toggle.isOn;
    if (requested && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:entry.identifier];
    }
    [registry stageEnabled:requested forEntryIdentifier:entry.identifier];
    FLEXHookEntry *resolved = [registry entryForIdentifier:entry.identifier];
    BOOL accepted = resolved && resolved.pendingEnabled == requested;
    [toggle setOn:accepted ? requested : !requested animated:YES];
    if (accepted) {
        [UISelectionFeedbackGenerator.new selectionChanged];
    } else {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
    }
}

- (void)updateNavigationStatus {
    NSString *status = nil;
    if (self.scanning || self.searching) {
        status = self.statusText ?: @"Reading live runtime";
    } else if (!self.selectedImage) {
        status = @"No app image loaded";
    } else if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        if (self.objectiveCSearchActive) {
            NSUInteger hitCount = 0;
            for (FLEXRuntimeSearchGroup *group in self.searchGroups) {
                hitCount += group.hits.count;
            }
            status = [NSString stringWithFormat:@"%@ · %lu live match%@",
                self.selectedImage.displayName,
                (unsigned long)hitCount,
                hitCount == 1 ? @"" : @"es"];
        } else {
            status = [NSString stringWithFormat:@"%@ · %lu live classes",
                self.selectedImage.displayName,
                (unsigned long)self.liveClassNames.count];
        }
    } else {
        NSUInteger count = 0;
        for (FLEXRuntimeEntryGroup *group in self.cGroups) count += group.entries.count;
        status = [NSString stringWithFormat:@"%@ · %lu live symbols",
            self.selectedImage.displayName,
            (unsigned long)count];
    }
    if (@available(iOS 26.0, *)) self.navigationItem.subtitle = status;
}

- (void)updateUnavailableConfigurationWithError:(NSError *)error {
    if (@available(iOS 17.0, *)) {
        BOOL hasContent = self.kind == FLEXRuntimeBrowserKindObjectiveC
            ? (self.objectiveCSearchActive
                ? self.searchGroups.count > 0
                : self.liveClassNames.count > 0)
            : self.cGroups.count > 0;
        if (hasContent) {
            self.contentUnavailableConfiguration = nil;
            return;
        }

        UIContentUnavailableConfiguration *configuration = nil;
        if (self.scanning) {
            configuration = [UIContentUnavailableConfiguration loadingConfiguration];
            configuration.text = self.statusText ?: @"Reading live runtime";
            configuration.secondaryText = self.kind == FLEXRuntimeBrowserKindObjectiveC
                ? @"Only current class names are enumerated now. Methods and properties are read when you open a class or search."
                : @"The current selected Mach-O image is being read off the main thread.";
        } else if (self.searching) {
            configuration = [UIContentUnavailableConfiguration loadingConfiguration];
            configuration.text = @"Searching current runtime";
            configuration.secondaryText =
                @"This search enumerates the runtime on demand; there is no prebuilt feature classification.";
        } else if (error) {
            configuration = [UIContentUnavailableConfiguration emptyConfiguration];
            configuration.image = [UIImage systemImageNamed:
                @"exclamationmark.triangle"];
            configuration.text = @"Runtime read failed";
            configuration.secondaryText = error.localizedDescription;
        } else if (self.searchController.searchBar.text.length) {
            configuration = [UIContentUnavailableConfiguration searchConfiguration];
            configuration.text = @"No live runtime match";
            configuration.secondaryText = @"Try another class, method, property or symbol term.";
        } else {
            configuration = [UIContentUnavailableConfiguration emptyConfiguration];
            configuration.text = self.selectedImage
                ? @"No live runtime entries" : @"No app image loaded";
            configuration.secondaryText = self.selectedImage
                ? @"Choose another loaded framework or refresh the current image."
                : @"Load the app executable or an embedded framework first.";
        }
        self.contentUnavailableConfiguration = configuration;
    }
}

@end
