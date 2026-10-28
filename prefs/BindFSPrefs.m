#import <UIKit/UIKit.h>
#import <spawn.h>
#import <objc/runtime.h>
#import <stdlib.h>
#include <roothide.h>

// 从当前 bundle 加载本地化字符串（用 AdvancedSettingsController 因为两个类在同一个 bundle）
#define BindFSLoc(key) NSLocalizedStringFromTableInBundle(key, nil, [NSBundle bundleForClass:[AdvancedSettingsController class]], nil)

@class BindFSPrefsController;

@interface AdvancedSettingsController : UITableViewController
@property (nonatomic, strong) NSMutableDictionary *prefs;
@property (nonatomic, copy) void (^saveBlock)(void);
@end

@implementation AdvancedSettingsController

- (void)setRootController:(id)controller {}
- (void)setParentController:(id)controller {}
- (void)setSpecifier:(id)specifier {}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = BindFSLoc(@"Advanced Settings");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 40)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(4, 10, 250, 24)];
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = (section == 0) ? BindFSLoc(@"CUSTOM MOUNT ROOT") : BindFSLoc(@"RELOAD METHOD");
    [header addSubview:label];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { return 40; }

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 44;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    
    if (indexPath.section == 0) {
        // 自定义挂载根 - 左对齐输入框
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(16, 0, cell.contentView.bounds.size.width - 32, 44)];
        tf.text = self.prefs[@"root"];
        tf.textAlignment = NSTextAlignmentLeft;
        tf.font = [UIFont systemFontOfSize:15];
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [tf addTarget:self action:@selector(rootChanged:) forControlEvents:UIControlEventEditingDidEnd];
        [cell.contentView addSubview:tf];
    } else {
        // 生效方式 - 左右选择
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[
            BindFSLoc(@"Reboot Userspace"),
            BindFSLoc(@"Restart Desktop")
        ]];
        seg.frame = CGRectMake(16, 8, cell.contentView.bounds.size.width - 32, 32);
        seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        NSString *mode = self.prefs[@"reboot"];
        seg.selectedSegmentIndex = [mode isEqualToString:@"2"] ? 1 : 0;
        [seg addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:seg];
    }
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return BindFSLoc(@"Reload note");
    return nil;
}

- (void)rootChanged:(UITextField *)tf {
    self.prefs[@"root"] = tf.text ?: @".jbroot/bindfs";
    if (self.saveBlock) self.saveBlock();
}

- (void)modeChanged:(UISegmentedControl *)seg {
    self.prefs[@"reboot"] = (seg.selectedSegmentIndex == 1) ? @"2" : @"1";
    if (self.saveBlock) self.saveBlock();
}

@end

@interface BindFSPrefsController : UITableViewController
@property (nonatomic, strong) NSMutableDictionary *prefs;
@end

@implementation BindFSPrefsController

- (void)setRootController:(id)controller {}
- (void)setParentController:(id)controller {}
- (void)setSpecifier:(id)specifier {}

- (NSString *)prefsPath {
    return @(jbroot("/var/mobile/Library/Preferences/com.nan.auto-bindfs.plist"));
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = BindFSLoc(@"BindFS");
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    [self loadPrefs];
    UIBarButtonItem *mountBtn = [[UIBarButtonItem alloc] initWithTitle:BindFSLoc(@"Mount Now")
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(mountNow)];
    UIBarButtonItem *reloadBtn = [[UIBarButtonItem alloc] initWithTitle:BindFSLoc(@"Reload")
                                                                   style:UIBarButtonItemStyleDone
                                                                  target:self
                                                                  action:@selector(reloadNow)];
    self.navigationItem.rightBarButtonItems = @[reloadBtn, mountBtn];
}

- (void)loadPrefs {
    self.prefs = [[NSDictionary dictionaryWithContentsOfFile:[self prefsPath]] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!self.prefs[@"Enable"]) self.prefs[@"Enable"] = @YES;
    if (!self.prefs[@"root"]) self.prefs[@"root"] = @".jbroot/bindfs";
    if (!self.prefs[@"reboot"]) self.prefs[@"reboot"] = @"1";
    if (!self.prefs[@"path"]) self.prefs[@"path"] = [NSMutableArray array];
    else self.prefs[@"path"] = [self.prefs[@"path"] mutableCopy];
}

- (void)savePrefs {
    [self.prefs writeToFile:[self prefsPath] atomically:YES];
}

- (void)toggleEdit {
    [self.tableView setEditing:!self.tableView.editing animated:YES];
}

// 解析路径，检查存在并转绝对路径
- (NSString *)resolvePath:(NSString *)path error:(NSString **)error {
    if (!path.length) {
        if (error) *error = BindFSLoc(@"Please enter a path");
        return nil;
    }
    char resolved[PATH_MAX];
    if (!realpath(path.UTF8String, resolved)) {
        if (error) *error = BindFSLoc(@"Path does not exist");
        return nil;
    }
    return @(resolved);
}

- (void)showPathError:(NSString *)msg {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BindFSLoc(@"Error")
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:BindFSLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (tableView.tag == 999) return 1;  // credits 页面
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView.tag == 999) return 1;  // credits 页面只有一行
    if (section == 0 || section == 2 || section == 3 || section == 4) return 1;
    return [self.prefs[@"path"] count] ?: 1;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 1) return nil;
    
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 40)];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(4, 10, 200, 24)];
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = BindFSLoc(@"PLANNED MOUNTS");
    [header addSubview:label];
    
    UIButton *sortBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sortBtn.frame = CGRectMake(tableView.bounds.size.width - 100, 5, 30, 30);
    [sortBtn setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] forState:UIControlStateNormal];
    [sortBtn addTarget:self action:@selector(toggleEdit) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:sortBtn];

    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.frame = CGRectMake(tableView.bounds.size.width - 60, 5, 30, 30);
    [addBtn setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
    [addBtn addTarget:self action:@selector(showAddPath) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:addBtn];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 1 ? 40 : UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // credits 页面
    if (tableView.tag == 999) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = @"Grok (by xAI)";
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.imageView.image = [UIImage imageNamed:@"grok" inBundle:[NSBundle bundleForClass:[self class]] compatibleWithTraitCollection:nil];
        cell.imageView.layer.cornerRadius = 10;
        cell.imageView.clipsToBounds = YES;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (indexPath.section == 0) {
        cell.textLabel.text = BindFSLoc(@"Enable");
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [self.prefs[@"Enable"] boolValue];
        [sw addTarget:self action:@selector(enableChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        NSArray *paths = self.prefs[@"path"];
        if (paths.count == 0) {
            cell.textLabel.text = BindFSLoc(@"(none)");
            cell.textLabel.textColor = [UIColor secondaryLabelColor];
        } else {
            cell.textLabel.text = paths[indexPath.row];
            cell.textLabel.font = [UIFont systemFontOfSize:14];
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 2) {
        cell.textLabel.text = BindFSLoc(@"Advanced Settings");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 3) {
        cell.textLabel.text = BindFSLoc(@"Reset All Options...");
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
    } else if (indexPath.section == 4) {
        cell.textLabel.text = BindFSLoc(@"Credits");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (tableView.tag == 999) {
        [self openGrok];
        return;
    }
    if (indexPath.section == 2) [self showAdvancedSettings];
    else if (indexPath.section == 3) [self resetAllOptions];
    else if (indexPath.section == 4) [self showCredits];
}

- (void)showAdvancedSettings {
    AdvancedSettingsController *vc = [[AdvancedSettingsController alloc] init];
    vc.prefs = self.prefs;
    vc.saveBlock = ^{ [self savePrefs]; };
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showCredits {
    UITableViewController *vc = [[UITableViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.title = BindFSLoc(@"Credits");
    vc.tableView.delegate = self;
    vc.tableView.dataSource = self;
    vc.tableView.tag = 999;  // 标记为 credits 页面
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openGrok {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://x.ai"] options:@{} completionHandler:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1 || [self.prefs[@"path"] count] == 0) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:BindFSLoc(@"Delete") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self.prefs[@"path"] removeObjectAtIndex:indexPath.row];
        [self savePrefs];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        done(YES);
    }];
    UIContextualAction *edit = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:BindFSLoc(@"Edit") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self editPathAtIndex:indexPath.row];
        done(YES);
    }];
    edit.backgroundColor = [UIColor systemBlueColor];
    UIContextualAction *open = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:BindFSLoc(@"Open") handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self openInFilza:self.prefs[@"path"][indexPath.row]];
        done(YES);
    }];
    open.backgroundColor = [UIColor systemGreenColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[del, edit, open]];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && [self.prefs[@"path"] count] > 0;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;  // 不显示删除按钮
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;  // 编辑时不缩进
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
    if (src.section == 1 && dst.section == 1) {
        NSMutableArray *paths = self.prefs[@"path"];
        id item = paths[src.row];
        [paths removeObjectAtIndex:src.row];
        [paths insertObject:item atIndex:dst.row];
        [self savePrefs];
    }
}

#pragma mark - Input Dialog

- (void)showInputDialog:(NSString *)title text:(NSString *)text completion:(void (^)(NSString *))completion {
    UIViewController *vc = [[UIViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationPageSheet;
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, 300, 30)];
    lbl.text = title;
    lbl.font = [UIFont boldSystemFontOfSize:18];
    [vc.view addSubview:lbl];

    // 固定高度，适配 iPhone 和 iPad
    CGFloat h = MIN(200, [UIScreen mainScreen].bounds.size.height * 0.25);
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(20, 100, vc.view.bounds.size.width - 40, h)];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    tv.font = [UIFont systemFontOfSize:16];
    tv.layer.borderColor = [UIColor separatorColor].CGColor;
    tv.layer.borderWidth = 1;
    tv.layer.cornerRadius = 8;
    tv.text = text ?: @"";
    [vc.view addSubview:tv];

    if (!text.length) {
        UILabel *ph = [[UILabel alloc] initWithFrame:CGRectMake(25, 108, 200, 24)];
        ph.text = BindFSLoc(@"Enter path");
        ph.textColor = [UIColor placeholderTextColor];
        ph.tag = 999;
        [vc.view addSubview:ph];
        // 监听输入隐藏 placeholder
        [[NSNotificationCenter defaultCenter] addObserverForName:UITextViewTextDidChangeNotification
                                                          object:tv
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) {
            ph.hidden = tv.text.length > 0;
        }];
    }

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(20, 110 + h, 80, 44);
    cancel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    [cancel setTitle:BindFSLoc(@"Cancel") forState:UIControlStateNormal];
    cancel.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [cancel addTarget:self action:@selector(dismissInput) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:cancel];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(vc.view.bounds.size.width - 100, 110 + h, 80, 44);
    save.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [save setTitle:BindFSLoc(@"Save") forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    objc_setAssociatedObject(save, "tv", tv, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(save, "cb", completion, OBJC_ASSOCIATION_COPY);
    [save addTarget:self action:@selector(saveInput:) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:save];

    [self presentViewController:vc animated:YES completion:^{ [tv becomeFirstResponder]; }];
}

- (void)dismissInput { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)saveInput:(UIButton *)btn {
    UITextView *tv = objc_getAssociatedObject(btn, "tv");
    void (^cb)(NSString *) = objc_getAssociatedObject(btn, "cb");
    NSString *text = [tv.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self dismissViewControllerAnimated:YES completion:^{ if (cb && text.length) cb(text); }];
}

#pragma mark - Actions

- (void)enableChanged:(UISwitch *)sw {
    self.prefs[@"Enable"] = @(sw.on);
    [self savePrefs];
}

- (void)rootChanged:(UITextField *)tf {
    if (tf.text.length) {
        self.prefs[@"root"] = tf.text;
        [self savePrefs];
    }
}

- (void)showAddPath {
    [self showInputDialog:BindFSLoc(@"Add Path") text:nil completion:^(NSString *text) {
        NSString *err = nil;
        NSString *resolved = [self resolvePath:text error:&err];
        if (!resolved) { [self showPathError:err]; return; }
        if (![self.prefs[@"path"] containsObject:resolved]) {
            [self.prefs[@"path"] addObject:resolved];
            [self savePrefs];
            [self.tableView reloadData];
        }
    }];
}

- (void)editPathAtIndex:(NSInteger)idx {
    [self showInputDialog:BindFSLoc(@"Edit Path") text:self.prefs[@"path"][idx] completion:^(NSString *text) {
        NSString *err = nil;
        NSString *resolved = [self resolvePath:text error:&err];
        if (!resolved) { [self showPathError:err]; return; }
        self.prefs[@"path"][idx] = resolved;
        [self savePrefs];
        [self.tableView reloadData];
    }];
}

- (void)resetAllOptions {
    UIAlertController *c = [UIAlertController alertControllerWithTitle:BindFSLoc(@"Reset All Options")
                                                               message:BindFSLoc(@"Reset all configurations to default?")
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [c addAction:[UIAlertAction actionWithTitle:BindFSLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [c addAction:[UIAlertAction actionWithTitle:BindFSLoc(@"Reset") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        self.prefs[@"root"] = @".jbroot/bindfs";
        self.prefs[@"reboot"] = @"1";
        self.prefs[@"path"] = [NSMutableArray array];
        [self savePrefs];
        [self.tableView reloadData];
    }]];
    [self presentViewController:c animated:YES completion:nil];
}

- (void)mountNow {
    pid_t pid;
    const char *helper = jbroot("/usr/libexec/mount_bindfs/auto-bindfs-prefs");
    const char *argv[] = {helper, "mount", NULL};
    posix_spawn(&pid, argv[0], NULL, NULL, (char **)argv, NULL);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:BindFSLoc(@"BindFS") message:BindFSLoc(@"Mount attempted") preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:BindFSLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)reloadNow {
    NSString *mode = self.prefs[@"reboot"] ?: @"1";
    pid_t pid;
    const char *helper = jbroot("/usr/libexec/mount_bindfs/auto-bindfs-prefs");
    const char *argv[] = {helper, "reboot", mode.UTF8String, NULL};
    posix_spawn(&pid, argv[0], NULL, NULL, (char **)argv, NULL);
}

- (void)openInFilza:(NSString *)path {
    // 检查 Filza 是否安装
    if (![[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"filza://"]]) {
        [self showPathError:BindFSLoc(@"Filza not installed")];
        return;
    }
    NSString *root = self.prefs[@"root"] ?: @".jbroot/bindfs";
    NSString *cleanPath = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    NSString *fullPath;
    const char *resolved;
    
    if ([root hasPrefix:@".jbroot/"]) {
        // .jbroot/ 开头：去掉前缀，用 jbroot() 解析
        NSString *stripped = [root substringFromIndex:8];  // 去掉 ".jbroot/"
        fullPath = [NSString stringWithFormat:@"/%@/%@", stripped, cleanPath];
        resolved = jbroot(fullPath.UTF8String);
    } else if ([root hasPrefix:@"/"]) {
        // / 开头：真实路径，直接拼接
        fullPath = [NSString stringWithFormat:@"%@/%@", root, cleanPath];
        resolved = fullPath.UTF8String;
    } else {
        // 其他情况：当作相对路径用 jbroot()
        fullPath = [NSString stringWithFormat:@"/%@/%@", root, cleanPath];
        resolved = jbroot(fullPath.UTF8String);
    }
    
    // 检查存在
    if (access(resolved, F_OK) != 0) {
        [self showPathError:[NSString stringWithFormat:@"%@\n%@", BindFSLoc(@"Path does not exist, please apply mount first"), @(resolved)]];
        return;
    }
    // 解析成真实路径传给 Filza
    char real[PATH_MAX];
    const char *realPath = realpath(resolved, real) ? real : resolved;
    NSString *url = [NSString stringWithFormat:@"filza://view%@", @(realPath)];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
}

@end
