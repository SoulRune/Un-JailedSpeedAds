#import "ASPRootListController.h"
#import "ASPAppListController.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// Minimal private API surface for enumerating installed apps.
@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

@implementation ASPRootListController

- (NSArray *)installedUserApps {
    LSApplicationWorkspace *ws = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
    NSMutableArray *result = [NSMutableArray array];
    for (LSApplicationProxy *app in [ws allApplications]) {
        if (![app.applicationType isEqualToString:@"User"]) continue;
        NSString *bid = app.applicationIdentifier;
        NSString *name = app.localizedName ?: bid;
        if (bid.length) [result addObject:@{ @"id": bid, @"name": name }];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return result;
}

- (BOOL)appEnabled:(NSString *)bid {
    return [self boolPref:[@"enabled-" stringByAppendingString:bid] default:NO];
}

// A row that opens the per-app detail page.
- (PSSpecifier *)appLinkFor:(NSDictionary *)app {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:app[@"name"]
                                                   target:self
                                                      set:NULL
                                                      get:NULL
                                                   detail:[ASPAppListController class]
                                                     cell:PSLinkCell
                                                     edit:nil];
    [s setProperty:@YES forKey:@"isController"];
    [s setProperty:app[@"id"] forKey:@"bid"];
    return s;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[self groupNamed:@"Ads Speed"
                                   footer:@"Tap an app to configure it. Enabled apps are highlighted and listed on "
                                          @"top. Changes apply next time the app is launched."]];
        [specs addObject:[self switchSpecifierNamed:@"Enabled (master)" key:@"Enabled" default:YES]];

        NSMutableArray *on = [NSMutableArray array], *off = [NSMutableArray array];
        for (NSDictionary *app in [self installedUserApps]) {
            [([self appEnabled:app[@"id"]] ? on : off) addObject:app];
        }

        if (on.count) {
            [specs addObject:[self groupNamed:@"Enabled" footer:nil]];
            for (NSDictionary *app in on) [specs addObject:[self appLinkFor:app]];
        }
        [specs addObject:[self groupNamed:@"Not enabled" footer:nil]];
        for (NSDictionary *app in off) [specs addObject:[self appLinkFor:app]];

        [specs addObject:[self groupNamed:@"" footer:@"Resets every app's settings and disables all apps."]];
        PSSpecifier *reset = [PSSpecifier preferenceSpecifierNamed:@"Reset all settings"
                                                           target:self
                                                              set:NULL
                                                              get:NULL
                                                           detail:NULL
                                                             cell:PSButtonCell
                                                             edit:NULL];
        reset->action = @selector(resetSettings);
        [reset setProperty:@YES forKey:@"enabled"];
        [specs addObject:reset];

        _specifiers = [specs copy];
    }
    return _specifiers;
}

// Wipe the prefs plist (with confirmation), so every setting returns to its default.
- (void)resetSettings {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset all settings?"
                                                              message:@"This clears every app's settings and disables all apps."
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *act) {
        [[NSFileManager defaultManager] removeItemAtPath:[ASPListBase prefsPathForDomain:@"com.34306-sr.adspeed"] error:nil];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.34306-sr.adspeed/reloadPrefs"), NULL, NULL, YES);
        self->_specifiers = nil;
        [self reloadSpecifiers];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// Re-sort the Enabled / Not enabled sections after returning from a detail page.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;
    [self reloadSpecifiers];
}

// Highlight enabled apps (green) in addition to the section split. Read the specifier
// straight off the cell (PSTableCell exposes -specifier) to avoid relying on
// -specifierAtIndexPath:, which isn't present on every Preferences version.
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![cell respondsToSelector:@selector(specifier)]) return;
    PSSpecifier *spec = [(id)cell specifier];
    NSString *bid = [spec propertyForKey:@"bid"];
    if (bid) {
        cell.textLabel.textColor = [self appEnabled:bid] ? [UIColor systemGreenColor] : [UIColor labelColor];
    }
}

@end
