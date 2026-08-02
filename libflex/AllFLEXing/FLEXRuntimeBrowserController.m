#import "FLEXRuntimeBrowserController.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeImageSession.h"
#import "FLEXRuntimeScanner.h"

#import <objc/runtime.h>

static const void *kFLEXRuntimeBrowserEntryIDKey = &kFLEXRuntimeBrowserEntryIDKey;

@interface FLEXRuntimeSearchRecord : NSObject
@property (nonatomic) FLEXHookEntry *entry;
@property (nonatomic, copy) NSString *normalizedText;
@property (nonatomic, copy) NSArray<NSString *> *tokens;
@end
@implementation FLEXRuntimeSearchRecord
@end

static dispatch_queue_t FLEXRuntimeBrowserSearchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.runtime-browser-search",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
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
            if (spaced.length && [spaced characterAtIndex:spaced.length - 1] != ' ') {
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
    NSMutableArray<NSString *> *tokens = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length) [tokens addObject:part];
    }
    return [tokens componentsJoinedByString:@" "];
}

static NSArray<NSString *> *FLEXRuntimeTokens(NSString *normalized) {
    return normalized.length ? [normalized componentsSeparatedByString:@" "] : @[];
}

static BOOL FLEXRuntimeTokenMatches(NSString *query,
                                    NSArray<NSString *> *candidateTokens,
                                    NSString *fullText) {
    if (!query.length) return YES;
    if (query.length >= 3) {
        for (NSString *candidate in candidateTokens) {
            if ([candidate hasPrefix:query] || [query hasPrefix:candidate]) return YES;
        }
    }
    return [fullText rangeOfString:query].location != NSNotFound;
}

static NSInteger FLEXRuntimeSearchScore(FLEXRuntimeSearchRecord *record,
                                        NSArray<NSString *> *queryTokens,
                                        NSString *normalizedQuery) {
    for (NSString *token in queryTokens) {
        if (!FLEXRuntimeTokenMatches(token, record.tokens, record.normalizedText)) {
            return -1;
        }
    }
    NSString *title = FLEXRuntimeNormalizedText(record.entry.title);
    NSInteger score = 0;
    if ([title isEqualToString:normalizedQuery]) score += 500;
    else if ([title hasPrefix:normalizedQuery]) score += 300;
    else if ([title containsString:normalizedQuery]) score += 160;
    for (NSString *token in queryTokens) {
        if ([title hasPrefix:token]) score += 40;
        else if ([title containsString:token]) score += 15;
    }
    return score;
}

@interface FLEXRuntimeBrowserController () <UISearchResultsUpdating>
@property (nonatomic) FLEXRuntimeBrowserKind kind;
@property (nonatomic) BOOL scanning;
@property (nonatomic) BOOL indexing;
@property (nonatomic) UISearchController *searchController;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *allEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *filteredEntries;
@property (nonatomic, copy) NSArray<FLEXRuntimeSearchRecord *> *searchIndex;
@property (nonatomic) FLEXRuntimeImageDescriptor *selectedImage;
@property (nonatomic) FLEXRuntimeImageSession *session;
@property (nonatomic) FLEXRuntimeImageSnapshot *snapshot;
@property (nonatomic) NSUInteger searchGeneration;
@property (nonatomic) UIBarButtonItem *scopeItem;
@property (nonatomic) UIBarButtonItem *reloadItem;
@property (nonatomic) UIBarButtonItem *progressItem;
@property (nonatomic) UIProgressView *progressView;
@property (nonatomic) UIActivityIndicatorView *progressSpinner;
@property (nonatomic, copy) NSString *progressPhase;
@property (nonatomic) NSUInteger progressCompleted;
@property (nonatomic) NSUInteger progressTotal;
@end

@implementation FLEXRuntimeBrowserController

- (instancetype)initWithKind:(FLEXRuntimeBrowserKind)kind {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _kind = kind;
        _allEntries = @[];
        _filteredEntries = @[];
        _searchIndex = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.kind == FLEXRuntimeBrowserKindObjectiveC
        ? @"Objective-C Runtime" : @"C Runtime";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Scan an image before searching";
    self.searchController.searchBar.userInteractionEnabled = NO;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];

    self.reloadItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadScan)];
    self.scopeItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Image"
                 menu:[self scopeMenu]];
    [self buildProgressItem];
    [self installNavigationItemsScanning:NO];

    NSArray<FLEXRuntimeImageDescriptor *> *images =
        FLEXRuntimeImageSession.loadedAppImages;
    self.selectedImage = images.firstObject;
    [self updateScopeItem];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(runtimeImagesChanged:)
               name:FLEXRuntimeImagesDidChangeNotification
             object:nil];

    [FLEXLiquidGlass applyToViewController:self];
    if (self.selectedImage) {
        [self reloadScan];
    } else {
        [self updateUnavailableConfigurationWithError:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshCanonicalEntries];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)dealloc {
    [self.session cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)buildProgressItem {
    self.progressSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.progressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progress = 0;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.progressSpinner, self.progressView]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    [self.progressView.widthAnchor constraintEqualToConstant:72.0].active = YES;
    self.progressItem = [[UIBarButtonItem alloc] initWithCustomView:stack];
    self.progressItem.accessibilityLabel = @"Runtime image scan progress";
}

- (void)installNavigationItemsScanning:(BOOL)scanning {
    UIBarButtonItem *separator = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                             target:nil
                             action:nil];
    separator.width = 8.0;
    if (@available(iOS 26.0, *)) separator.hidesSharedBackground = YES;
    self.navigationItem.rightBarButtonItems = scanning
        ? @[self.progressItem, separator, self.scopeItem]
        : @[self.reloadItem, separator, self.scopeItem];
}

- (void)updateScopeItem {
    self.scopeItem.title = self.selectedImage.displayName ?: @"Image";
    self.scopeItem.menu = [self scopeMenu];
}

- (UIMenu *)scopeMenu {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (FLEXRuntimeImageDescriptor *image in FLEXRuntimeImageSession.loadedAppImages) {
        NSString *subtitle = image.mainExecutable
            ? @"Main executable"
            : [image.path stringByAbbreviatingWithTildeInPath];
        UIAction *action = [UIAction actionWithTitle:image.displayName
                                           subtitle:subtitle
                                              image:[UIImage systemImageNamed:
                                                  image.mainExecutable ? @"terminal" : @"shippingbox"]
                                         identifier:nil
                                            handler:^(__unused UIAction *menuAction) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || [self.selectedImage.path isEqualToString:image.path]) return;
            self.selectedImage = image;
            [self updateScopeItem];
            [self reloadScan];
        }];
        action.state = [self.selectedImage.path isEqualToString:image.path]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    if (!actions.count) {
        UIAction *empty = [UIAction actionWithTitle:@"No app image is loaded"
                                             image:[UIImage systemImageNamed:@"exclamationmark.triangle"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {}];
        empty.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:empty];
    }
    return [UIMenu menuWithTitle:@"Runtime image"
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
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshCanonicalEntries];
}

- (void)refreshCanonicalEntries {
    if (!self.allEntries.count) return;
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    NSMutableArray<FLEXHookEntry *> *canonical =
        [NSMutableArray arrayWithCapacity:self.allEntries.count];
    for (FLEXHookEntry *entry in self.allEntries) {
        [canonical addObject:[registry entryForIdentifier:entry.identifier] ?: entry];
    }
    self.allEntries = canonical.copy;
    [self buildSearchIndexForEntries:self.allEntries];
}

- (void)reloadScan {
    if (!self.selectedImage) return;
    [self.session cancel];
    self.searchGeneration++;
    self.scanning = YES;
    self.indexing = NO;
    self.snapshot = nil;
    self.allEntries = @[];
    self.filteredEntries = @[];
    self.searchIndex = @[];
    self.searchController.searchBar.text = @"";
    self.searchController.searchBar.userInteractionEnabled = NO;
    self.reloadItem.enabled = NO;
    self.scopeItem.enabled = NO;
    self.progressPhase = @"Opening selected image";
    self.progressCompleted = 0;
    self.progressTotal = 0;
    self.progressView.progress = 0;
    [self.progressSpinner startAnimating];
    [self installNavigationItemsScanning:YES];
    [self.tableView reloadData];
    [self updateNavigationStatus];
    [self updateUnavailableConfigurationWithError:nil];

    self.session = [[FLEXRuntimeImageSession alloc]
        initWithImage:self.selectedImage];
    __weak typeof(self) weakSelf = self;
    [self.session scanKind:self.kind
                  progress:^(NSString *phase, NSUInteger completed, NSUInteger total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.scanning) return;
        self.progressPhase = phase;
        self.progressCompleted = completed;
        self.progressTotal = total;
        self.progressView.progress = total
            ? MIN(1.0, (float)completed / (float)total)
            : 0.05;
        [self updateNavigationStatus];
        [self updateUnavailableConfigurationWithError:nil];
    } completion:^(FLEXRuntimeImageSnapshot *snapshot, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.scanning = NO;
        [self.progressSpinner stopAnimating];
        self.reloadItem.enabled = YES;
        self.scopeItem.enabled = YES;
        [self installNavigationItemsScanning:NO];
        if (!snapshot || error) {
            self.allEntries = @[];
            self.filteredEntries = @[];
            [self.tableView reloadData];
            [self updateNavigationStatus];
            [self updateUnavailableConfigurationWithError:error];
            return;
        }

        self.snapshot = snapshot;
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        NSMutableArray<FLEXHookEntry *> *canonical =
            [NSMutableArray arrayWithCapacity:snapshot.entries.count];
        for (FLEXHookEntry *entry in snapshot.entries) {
            FLEXHookEntry *merged = [registry upsertDiscoveredEntry:entry];
            [canonical addObject:merged ?: entry];
        }
        self.allEntries = canonical.copy;
        [self buildSearchIndexForEntries:self.allEntries];
    }];
}

- (void)buildSearchIndexForEntries:(NSArray<FLEXHookEntry *> *)entries {
    NSUInteger generation = ++self.searchGeneration;
    self.indexing = YES;
    self.searchController.searchBar.userInteractionEnabled = NO;
    self.progressPhase = @"Building complete search index";
    [self.progressSpinner startAnimating];
    [self installNavigationItemsScanning:YES];
    [self updateNavigationStatus];
    [self updateUnavailableConfigurationWithError:nil];

    dispatch_async(FLEXRuntimeBrowserSearchQueue(), ^{
        NSMutableArray<FLEXRuntimeSearchRecord *> *records =
            [NSMutableArray arrayWithCapacity:entries.count];
        NSUInteger completed = 0;
        for (FLEXHookEntry *entry in entries) {
            @autoreleasepool {
                NSMutableString *raw = [NSMutableString stringWithFormat:
                    @"%@ %@ %@ %@ %@",
                    entry.title ?: @"",
                    entry.detail ?: @"",
                    entry.imageName ?: @"",
                    entry.identifier ?: @"",
                    entry.locator ?: @{}];
                FLEXRuntimeSearchRecord *record = [FLEXRuntimeSearchRecord new];
                record.entry = entry;
                record.normalizedText = FLEXRuntimeNormalizedText(raw);
                record.tokens = FLEXRuntimeTokens(record.normalizedText);
                [records addObject:record];
            }
            completed++;
            if ((completed & 1023) == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.searchGeneration) return;
                    self.progressCompleted = completed;
                    self.progressTotal = entries.count;
                    self.progressView.progress = entries.count
                        ? (float)completed / (float)entries.count : 1.0;
                    [self updateNavigationStatus];
                });
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return;
            self.searchIndex = records.copy;
            self.indexing = NO;
            [self.progressSpinner stopAnimating];
            [self installNavigationItemsScanning:NO];
            self.searchController.searchBar.userInteractionEnabled = YES;
            self.searchController.searchBar.placeholder = [NSString stringWithFormat:
                @"Search %lu indexed %@",
                (unsigned long)records.count,
                self.kind == FLEXRuntimeBrowserKindObjectiveC ? @"methods" : @"functions"];
            [self reloadEntries];
        });
    });
}

- (void)reloadEntries {
    [self scheduleSearchForText:self.searchController.searchBar.text ?: @"" immediate:YES];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self scheduleSearchForText:searchController.searchBar.text ?: @"" immediate:NO];
}

- (void)scheduleSearchForText:(NSString *)text immediate:(BOOL)immediate {
    if (self.scanning || self.indexing || !self.searchIndex.count) return;
    NSUInteger generation = ++self.searchGeneration;
    NSString *query = FLEXRuntimeNormalizedText(text);
    NSTimeInterval delay = immediate ? 0 : 0.16;
    NSArray<FLEXRuntimeSearchRecord *> *index = self.searchIndex;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(delay * NSEC_PER_SEC)),
                   FLEXRuntimeBrowserSearchQueue(), ^{
        if (generation != self.searchGeneration) return;
        NSArray<NSString *> *queryTokens = FLEXRuntimeTokens(query);
        NSMutableArray<NSDictionary *> *ranked = [NSMutableArray array];
        for (FLEXRuntimeSearchRecord *record in index) {
            if (generation != self.searchGeneration) return;
            NSInteger score = query.length
                ? FLEXRuntimeSearchScore(record, queryTokens, query) : 1;
            if (score < 0) continue;
            [ranked addObject:@{ @"entry": record.entry, @"score": @(score) }];
        }
        if (query.length) {
            [ranked sortUsingComparator:^NSComparisonResult(
                NSDictionary *left, NSDictionary *right
            ) {
                NSInteger leftScore = [left[@"score"] integerValue];
                NSInteger rightScore = [right[@"score"] integerValue];
                if (leftScore != rightScore) {
                    return leftScore > rightScore ? NSOrderedAscending : NSOrderedDescending;
                }
                return [((FLEXHookEntry *)left[@"entry"]).title
                    localizedCaseInsensitiveCompare:((FLEXHookEntry *)right[@"entry"]).title];
            }];
        }

        NSUInteger materializationLimit = query.length <= 1 ? 2048 : 8192;
        NSUInteger count = MIN(materializationLimit, ranked.count);
        NSMutableArray<FLEXHookEntry *> *results =
            [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger indexPosition = 0; indexPosition < count; indexPosition++) {
            [results addObject:ranked[indexPosition][@"entry"]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return;
            self.filteredEntries = results.copy;
            [self.tableView reloadData];
            [self updateNavigationStatusWithTotalMatches:ranked.count];
            [self updateUnavailableConfigurationWithError:nil];
        });
    });
}

- (void)addManualSymbol:(UIBarButtonItem *)sender {
    (void)sender;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Add symbol in selected image"
                         message:self.selectedImage.displayName
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Exact symbol name";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Resolve"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *symbol = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!symbol.length) return;
        FLEXHookEntry *entry = [FLEXRuntimeScanner manualCEntryForSymbol:symbol
                                                               imageName:self.selectedImage.path];
        [FLEXCHookEngine refreshAvailabilityForEntry:entry];
        FLEXHookEntry *canonical = [FLEXHookRegistry.sharedRegistry
            upsertDiscoveredEntry:entry];
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc] initWithEntry:canonical ?: entry];
        [self.navigationController pushViewController:detail animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.filteredEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AllFLEXingRuntimeBrowserCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    FLEXHookEntry *entry = self.filteredEntries[indexPath.row];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = entry.title;
    content.textProperties.numberOfLines = 0;
    content.textProperties.lineBreakMode = NSLineBreakByCharWrapping;
    content.secondaryText = [NSString stringWithFormat:@"%@\n%@ · %@",
        entry.detail, entry.imageName, entry.statusSummary];
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping;
    content.image = [UIImage systemImageNamed:entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? @"checkmark.circle.fill" : @"bolt.circle.fill")
        : (entry.hookable ? @"circle.dashed" : @"waveform.path.ecg")];
    content.imageProperties.tintColor = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor)
        : (entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor);
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryNone;

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@", entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(toggle,
                             kFLEXRuntimeBrowserEntryIDKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(toggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    [FLEXLiquidGlass styleTableCell:cell];
    return cell;
}

- (void)updateNavigationStatus {
    [self updateNavigationStatusWithTotalMatches:self.filteredEntries.count];
}

- (void)updateNavigationStatusWithTotalMatches:(NSUInteger)totalMatches {
    NSString *status = nil;
    if (self.scanning || self.indexing) {
        if (self.progressTotal) {
            status = [NSString stringWithFormat:@"%@ · %lu/%lu",
                self.progressPhase ?: @"Working",
                (unsigned long)self.progressCompleted,
                (unsigned long)self.progressTotal];
        } else {
            status = self.progressPhase ?: @"Working…";
        }
    } else if (self.snapshot) {
        status = [NSString stringWithFormat:@"%@ · %lu indexed · %lu shown",
            self.selectedImage.displayName,
            (unsigned long)self.searchIndex.count,
            (unsigned long)MIN(totalMatches, self.filteredEntries.count)];
    } else {
        status = @"Select an image and scan";
    }
    if (@available(iOS 26.0, *)) self.navigationItem.subtitle = status;
}

- (void)updateUnavailableConfigurationWithError:(NSError *)error {
    if (@available(iOS 17.0, *)) {
        if (self.filteredEntries.count) {
            self.contentUnavailableConfiguration = nil;
            return;
        }
        UIContentUnavailableConfiguration *configuration = nil;
        if (self.scanning || self.indexing) {
            configuration = [UIContentUnavailableConfiguration loadingConfiguration];
            configuration.text = self.progressPhase ?: @"Scanning selected image";
            configuration.secondaryText = @"Mach-O, Objective-C metadata, symbols, function starts and ABI evidence are resolved off the main thread.";
        } else if (error) {
            configuration = [UIContentUnavailableConfiguration emptyConfiguration];
            configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
            configuration.text = @"Runtime scan failed";
            configuration.secondaryText = error.localizedDescription;
        } else if (self.searchController.searchBar.text.length) {
            configuration = [UIContentUnavailableConfiguration searchConfiguration];
            configuration.text = @"No result in the selected image";
            configuration.secondaryText = @"The completed image index was searched; refresh only when the loaded image changes.";
        } else {
            configuration = [UIContentUnavailableConfiguration emptyConfiguration];
            configuration.text = self.selectedImage ? @"No runtime entries" : @"No app image loaded";
            configuration.secondaryText = self.selectedImage
                ? @"Refresh the selected image or choose another framework."
                : @"Load the application executable or a framework first.";
        }
        self.contentUnavailableConfiguration = configuration;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.selectedImage.displayName;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FLEXHookEntry *entry = self.filteredEntries[indexPath.row];
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXRuntimeBrowserEntryIDKey);
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requestedState = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    if (requestedState && entry && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requestedState forEntryIdentifier:identifier];
    entry = [registry entryForIdentifier:identifier];
    if (!entry || entry.pendingEnabled != requestedState) {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
        [self refreshCanonicalEntries];
        return;
    }
    [UISelectionFeedbackGenerator.new selectionChanged];
    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:identifier completion:^(
        __unused NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        FLEXHookEntry *resolved = [registry entryForIdentifier:identifier];
        UINotificationFeedbackType type = failed.count
            ? UINotificationFeedbackTypeError
            : (resolved.overrideHitCount > 0
                ? UINotificationFeedbackTypeSuccess
                : UINotificationFeedbackTypeWarning);
        [UINotificationFeedbackGenerator.new notificationOccurred:type];
        [weakSelf refreshCanonicalEntries];
    }];
}

@end
