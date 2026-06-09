#import "ASPRootListController.h"
#import <objc/runtime.h>

static NSString *const kDomain = @"com.34306.adspeed";
static NSString *const kNotify = @"com.34306.adspeed/reloadPrefs";

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

// Persist directly to the domain plist so it works regardless of the base class /
// iOS version, and lands exactly where the tweak reads it
// (/var/mobile/Library/Preferences/com.34306.adspeed.plist).
- (NSString *)prefsPathForSpecifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"] ?: kDomain;
    // Store under the jailbreak root. Sandboxed App Store apps cannot read
    // /var/mobile/Library/Preferences, but the rootless sandbox profile grants
    // them read access to /var/jb, so the injected tweak can read it there.
    return [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%@.plist", domain];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[self prefsPathForSpecifier:specifier]];
    id value = settings[[specifier propertyForKey:@"key"]];
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *path = [self prefsPathForSpecifier:specifier];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    settings[[specifier propertyForKey:@"key"]] = value;
    [settings writeToFile:path atomically:YES];

    NSString *notification = [specifier propertyForKey:@"PostNotification"];
    if (notification) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)notification, NULL, NULL, YES);
    }

    // Master/sub switches reveal or hide their dependent rows, so rebuild the list.
    NSString *changed = [specifier propertyForKey:@"key"];
    if ([changed isEqualToString:@"SpeedUpVideo"] || [changed isEqualToString:@"CompressTimers"]) {
        _specifiers = nil;
        [self reloadSpecifiers];
    }
}

- (BOOL)boolPref:(NSString *)key default:(BOOL)def {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        [NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%@.plist", kDomain]];
    id v = d[key];
    return v ? [v boolValue] : def;
}

// A switch shown as an indented sub-item of the row above it.
- (PSSpecifier *)subSwitchNamed:(NSString *)name key:(NSString *)key default:(BOOL)def {
    PSSpecifier *s = [self switchSpecifierNamed:[@"      " stringByAppendingString:name] key:key default:def];
    [s setProperty:@1 forKey:@"indentationLevel"];
    return s;
}

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

- (PSSpecifier *)switchSpecifierNamed:(NSString *)name key:(NSString *)key default:(BOOL)def {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:name
                                                   target:self
                                                      set:@selector(setPreferenceValue:specifier:)
                                                      get:@selector(readPreferenceValue:)
                                                   detail:nil
                                                     cell:PSSwitchCell
                                                     edit:nil];
    [s setProperty:kDomain forKey:@"defaults"];
    [s setProperty:kNotify forKey:@"PostNotification"];
    [s setProperty:key forKey:@"key"];
    [s setProperty:@(def) forKey:@"default"];
    return s;
}

- (PSSpecifier *)groupNamed:(NSString *)name footer:(NSString *)footer {
    PSSpecifier *g = [PSSpecifier groupSpecifierWithName:name];
    if (footer) [g setProperty:footer forKey:@"footerText"];
    return g;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[self groupNamed:@"General"
                                   footer:@"Choose which apps Ads Speed runs in below. "
                                          @"Changes take effect next time the app is launched."]];
        [specs addObject:[self switchSpecifierNamed:@"Enabled" key:@"Enabled" default:YES]];
        [specs addObject:[self switchSpecifierNamed:@"Block ads" key:@"BlockAds" default:YES]];
        [specs addObject:[self switchSpecifierNamed:@"Bypass jailbreak detection" key:@"BypassJailbreak" default:YES]];

        BOOL speedOn  = [self boolPref:@"SpeedUpVideo" default:YES];
        BOOL timersOn = [self boolPref:@"CompressTimers" default:NO];

        // Fast-forward + its native sub-option.
        [specs addObject:[self groupNamed:@"Fast-forward ads"
                                   footer:@"Plays reward-ad video faster, keeping the reward. "
                                          @"“Include native video” also speeds in-game cutscenes if a game has them."]];
        [specs addObject:[self switchSpecifierNamed:@"Fast-forward ads" key:@"SpeedUpVideo" default:YES]];
        if (speedOn) {
            [specs addObject:[self subSwitchNamed:@"Include native video" key:@"SpeedNativeVideo" default:YES]];
        }

        // Separate section for the aggressive countdown options (+ its clock sub-option).
        if (speedOn) {
            [specs addObject:[self groupNamed:@"Ad countdowns (playables)"
                                       footer:@"For timer-gated playable ads. “Accelerate clock” also speeds "
                                              @"wall-clock timers. Both can void the reward on video ads."]];
            [specs addObject:[self switchSpecifierNamed:@"Rush ad countdowns" key:@"CompressTimers" default:NO]];
            if (timersOn) {
                [specs addObject:[self subSwitchNamed:@"Accelerate clock" key:@"AccelerateClock" default:NO]];
            }
        }

        // Video speed multiplier (numeric text field).
        [specs addObject:[self groupNamed:@"Speed"
                                   footer:@"How many times faster (default 8). If a reward stops counting, "
                                          @"lower it to 3–4 — high speeds can skip the ad's completion event."]];
        PSSpecifier *rate = [PSSpecifier preferenceSpecifierNamed:@"Multiplier"
                                                           target:self
                                                              set:@selector(setPreferenceValue:specifier:)
                                                              get:@selector(readPreferenceValue:)
                                                           detail:nil
                                                             cell:PSEditTextCell
                                                             edit:nil];
        [rate setProperty:kDomain forKey:@"defaults"];
        [rate setProperty:kNotify forKey:@"PostNotification"];
        [rate setProperty:@"VideoRate" forKey:@"key"];
        [rate setProperty:@(8) forKey:@"default"];
        [rate setProperty:@YES forKey:@"isNumeric"];
        [rate setProperty:@(UIKeyboardTypeNumberPad) forKey:@"keyboardType"];
        [specs addObject:rate];

        // One switch per installed app.
        [specs addObject:[self groupNamed:@"Apps" footer:nil]];
        for (NSDictionary *app in [self installedUserApps]) {
            NSString *key = [@"enabled-" stringByAppendingString:app[@"id"]];
            [specs addObject:[self switchSpecifierNamed:app[@"name"] key:key default:NO]];
        }

        _specifiers = [specs copy];
    }
    return _specifiers;
}

@end
