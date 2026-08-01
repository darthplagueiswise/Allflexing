#import "FLEXHookToggles.h"

#import "FLEXHooking.h"
#import "FLEXHookPersistence.h"
#import "FLEXLiquidGlass.h"
#import "FLEXSymbolRebind.h"
#import <objc/runtime.h>

static const void *kFLEXHookToggleIdentifierKey = &kFLEXHookToggleIdentifierKey;

@interface FLEXHookToggles ()
@property (nonatomic, copy) NSArray<FLEXHookFlag *> *flags;
@end

@implementation FLEXHookToggles

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hook Toggles";
    self.tableView.allowsSelection = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
    [self reloadFlags];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(flagsChanged:)
               name:FLEXHookFlagsDidChangeNotification
             object:nil];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFlags];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reloadFlags {
    self.flags = FLEXHookPersistence.sharedManager.registeredFlags;
    [self.tableView reloadData];
}

- (void)flagsChanged:(NSNotification *)notification {
    (void)notification;
    [self reloadFlags];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.flags.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseIdentifier = @"AllFLEXingHookToggleCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:reuseIdentifier];
    }

    FLEXHookFlag *flag = self.flags[indexPath.row];
    cell.textLabel.text = flag.title;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@",
        flag.detail,
        flag.identifier];
    cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = UIColor.secondarySystemBackgroundColor;

    UISwitch *toggle = [UISwitch new];
    toggle.on = [FLEXHookPersistence.sharedManager boolForFlag:flag.identifier];
    objc_setAssociatedObject(
        toggle,
        kFLEXHookToggleIdentifierKey,
        flag.identifier,
        OBJC_ASSOCIATION_COPY_NONATOMIC
    );
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return @"AllFLEXing runtime";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    FLEXHookPersistence *persistence = FLEXHookPersistence.sharedManager;
    return [NSString stringWithFormat:
        @"Hooks install once when the dylib loads. Switches gate them live and persist in %@.\n\nMessage hooks: %@\nC symbols: %@",
        persistence.storageDomainDescription,
        FLEXMessageHookBackend(),
        FLEXSymbolRebind.backendDescription];
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXHookToggleIdentifierKey);
    if (identifier.length == 0) {
        return;
    }

    [FLEXHookPersistence.sharedManager setBool:toggle.isOn forFlag:identifier];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

@end
