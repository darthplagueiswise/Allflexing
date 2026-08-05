#import "FLEXHookableObjectExplorerViewController.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"
#import "FLEXMethod.h"
#import "FLEXObjCHookResolver.h"
#import "FLEXObjectExplorer.h"
#import "FLEXProperty.h"
#import "FLEXTableView.h"
#import "FLEXTableViewCell.h"
#import "FLEXTableViewController.h"
#import "FLEXTableViewSection.h"

#import <objc/runtime.h>

#pragma mark - Semantic helpers

static NSString *FLEXHookableNormalizeText(NSString *input) {
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

        BOOL boundary = NO;
        if (index > 0 && [uppercase characterIsMember:character]) {
            unichar previous = [input characterAtIndex:index - 1];
            BOOL previousLower = [lowercase characterIsMember:previous];
            BOOL previousDigit = [digits characterIsMember:previous];
            BOOL previousUpper = [uppercase characterIsMember:previous];
            BOOL nextLower = index + 1 < input.length &&
                [lowercase characterIsMember:[input characterAtIndex:index + 1]];
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

static NSString *FLEXHookableCompactText(NSString *input) {
    return [[FLEXHookableNormalizeText(input)
        stringByReplacingOccurrencesOfString:@" " withString:@""] copy];
}

static NSArray<NSString *> *FLEXHookableQueryTerms(NSString *query) {
    NSString *normalized = FLEXHookableNormalizeText(query);
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

static BOOL FLEXHookableEntryMatches(FLEXHookEntry *entry,
                                     NSArray<NSString *> *terms) {
    NSDictionary *locator = entry.locator ?: @{};
    NSArray<NSString *> *fields = @[
        entry.title ?: @"",
        entry.detail ?: @"",
        entry.imageName ?: @"",
        [locator[@"class"] isKindOfClass:NSString.class] ? locator[@"class"] : @"",
        [locator[@"selector"] isKindOfClass:NSString.class] ? locator[@"selector"] : @"",
        [locator[@"encoding"] isKindOfClass:NSString.class] ? locator[@"encoding"] : @"",
    ];

    NSMutableArray<NSString *> *normalizedFields = [NSMutableArray array];
    NSMutableArray<NSString *> *compactFields = [NSMutableArray array];
    for (NSString *field in fields) {
        [normalizedFields addObject:FLEXHookableNormalizeText(field)];
        [compactFields addObject:FLEXHookableCompactText(field)];
    }

    for (NSString *term in terms) {
        NSString *compactTerm = FLEXHookableCompactText(term);
        BOOL matched = NO;
        for (NSUInteger index = 0; index < normalizedFields.count; index++) {
            if ([normalizedFields[index] rangeOfString:term].location != NSNotFound ||
                (compactTerm.length &&
                 [compactFields[index] rangeOfString:compactTerm].location != NSNotFound)) {
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

#pragma mark - Models

@interface FLEXHookableEntryGroup : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@end

@implementation FLEXHookableEntryGroup
@end

@class FLEXHookableEntryListController;

@interface FLEXHookableGroupSection : FLEXTableViewSection
@property (nonatomic, copy) NSArray<FLEXHookableEntryGroup *> *allGroups;
@property (nonatomic, copy) NSArray<FLEXHookableEntryGroup *> *visibleGroups;
- (instancetype)initWithGroups:(NSArray<FLEXHookableEntryGroup *> *)groups;
@end

@interface FLEXHookableEntryDetailController : FLEXHookEntryDetailController
@end

@interface FLEXHookableEntryListController : FLEXTableViewController <FLEXSearchResultsUpdating>
@property (nonatomic) FLEXHookableEntryGroup *group;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *visibleEntries;
- (instancetype)initWithGroup:(FLEXHookableEntryGroup *)group;
@end

#pragma mark - Group section

@implementation FLEXHookableGroupSection

- (instancetype)initWithGroups:(NSArray<FLEXHookableEntryGroup *> *)groups {
    self = [super init];
    if (self) {
        _title = @"Hookable members";
        _allGroups = groups.copy;
        _visibleGroups = groups.copy;
    }
    return self;
}

- (NSInteger)numberOfRows {
    return self.visibleGroups.count;
}

- (void)setFilterText:(NSString *)filterText {
    [super setFilterText:filterText];
    NSArray<NSString *> *terms = FLEXHookableQueryTerms(filterText ?: @"");
    if (terms.count == 0) {
        self.visibleGroups = self.allGroups;
        return;
    }

    self.visibleGroups = [self.allGroups filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(FLEXHookableEntryGroup *group,
                                              NSDictionary *bindings) {
            (void)bindings;
            NSString *haystack = [NSString stringWithFormat:@"%@ %@",
                group.title ?: @"", group.subtitle ?: @""];
            NSString *normalized = FLEXHookableNormalizeText(haystack);
            NSString *compact = FLEXHookableCompactText(haystack);
            for (NSString *term in terms) {
                if ([normalized rangeOfString:term].location == NSNotFound &&
                    [compact rangeOfString:FLEXHookableCompactText(term)].location == NSNotFound) {
                    return NO;
                }
            }
            return YES;
        }]];
}

- (void)reloadData {
    [self setFilterText:self.filterText];
}

- (NSString *)reuseIdentifierForRow:(NSInteger)row {
    (void)row;
    return kFLEXMultilineDetailCell;
}

- (void)configureCell:(UITableViewCell *)cell forRow:(NSInteger)row {
    FLEXHookableEntryGroup *group = self.visibleGroups[(NSUInteger)row];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = group.title;
    content.secondaryText = group.subtitle;
    content.secondaryTextProperties.numberOfLines = 0;
    content.image = [UIImage systemImageNamed:group.imageName];
    content.imageProperties.tintColor = cell.tintColor;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    [FLEXLiquidGlass styleTableCell:cell];
}

- (BOOL)canSelectRow:(NSInteger)row {
    return row >= 0 && row < self.visibleGroups.count;
}

- (UIViewController *)viewControllerToPushForRow:(NSInteger)row {
    if (![self canSelectRow:row]) {
        return nil;
    }
    return [[FLEXHookableEntryListController alloc]
        initWithGroup:self.visibleGroups[(NSUInteger)row]];
}

- (NSString *)titleForRow:(NSInteger)row {
    return [self canSelectRow:row] ? self.visibleGroups[(NSUInteger)row].title : nil;
}

- (NSString *)subtitleForRow:(NSInteger)row {
    return [self canSelectRow:row] ? self.visibleGroups[(NSUInteger)row].subtitle : nil;
}

@end

#pragma mark - Explicit detail navigation

@implementation FLEXHookableEntryDetailController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    self.navigationItem.hidesBackButton = YES;

    if (self.navigationController.viewControllers.count > 1) {
        UIBarButtonItem *back = [[UIBarButtonItem alloc]
            initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
                    style:UIBarButtonItemStylePlain
                   target:self
                   action:@selector(allflexing_goBack:)];
        back.accessibilityLabel = @"Back";
        self.navigationItem.leftBarButtonItem = back;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (void)allflexing_goBack:(UIBarButtonItem *)sender {
    (void)sender;
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - Per-group function list

@implementation FLEXHookableEntryListController

- (instancetype)initWithGroup:(FLEXHookableEntryGroup *)group {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _group = group;
        _visibleEntries = group.entries;
        self.showsSearchBar = YES;
        self.showSearchBarInitially = YES;
        self.searchDelegate = self;
        self.searchBarDebounceInterval = kFLEXDebounceFast;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.group.title;
    self.searchController.searchBar.placeholder = @"Search name, selector, ABI or encoding";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58.0;
    self.navigationItem.hidesBackButton = NO;
    self.navigationItem.backButtonTitle = @"";
    if (@available(iOS 14.0, *)) {
        self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    }
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    [self disableToolbar];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)updateSearchResults:(NSString *)newText {
    NSArray<NSString *> *terms = FLEXHookableQueryTerms(newText ?: @"");
    if (terms.count == 0) {
        self.visibleEntries = self.group.entries;
    } else {
        self.visibleEntries = [self.group.entries filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(FLEXHookEntry *entry,
                                                  NSDictionary *bindings) {
                (void)bindings;
                return FLEXHookableEntryMatches(entry, terms);
            }]];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.visibleEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FLEXTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kFLEXMultilineDetailCell
                                                              forIndexPath:indexPath];
    FLEXHookEntry *entry = self.visibleEntries[(NSUInteger)indexPath.row];

    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = entry.title;
    content.secondaryText = [NSString stringWithFormat:@"%@\n%@",
        entry.detail ?: @"", entry.statusSummary ?: @""];
    content.secondaryTextProperties.numberOfLines = 0;
    content.image = [UIImage systemImageNamed:@"function"];
    content.imageProperties.tintColor = entry.hookable
        ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    [FLEXLiquidGlass styleTableCell:cell];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.visibleEntries.count) {
        return;
    }

    FLEXHookEntry *candidate = self.visibleEntries[(NSUInteger)indexPath.row];
    FLEXHookEntry *entry = [FLEXHookRegistry.sharedRegistry upsertDiscoveredEntry:candidate];
    if (!entry) {
        return;
    }

    FLEXHookableEntryDetailController *detail =
        [[FLEXHookableEntryDetailController alloc] initWithEntry:entry];
    detail.navigationItem.hidesBackButton = NO;
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    [self.navigationController pushViewController:detail animated:YES];
}

@end

#pragma mark - Class explorer

@implementation FLEXHookableObjectExplorerViewController

- (Class)allflexing_currentScopeClass {
    NSArray<Class> *classes = self.explorer.classHierarchyClasses;
    NSInteger scope = self.explorer.classScope;
    if (scope < 0 || scope >= (NSInteger)classes.count) {
        return object_isClass(self.object) ? (Class)self.object : object_getClass(self.object);
    }
    return classes[(NSUInteger)scope];
}

- (NSArray<FLEXHookEntry *> *)allflexing_methodEntriesFrom:(NSArray<FLEXMethod *> *)methods
                                                targetClass:(Class)targetClass {
    NSMutableArray<FLEXHookEntry *> *entries = [NSMutableArray array];
    for (FLEXMethod *method in methods) {
        FLEXHookEntry *entry = [FLEXObjCHookResolver entryForMethod:method
                                                       targetClass:targetClass];
        if (entry) {
            [entries addObject:entry];
        }
    }
    [entries sortUsingComparator:^NSComparisonResult(FLEXHookEntry *left,
                                                      FLEXHookEntry *right) {
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
    return entries.copy;
}

- (NSArray<FLEXHookEntry *> *)allflexing_propertyEntriesFrom:(NSArray<FLEXProperty *> *)properties
                                                  targetClass:(Class)targetClass {
    NSMutableArray<FLEXHookEntry *> *entries = [NSMutableArray array];
    for (FLEXProperty *property in properties) {
        FLEXHookEntry *entry = [FLEXObjCHookResolver entryForProperty:property
                                                         targetClass:targetClass];
        if (entry) {
            [entries addObject:entry];
        }
    }
    [entries sortUsingComparator:^NSComparisonResult(FLEXHookEntry *left,
                                                      FLEXHookEntry *right) {
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
    return entries.copy;
}

- (FLEXHookableEntryGroup *)allflexing_groupWithTitle:(NSString *)title
                                             subtitle:(NSString *)subtitle
                                                image:(NSString *)image
                                              entries:(NSArray<FLEXHookEntry *> *)entries {
    FLEXHookableEntryGroup *group = [FLEXHookableEntryGroup new];
    group.title = title;
    group.subtitle = [NSString stringWithFormat:@"%lu %@",
        (unsigned long)entries.count, subtitle];
    group.imageName = image;
    group.entries = entries;
    return group;
}

- (NSArray<FLEXTableViewSection *> *)makeSections {
    Class targetClass = [self allflexing_currentScopeClass];
    if (!targetClass) {
        return @[];
    }

    NSArray<FLEXHookEntry *> *instanceProperties =
        [self allflexing_propertyEntriesFrom:self.explorer.properties
                                 targetClass:targetClass];
    NSArray<FLEXHookEntry *> *classProperties =
        [self allflexing_propertyEntriesFrom:self.explorer.classProperties
                                 targetClass:targetClass];
    NSArray<FLEXHookEntry *> *instanceMethods =
        [self allflexing_methodEntriesFrom:self.explorer.methods
                               targetClass:targetClass];
    NSArray<FLEXHookEntry *> *classMethods =
        [self allflexing_methodEntriesFrom:self.explorer.classMethods
                               targetClass:targetClass];

    NSMutableArray<FLEXHookableEntryGroup *> *groups = [NSMutableArray array];
    if (instanceProperties.count) {
        [groups addObject:[self allflexing_groupWithTitle:@"Instance properties"
                                                 subtitle:@"hookable BOOL getters"
                                                    image:@"p.square"
                                                  entries:instanceProperties]];
    }
    if (classProperties.count) {
        [groups addObject:[self allflexing_groupWithTitle:@"Class properties"
                                                 subtitle:@"hookable BOOL getters"
                                                    image:@"p.square.fill"
                                                  entries:classProperties]];
    }
    if (instanceMethods.count) {
        [groups addObject:[self allflexing_groupWithTitle:@"Instance methods"
                                                 subtitle:@"hookable functions"
                                                    image:@"minus.square"
                                                  entries:instanceMethods]];
    }
    if (classMethods.count) {
        [groups addObject:[self allflexing_groupWithTitle:@"Class methods"
                                                 subtitle:@"hookable functions"
                                                    image:@"plus.square"
                                                  entries:classMethods]];
    }

    return groups.count ? @[[[FLEXHookableGroupSection alloc] initWithGroups:groups]] : @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    Class targetClass = [self allflexing_currentScopeClass];
    self.title = targetClass ? NSStringFromClass(targetClass) : @"Objective-C";
    self.navigationItem.hidesBackButton = NO;
    self.navigationItem.backButtonTitle = @"";
    if (@available(iOS 14.0, *)) {
        self.navigationItem.backButtonDisplayMode = UINavigationItemBackButtonDisplayModeMinimal;
    }
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    [self disableToolbar];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [FLEXLiquidGlass applyToViewController:self];
}

- (BOOL)shouldShowDescription {
    return NO;
}

@end
