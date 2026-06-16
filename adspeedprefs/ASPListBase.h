#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Shared base: persistence to the (rootless/rootful aware) prefs plist + specifier
// builder helpers, reused by the root list and the per-app detail page.
@interface ASPListBase : PSListController
+ (NSString *)prefsPathForDomain:(NSString *)domain;
- (BOOL)boolPref:(NSString *)key default:(BOOL)def;
- (void)setBool:(BOOL)value forKey:(NSString *)key;   // write + notify the tweak
- (PSSpecifier *)switchSpecifierNamed:(NSString *)name key:(NSString *)key default:(BOOL)def;
- (PSSpecifier *)subSwitchNamed:(NSString *)name key:(NSString *)key default:(BOOL)def;
- (PSSpecifier *)groupNamed:(NSString *)name footer:(NSString *)footer;
- (PSSpecifier *)numberFieldNamed:(NSString *)name key:(NSString *)key default:(id)def;
@end
