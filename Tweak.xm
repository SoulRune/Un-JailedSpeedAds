// Ads Speed - rewritten 2.1
//
// Two ways to ship this:
//   1) As a .deb  -> injected into every UIKit app via the filter (adspeed.plist),
//                    then gated at runtime per-app from the Settings panel.
//   2) Statically injected into a single .ipa (e.g. TrollFools). For that build,
//      compile with -DADSPEED_FORCE_ON so it is always active and ignores prefs.
//
// Blocking, per app:
//   - "Block ads": "is the ad ready" checks of known ad SDK classes return NO, so the app
//     skips the ad. Show/present calls are never stubbed (the app would wait forever).
//   - "Block ad servers" (off by default): requests to known ad hosts fail like a DNS
//     block, after a delay so SDK retry loops can't spin. Ads that wait for a load may
//     then never show.
// Video is sped up only while a known ad view-controller is on screen (aspAdDepth).
// "Block App Store" (off by default): no store sheet / overlay / redirect from ads, and no
// links out while an ad is on screen.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#pragma mark - Preferences

static NSString *const kKeyMaster     = @"Enabled";        // master on/off, default YES
static NSString *const kKeyBlockAds   = @"BlockAds";       // SDK "ready" stubs, default NO
static NSString *const kKeyBlockNet   = @"BlockAdServers"; // block ad hosts, default NO
static NSString *const kKeyBlockStubsOld = @"BlockAdsStubs"; // interim name of BlockAds, still read
static NSString *const kKeyBlockStore = @"BlockStore";     // no App Store from ads, default NO
static NSString *const kKeySpeedVideo = @"SpeedUpVideo";   // speed up ad video, default YES
static NSString *const kKeyVideoRate  = @"VideoRate";      // playback multiplier
static const float kDefaultVideoRate = 5.0f;               // higher rates cost noticeably more CPU
static NSString *const kKeyWebTimers  = @"CompressTimers"; // compress JS setTimeout/setInterval, default NO
static NSString *const kKeyWebClock   = @"AccelerateClock"; // also run Date.now/performance.now fast, default NO
static NSString *const kKeyForceInline = @"ForceInline";   // force webview video inline (for stuck fullscreen video), default NO
static NSString *const kKeySpeedNative= @"SpeedNativeVideo";// speed every AVPlayer, not just detected ad VCs, default NO
static NSString *const kKeyBypassJB   = @"BypassJailbreak";// jailbreak-detect bypass, default YES
static NSString *const kKeyAppPrefix  = @"enabled-";       // per-app key: enabled-<bundleID>

// Runtime state, resolved once at launch.
static BOOL  gActive      = NO;
static BOOL  gSpeedVideo  = YES;
static BOOL  gWebTimers   = NO;
static BOOL  gWebClock    = NO;
static BOOL  gForceInline  = NO;
static BOOL  gSpeedNative  = NO;
static float gVideoRate  = kDefaultVideoRate;
static BOOL  gBlockNet   = NO;    // block ad hosts
static BOOL  gBlockStore = NO;    // block App Store sheets / redirects from ads

static NSDictionary *loadPrefs(void) {
    // The Settings panel writes via CFPreferences for the mobile user; read the plist
    // directly so it works regardless of sandbox/CFPreferences quirks. Try rootless
    // first, then rootful.
    NSArray *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.soulrune.adspeed.plist",
        @"/var/mobile/Library/Preferences/com.soulrune.adspeed.plist",
    ];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) return d;
    }
    return nil;
}

static BOOL prefBool(NSDictionary *p, NSString *key, BOOL fallback) {
    id v = p[key];
    return v ? [v boolValue] : fallback;
}

// Per-app preference key: "<bundleID>-<Suffix>" (e.g. com.x.game-SpeedUpVideo).
static NSString *appKey(NSString *bid, NSString *suffix) {
    return [NSString stringWithFormat:@"%@-%@", bid, suffix];
}

#pragma mark - Debug (build with -DADSPEED_DEBUG)

#ifdef ADSPEED_DEBUG
// Logs to the system log AND to <app sandbox>/tmp/adspeed.log (always writable,
// retrieve it over SSH with:
//   find /var/mobile/Containers/Data/Application -name adspeed.log)
static void aspLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AdSpeed] %@", msg);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"adspeed.log"];
    NSString *line = [msg stringByAppendingString:@"\n"];
    // Truncate once per process launch, then append within the launch, so each file
    // only holds the most recent run instead of accumulating across respawns.
    static BOOL truncated = NO;
    FILE *f = fopen(path.UTF8String, truncated ? "a" : "w");
    truncated = YES;
    if (f) { fputs(line.UTF8String, f); fclose(f); }
}

#endif // ADSPEED_DEBUG

// Class dump is opt-in (build with -DADSPEED_DUMP -DADSPEED_DEBUG): calling
// objc_copyClassList crashes some apps (e.g. Idle Sword Master), so keep it out of
// the normal debug build.
#ifdef ADSPEED_DUMP
static void aspDumpAdClasses(void) {
    // Specific tokens only — loose ones (MAX, ISA, MTG, Interstitial) match tons of
    // system classes (MAXpcManager, UISApplicationState, MPS...MTGP32, AVPlayerInterstitial).
    NSArray *kw = @[@"AppLovin", @"ALSdk", @"MAInterstitial", @"MARewarded", @"MANative", @"MAAppOpen",
                    @"IronSource", @"LevelPlay", @"ISInterstitial", @"ISRewardedVideo", @"ISBannerAd",
                    @"Mintegral", @"MTGInterstitial", @"MTGReward", @"MTGBid", @"MTGBanner", @"MTGNative",
                    @"InMobi", @"IMInterstitial", @"IMBanner", @"IMNative", @"IMRewarded",
                    @"UnityAds", @"UADSBanner",
                    @"GADInterstitial", @"GADRewarded", @"GADAppOpen", @"GADNativeAd",
                    @"Vungle", @"AdColony", @"Chartboost", @"PAGInterstitial", @"BUNativeAd",
                    @"Fyber", @"Tapjoy"];
    unsigned int n = 0;
    Class *cls = objc_copyClassList(&n);
    int hits = 0;
    for (unsigned i = 0; i < n; i++) {
        NSString *name = @(class_getName(cls[i]));
        for (NSString *k in kw) {
            if ([name containsString:k]) { aspLog(@"  class: %@", name); hits++; break; }
        }
    }
    free(cls);
    aspLog(@"ad-like classes found: %d", hits);
}
#endif

#pragma mark - Typed stubs

// NO / nil / 0 are bit-identical in x0 on arm64, but naming the intent keeps the
// hook table readable and avoids surprises if this is ever ported.
static BOOL returnFalse(__unused id self, __unused SEL _cmd) { return NO; }
static BOOL returnTrue (__unused id self, __unused SEL _cmd) { return YES; }
static id   returnNil  (__unused id self, __unused SEL _cmd) { return nil; }
static void returnVoid (__unused id self, __unused SEL _cmd) { }

// StubBOOL -> NO ("not ready"), StubTRUE -> YES ("expired").
typedef enum { StubBOOL, StubNil, StubVoid, StubTRUE } StubType;
typedef struct { const char *cls; const char *sel; StubType type; } AdHook;

static IMP stubFor(StubType t) {
    return (t == StubNil)  ? (IMP)returnNil
         : (t == StubVoid) ? (IMP)returnVoid
         : (t == StubTRUE) ? (IMP)returnTrue
                           : (IMP)returnFalse;
}

static void installHook(const AdHook *h) {
    Class c = objc_getClass(h->cls);
    if (!c) return;
    SEL s = sel_registerName(h->sel);
    // Only retarget a method the class actually implements - never add new methods,
    // which would alter -respondsToSelector: behaviour.
    if (!class_getInstanceMethod(c, s)) return;
    MSHookMessageEx(c, s, stubFor(h->type), NULL);
}

// Same, but for class methods (e.g. +[IronSource hasRewardedVideo]): hook the metaclass.
static void installClassHook(const AdHook *h) {
    Class c = objc_getClass(h->cls);
    if (!c) return;
    SEL s = sel_registerName(h->sel);
    if (!class_getClassMethod(c, s)) return;
    MSHookMessageEx(object_getClass(c), s, stubFor(h->type), NULL);
}

static void installAll(const AdHook *table, size_t n) {
    for (size_t i = 0; i < n; i++) installHook(&table[i]);
}

static void installAllClass(const AdHook *table, size_t n) {
    for (size_t i = 0; i < n; i++) installClassHook(&table[i]);
}

#pragma mark - Ad-SDK blocking table

static const AdHook kAdHooks[] = {
    // Generic / app-specific ad managers
    {"GADAdSource", "invalidated", StubBOOL},
    {"ALMediationServiceAdDelegateProxy", "didLoadAd:withExtraInfo:", StubVoid},
    {"AdsHandler", "pauseAll:", StubVoid},
    {"AdsHandler", "clear", StubVoid},
    {"AdsHandler", "setPossibleAdsPerHour:", StubVoid},
    {"AdsHandler", "init", StubNil},
    {"AdsHandler", "clearTimeSinceLiveStarted", StubVoid},
    {"AdsHandler", "updateTimeSinceLiveStarted", StubVoid},
    {"BasePlayerView", "OnPlayer_AdStarted:", StubVoid},
    {"FullScreenViewTVAIS", "getLastPlayedChannel", StubNil},
    {"FullScreenViewTVAIS", "startPlayChannel:forceStart:", StubVoid},
    {"RFQVideoPlayer", "checkIsPreviewEnded", StubBOOL},
    {"RFQVideoPlayerAd", "onAdStartedPlay", StubVoid},
    {"RFQVideoPlayerAd", "adShouldStartPlay", StubBOOL},
    {"RFQVideoPlayerAd", "setAdShouldStartPlay:", StubVoid},
    {"RSVodHead", "isPreview", StubBOOL},
    {"RSVodHead", "isPreviewEnded", StubBOOL},
    {"RSVodHead", "setIsPreview:", StubVoid},
    {"RSVodHead", "setIsPreviewEnded:", StubVoid},
    {"TAGPreviewManager", "isPreviewingContainer:", StubBOOL},
    {"TabBarBaseVC", "OnHeadLoadSuccess", StubVoid},
    {"UMPConsentInformation", "canRequestAds", StubBOOL},
    {"XmppVCardInfo", "hasAnyAds", StubBOOL},
    {"XmppVCardInfo", "hasNativeAds", StubBOOL},
    {"XmppVCardInfo", "hasRegularAds", StubBOOL},

    // Snap ad cache / serve
    {"SCSnapAdsAdResponsePersistentCache", "_getAdResponse:removeAdResponseOnHit:", StubNil},
    {"SCSnapAdsAdSourceConfig", "shouldDisableServeRequest", StubBOOL},
    {"SCSnapAdsAdSourceConfig", "protoServeEndpoint", StubNil},
    {"SCSnapAdsAdSourceConfig", "protoInitEndpoint", StubNil},
    {"SCSnapAdsDynamicAdMediaManagerImpl", "removeMediaDataSource:", StubVoid},
    {"SCSnapAdsOnDeviceInfoRecordCoordinator", "_handleRemoveOnDeviceInfoRecordsWithSuccess:completionBlock:", StubVoid},
    {"SCSnapAdsOnDeviceInfoRecordCoordinator", "removeAllOnDeviceInfoRecordsForSaid:completionQueue:completionBlock:", StubVoid},
    {"SCSnapAdsServeResponseDataStore", "_removeAdResponseForIdentifier:", StubVoid},
    {"SCSnapAdsServeResponseDataStore", "removeAdResponseForIdentifier:", StubVoid},

    // Vungle
    {"VungleURLConfiguration", "setAdsURL:", StubVoid},

    // Mintegral (MTG*) — selectors verified against the AppLovin↔Mintegral adapter.
    // Old interstitial-video + rewarded managers (this is what Tycoon Empire uses):
    {"MTGInterstitialVideoAdManager", "isVideoReadyToPlayWithPlacementId:unitId:", StubBOOL},
    {"MTGBidInterstitialVideoAdManager", "isVideoReadyToPlayWithPlacementId:unitId:", StubBOOL},
    {"MTGRewardAdManager", "isVideoReadyToPlayWithPlacementId:unitId:", StubBOOL},
    {"MTGBidRewardAdManager", "isVideoReadyToPlayWithPlacementId:unitId:", StubBOOL},
    // New interstitial managers use -isAdReady:
    {"MTGNewInterstitialAdManager", "isAdReady", StubBOOL},
    {"MTGNewInterstitialBidAdManager", "isAdReady", StubBOOL},
    // Splash / app-open:
    {"MTGSplashAD", "isBiddingADReadyToShow", StubBOOL},

    // Misc
    {"FPUserCredentials", "adremoval_enabled", StubBOOL},

    // AppLovin (AL* / MA*)
    {"ALIncentivizedInterstitialAd", "isReadyForDisplay", StubBOOL},
    {"ALMediatedAd", "isReady", StubBOOL},
    {"ALStoreKitProductViewController", "isReady", StubBOOL},
    {"ALStoreProductViewControllerWrapper", "isReady", StubBOOL},
    {"ALDCreativeDebuggerTableViewDataSource", "initializeWithDisplayedAds:", StubVoid},
    {"ALMediationAdLoadCoordinator", "didLoadAd:", StubVoid},
    {"ALMediationSetting", "fullscreenAdShouldReturnReadyWhenAdLoadIsInProgress", StubBOOL},
    {"ALAdLoadState", "isWaitingForAd", StubBOOL},
    {"ALAdLoadState", "setIsWaitingForAd:", StubVoid},
    {"ALAdService", "hasPreloadedAdOfSize:", StubBOOL},
    {"ALAdService", "hasPreloadedAdForZoneIdentifier:", StubBOOL},
    {"ALFullScreenAdTracker", "isFullScreenAdShowing", StubBOOL},
    {"ALMediationAdLoadState", "isWaitingForAd", StubBOOL},
    {"ALMediationAdLoadState", "setIsWaitingForAd:", StubVoid},
    {"ALMediationAdapterRouter", "isAdShowingForAdapter:", StubBOOL},
    {"ALNativeAdService", "loadNextAdAndNotify:", StubVoid},
    {"MAAd", "isReady", StubBOOL},
    {"MAAppOpenAd", "isReady", StubBOOL},
    {"MAFullscreenAdController", "isReady", StubBOOL},
    {"MAInterstitialAd", "isReady", StubBOOL},
    {"MARewardedAd", "isReady", StubBOOL},
    {"MARewardedInterstitialAd", "isReady", StubBOOL},
    {"MANativeAdSource", "isAdLoading", StubBOOL},

    // Meta Audience Network
    {"FBAdDSLBridgeViewController", "isReadyToPresent", StubBOOL},

    // Google IMA
    {"IMAAd", "isSkippable", StubBOOL},
    {"IMAAd", "isUiDisabled", StubBOOL},

    // ironSource (IS*)
    {"ISAdMobBannerAdapter", "isLargeScreen", StubBOOL},
    {"ISBaseAdUnitInteractionSmash", "isReadyToShow", StubBOOL},
    {"ISBaseAdUnitManager", "isReadyToShow", StubBOOL},
    {"ISBaseAdUnitSmash", "isReadyToShow", StubBOOL},
    {"ISDemandOnlyIsSmash", "isReadyToShow", StubBOOL},
    {"ISDemandOnlyRvSmash", "isReadyToShow", StubBOOL},
    {"ISLWSProgRvSmash", "isReadyToShow", StubBOOL},
    {"ISProgIsSmash", "isReadyToShow", StubBOOL},

    // Google AdMob (GAD*)
    // The init -> nil and viewWillAppear: stubs are blunt; kept for older GMA versions.
    {"GADView", "initWithFrame:context:", StubNil},
    {"GADBannerAd", "adView", StubNil},
    {"GADBannerAd", "videoController", StubNil},
    {"GADCustomEventBannerAdRenderer", "renderWithServerTransaction:adConfiguration:completionHandler:", StubVoid},
    {"GADFullScreenAdViewController", "viewWillAppear:", StubVoid},
    {"GADFullScreenAdViewController", "presented", StubBOOL},
    {"GADFullScreenAdViewController", "canPresentFromViewController:error:", StubBOOL},
    {"GADInlineInterstitialAdRenderer", "renderWithServerTransaction:adConfiguration:completionHandler:", StubVoid},
    {"GADInlineMultipleNativeAdsRenderer", "renderWithServerTransaction:adConfiguration:completionHandler:", StubVoid},
    {"GADInlineMultipleNativeAdsRenderer", "init", StubNil},
    {"GADMediationBannerAdRenderer", "renderWithServerTransaction:adConfiguration:completionHandler:", StubVoid},
    {"GADMediationBannerAdRenderer", "adapter:didReceiveAdView:", StubVoid},
    {"GADRTBMediationBannerAdRenderer", "renderWithServerTransaction:adConfiguration:completionHandler:", StubVoid},
    {"GADUnifiedMediationBannerAdRenderer", "renderWithServerTransaction:adConfiguration:completionHandler:", StubVoid},
    {"GADInlineBannerAdRenderer", "renderWithServerTransaction:adConfiguration:completionHandler:", StubVoid},
    {"GADAdRenderResult", "rendererClassString", StubNil},
    {"GADAdRenderResult", "setRendererClassString:", StubVoid},
    {"GADInlineSingleNativeAdRenderer", "init", StubNil},
    {"GADInternalBannerView", "callBackAdViewDidReceiveAd", StubVoid},
    {"GADMediatedAdRenderer", "adapter:didReceiveAdView:", StubVoid},
    {"GADBannerView", "bannerViewDidReceiveAd:", StubVoid},
    {"GADBannerView", "bannerView:didFailToReceiveAdWithError:", StubVoid},
    {"GADBannerView", "bannerViewDidRecordImpression:", StubVoid},
    {"GADBannerView", "bannerViewWillPresentScreen:", StubVoid},
    {"GADBannerView", "adViewIntrinsicContentSizeDidChange:", StubVoid},
    {"GADBannerView", "setAutoloadEnabled:", StubVoid},
    {"GADBannerView", "setAdUnitID:", StubVoid},
    {"GADBannerView", "loadRequest:", StubVoid},

    // OMID (Open Measurement) ad sessions
    {"GADOMIDAdSessionRegistry", "isActive", StubBOOL},
    {"GADOMIDAdSessionRegistry", "removeAdSession:", StubVoid},
    {"GADOMIDAdSessionRegistry", "adSessions", StubNil},
    {"GADOMIDAdSessionRegistry", "activeAdSessions", StubNil},
    {"GADOMIDAdSessionRegistry", "addAdSession:", StubVoid},
    {"GADMinimumVersionSupport", "OSIsSupported", StubBOOL},

    // React Native Google Mobile Ads
    {"RNGoogleMobileAdsBannerComponent", "didSetProps:", StubVoid},
    {"RNGoogleMobileAdsBannerComponent", "banner", StubNil},
    {"RNGoogleMobileAdsBannerComponent", "requested", StubBOOL},
    {"RNGoogleMobileAdsBannerComponent", "setBanner:", StubVoid},
    {"RNGoogleMobileAdsBannerComponent", "request", StubVoid},
    {"RNGoogleMobileAdsBannerComponent", "propsChanged", StubBOOL},
    {"RNGoogleMobileAdsBannerComponent", "onNativeEvent", StubVoid},
    {"RNGoogleMobileAdsBannerComponent", "setPropsChanged:", StubVoid},
    {"RNGoogleMobileAdsBannerViewManager", "view", StubNil},
    {"RNGoogleMobileAdsBannerViewManager", "methodQueue", StubNil},
    {"RNGoogleMobileAdsBannerViewManager", "propConfig_unitId", StubNil},
    {"RNGoogleMobileAdsBannerViewManager", "propConfig_sizes", StubNil},
    {"RNGoogleMobileAdsBannerViewManager", "propConfig_onNativeEvent", StubNil},
    {"RNGoogleMobileAdsBannerViewManager", "propConfig_manualImpressionsEnabled", StubNil},
    {"RNGoogleMobileAdsBannerViewManager", "recordManualImpression:", StubVoid},
    {"RNGoogleMobileAdsBannerViewManager", "bridge", StubNil},
    {"RNGoogleMobileAdsBannerViewManager", "propConfig_request", StubNil},

    // App-specific banner
    {"_TtC9BusTaiwan20YBGoogleBannerAdView", "loadAd", StubVoid},

    // Personalised ads config
    {"APMPersistedConfig", "allowPersonalizedAds", StubBOOL},

    // ===================================================================
    // Current ad SDKs (2024-2026). Each entry neutralises a "ready / valid /
    // cached / can-present" check so the host app believes no ad is available.
    // Names are from public SDK APIs; versions vary, so misses are silent no-ops.
    // Swift-only SDKs (Unity Ads, new InMobiSDK.*, new GoogleMobileAds Swift)
    // can't be reached this way — see the web speed-up path for those.
    // ===================================================================

    // Meta Audience Network (FAN)
    {"FBInterstitialAd", "isAdValid", StubBOOL},
    {"FBRewardedVideoAd", "isAdValid", StubBOOL},
    {"FBRewardedInterstitialAd", "isAdValid", StubBOOL},
    {"FBNativeAd", "isAdValid", StubBOOL},

    // Google AdMob / Google Mobile Ads (ObjC GAD*) — block full-screen presentation
    {"GADInterstitialAd", "canPresentFromRootViewController:error:", StubBOOL},
    {"GADRewardedAd", "canPresentFromRootViewController:error:", StubBOOL},
    {"GADRewardedInterstitialAd", "canPresentFromRootViewController:error:", StubBOOL},
    {"GADAppOpenAd", "canPresentFromRootViewController:error:", StubBOOL},

    // ironSource LevelPlay (newer instance API; class API is in kAdClassHooks)
    {"LPMInterstitialAd", "isAdReady", StubBOOL},
    {"LPMRewardedAd", "isAdReady", StubBOOL},

    // Vungle / Liftoff Monetize
    {"VungleInterstitial", "canPlayAd", StubBOOL},
    {"VungleRewarded", "canPlayAd", StubBOOL},
    {"VungleInterstitialAd", "canPlayAd", StubBOOL},
    {"VungleRewardedAd", "canPlayAd", StubBOOL},
    {"VungleSDK", "isAdCachedForPlacementID:", StubBOOL},
    {"VungleSDK", "isAdCachedForPlacementID:adMarkup:", StubBOOL},

    // Chartboost
    {"CHBInterstitial", "isCached", StubBOOL},
    {"CHBRewarded", "isCached", StubBOOL},
    {"CHBBanner", "isCached", StubBOOL},

    // Tapjoy
    {"TJPlacement", "isContentReady", StubBOOL},
    {"TJPlacement", "isContentAvailable", StubBOOL},

    // Pangle (ByteDance). New PAG* API has no readiness flag — block the show call
    // (presentFromRootViewController:). Older "BU" SDK exposes a validity flag.
    {"PAGLInterstitialAd", "presentFromRootViewController:", StubVoid},
    {"PAGRewardedAd", "presentFromRootViewController:", StubVoid},
    {"PAGAppOpenAd", "presentFromRootViewController:", StubVoid},
    {"BUFullscreenVideoAd", "isAdValid", StubBOOL},
    {"BURewardedVideoAd", "isAdValid", StubBOOL},
    {"BUNativeExpressFullscreenVideoAd", "isAdValid", StubBOOL},

    // InMobi (older ObjC SDK; the new InMobiSDK.* is Swift and not reachable here)
    {"IMInterstitial", "isReady", StubBOOL},

    // AdColony (legacy, still embedded via DT mediation)
    {"AdColonyInterstitial", "expired", StubTRUE},

    // Smaato
    {"SMAInterstitial", "isAvailableForPresentation", StubBOOL},
    {"SMARewardedInterstitial", "isAvailableForPresentation", StubBOOL},

    // Yandex Mobile Ads (RU) — block the loaded ad presentation gate where present
    {"YMAInterstitialAd", "isLoaded", StubBOOL},
    {"YMARewardedAd", "isLoaded", StubBOOL},

    // Bigo Ads
    {"BigoInterstitialAd", "isExpired", StubTRUE},
    {"BigoRewardVideoAd", "isExpired", StubTRUE},

    // ===================================================================
    // GMA 13, AppLovin 13, LevelPlay 9, Vungle 7, Pangle 8, Mintegral 8, InMobi 11,
    // Chartboost 9, Moloco 4, Ogury, MobileFuse, Start.io, Smaato 10, Tapjoy 14.
    // Readiness checks only: a stubbed show/present call would leave the app waiting for
    // a callback that never comes. Swift classes use their runtime (mangled) names.
    // ===================================================================

    // Google Mobile Ads 12/13
    // Preloader API (GAD*AdPreloader sharedInstance)
    {"GADInterstitialAdPreloader", "isAdAvailableWithPreloadID:", StubBOOL},
    {"GADInterstitialAdPreloader", "adWithPreloadID:", StubNil},
    {"GADRewardedAdPreloader", "isAdAvailableWithPreloadID:", StubBOOL},
    {"GADRewardedAdPreloader", "adWithPreloadID:", StubNil},
    {"GADRewardedInterstitialAdPreloader", "isAdAvailableWithPreloadID:", StubBOOL},
    {"GADRewardedInterstitialAdPreloader", "adWithPreloadID:", StubNil},
    {"GADAppOpenAdPreloader", "isAdAvailableWithPreloadID:", StubBOOL},
    {"GADAppOpenAdPreloader", "adWithPreloadID:", StubNil},

    // AppLovin MAX 13

    // ironSource LevelPlay 8/9

    // Liftoff / Vungle 7 (Swift)
    {"_TtC12VungleAdsSDK12BasePublicAd", "canPlayAd", StubBOOL},

    // Pangle 7/8

    // Mintegral 7/8
    {"MTGInterstitialVideoAdManager", "isVideoReadyToPlayWithPlacementId:unitId:", StubBOOL},
    {"MTGBidInterstitialVideoAdManager", "isVideoReadyToPlayWithPlacementId:unitId:", StubBOOL},
    {"MTGSplashAD", "isADReadyToShow", StubBOOL},

    // InMobi 10/11 (Swift)
    {"_TtC9InMobiSDK14IMInterstitial", "isReady", StubBOOL},

    // Chartboost 9

    // Moloco 3/4 (Swift)
    {"_TtC9MolocoSDK21PublisherFullscreenAd", "isReady", StubBOOL},

    // Ogury
    {"OguryInterstitialAd", "isLoaded", StubBOOL},
    {"OguryRewardedAd", "isLoaded", StubBOOL},
    {"OguryThumbnailAd", "isLoaded", StubBOOL},

    // MobileFuse
    {"MFInterstitialAd", "isAdReady", StubBOOL},
    {"MFRewardedAd", "isAdReady", StubBOOL},

    // Start.io (StartApp)
    {"STAStartAppAd", "isReady", StubBOOL},

    // Smaato 10 (iSoma)
    {"SOMAInterstitialAdView", "isReady", StubBOOL},
    {"SOMAInterstitialVideoAdView", "isReady", StubBOOL},
    {"SOMAMultiFormatInterstitial", "isReady", StubBOOL},

    // Tapjoy
};

// Class-method "is ready" checks (hook the metaclass).
static const AdHook kAdClassHooks[] = {
    // ironSource classic (mediation + DemandOnly) — all class methods returning BOOL
    {"IronSource", "hasRewardedVideo", StubBOOL},
    {"IronSource", "hasInterstitial", StubBOOL},
    {"IronSource", "hasISDemandOnlyInterstitial:", StubBOOL},
    {"IronSource", "hasISDemandOnlyRewardedVideo:", StubBOOL},

    // Digital Turbine FairBid (formerly Fyber) — class-method availability checks
    {"FYBInterstitial", "isAvailable:", StubBOOL},
    {"FYBRewarded", "isAvailable:", StubBOOL},

    // Appodeal 3/4
    {"Appodeal", "isReadyForShowWithStyle:", StubBOOL},
    {"Appodeal", "canShow:forPlacement:", StubBOOL},
    {"Appodeal", "canShowAd:forPlacement:", StubBOOL},
};

#pragma mark - Jailbreak-detection bypass table

static const AdHook kJailbreakHooks[] = {
    {"BUDeviceHelper", "bu_isJailBroken", StubBOOL},
    {"EBAppLogDeviceHelper", "isJailBroken", StubBOOL},
    {"HMDBUInfo", "isJailBroken", StubBOOL},
    {"MobClick", "isJailbroken", StubBOOL},
    {"MobClick", "isPirated", StubBOOL},
    {"SSEDeviceStatus", "jailBroken", StubBOOL},
    {"UMUtils", "isDeviceJailBreak", StubBOOL},
    {"UMUtils", "isAppPirate", StubBOOL},
};

#pragma mark - Video ad context + speed-up

// Ad context: count visible full-screen ad view-controllers, matched by class name or by
// the Swift module prefix of the SDK.
static NSSet<NSString *> *aspAdVCNames(void) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[
            // Google Mobile Ads
            @"GADFullScreenAdViewController", @"GADWebViewController",
            // AppLovin
            @"MAFullscreenAdViewController", @"ALAppLovinVideoViewController",
            @"ALBaseVideoViewController", @"ALVASTVideoViewController", @"ALWebViewViewController",
            // Meta Audience Network
            @"FBAdDSLFullScreenAdViewController", @"FBAdVideoAdViewController",
            @"FBAdPlayableViewController", @"FBAdEndCardViewController",
            // Pangle
            @"PAGAppOpenAdViewController", @"PAGRewardedInterstitialRootViewController",
            @"PAGRewardedInsterstitialParentViewController", @"PAGRewardedVideoWebViewController",
            @"PAGNativeExpressRewardedVideoAdDisplayViewController", @"PAGPurePlayableLoadingViewController",
            // Mintegral
            @"MTGFullScreenViewController", @"MTGMediaVideoBaseViewController", @"MTGVideoBaseViewController",
            @"MTGMediaVideoTemplate2ViewController", @"MTGMediaVideoTemplate3ViewController",
            @"MTGMediaVideoTemplate4ViewController", @"MTGSplashViewController",
            // Chartboost, DT Exchange, HyprMX, Amazon, Smaato, Start.io, Ogury, myTarget, BidMachine, Bigo, Tapjoy, InMobi
            @"CHBAdContainerViewController", @"CHBHTMLWebViewController",
            @"IAAVPlayerViewController", @"IAEndcardViewController", @"IAMRAIDViewController", @"IAMRAIDBaseViewController",
            @"HYPROfferFullscreenAdViewController", @"HYPROfferViewController",
            @"DTBAdInterstitialViewController", @"SOMAFullScreenAdViewController",
            @"STAAdVideoViewController", @"STAMRAIDAdViewController", @"STAMRAIDRewardedAdViewController", @"STASplashViewController",
            @"OGAFullscreenViewController", @"MTRGFullscreenViewController", @"BDMVideoPlayerViewController",
            @"BGAdSplashViewController", @"BGAdWebViewController", @"TJCWebViewController", @"IMWKWebViewController",
            @"ISNPresentationStrategyViewController",
        ]];
    });
    return names;
}

// Swift module prefixes of ad SDKs with Swift view-controllers.
static const char *const kAdSwiftModulePrefixes[] = {
    "_TtC12VungleAdsSDK", "_TtC9MolocoSDK", "_TtC8UnityAds", "_TtC13ChartboostSDK",
    "_TtC10BidMachine", "_TtC9InMobiSDK", "_TtC6HyprMX", "_TtC11MyTargetSDK",
    "_TtC13MobileAdsCore", "_TtC10IronSource", "_TtC16FBANEndCardSwift",
};

static BOOL aspIsAdViewController(UIViewController *vc) {
    NSSet *names = aspAdVCNames();
    for (Class c = object_getClass(vc); c && c != [UIViewController class]; c = class_getSuperclass(c)) {
        const char *n = class_getName(c);
        if ([names containsObject:@(n)]) return YES;
        size_t len = strlen(n);
        if (len > 2 && (strcmp(n + len - 2, "VC") == 0 || strstr(n, "ViewController"))) {
            for (size_t i = 0; i < sizeof(kAdSwiftModulePrefixes) / sizeof(kAdSwiftModulePrefixes[0]); i++) {
                if (strncmp(n, kAdSwiftModulePrefixes[i], strlen(kAdSwiftModulePrefixes[i])) == 0) return YES;
            }
        }
    }
    return NO;
}

// Player -> time of its last start, to speed up an ad video that started just before its
// controller appeared. Older players (the app's own video) are left alone.
static NSMapTable *aspPlayers(void) {
    static NSMapTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSMapTable weakToStrongObjectsMapTable]; });
    return t;
}
static const CFAbsoluteTime kAspPreAdWindow = 3.0;

// Players running at the boosted rate; set back to normal when the last ad closes, so an
// SDK player that keeps going (looping end card, preloaded next ad) doesn't burn CPU.
static NSHashTable *aspBoosted(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

// Ad view-controllers between -viewDidAppear: and -viewDidDisappear:. Weak, so one that is
// freed without -viewDidDisappear: can't leave the app stuck in "ad on screen".
static NSHashTable *aspAdVCs(void) {
    static NSHashTable *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [NSHashTable weakObjectsHashTable]; });
    return t;
}

static NSUInteger aspAdDepth(void) {
    @synchronized (aspAdVCs()) { return [aspAdVCs() allObjects].count; }
}

static void aspRestorePlayers(void) {
    NSArray *players;
    @synchronized (aspBoosted()) {
        players = [aspBoosted() allObjects];
        [aspBoosted() removeAllObjects];
    }
    if (gSpeedNative) return;
    for (AVPlayer *p in players) {
        float r = p.rate;
        if (r >= gVideoRate * 0.99f) [p setRate:r / gVideoRate];  // no ad on screen: passes through
    }
}

%group AdContext

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (aspIsAdViewController(self)) {
        BOOL first;
        @synchronized (aspAdVCs()) {
            if ([aspAdVCs() containsObject:self]) return;
            first = [aspAdVCs() allObjects].count == 0;
            [aspAdVCs() addObject:self];
        }
#ifdef ADSPEED_DEBUG
        aspLog(@"ad VC appeared: %s depth=%lu", class_getName(object_getClass(self)), (unsigned long)aspAdDepth());
#endif
        if (first) {
            NSMutableArray *players = [NSMutableArray array];
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            @synchronized (aspPlayers()) {
                for (AVPlayer *p in aspPlayers()) {
                    if (now - [[aspPlayers() objectForKey:p] doubleValue] < kAspPreAdWindow) [players addObject:p];
                }
            }
            for (AVPlayer *p in players) {
                if (p.rate > 0.0f && p.rate < gVideoRate) [p setRate:p.rate];
            }
        }
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    BOOL last = NO;
    @synchronized (aspAdVCs()) {
        if (![aspAdVCs() containsObject:self]) return;
        [aspAdVCs() removeObject:self];
        last = [aspAdVCs() allObjects].count == 0;
    }
    if (last) aspRestorePlayers();
}
%end

%end // group AdContext

// Only touch playback rate while an ad is on screen; leave the app's own video alone.
%hook AVPlayer
- (void)setRate:(float)rate {
#ifdef ADSPEED_DEBUG
    if (gActive && rate > 0.0f) aspLog(@"AVPlayer setRate %.2f adDepth=%lu", rate, (unsigned long)aspAdDepth());
#endif
    BOOL inAd = gActive && gSpeedVideo && rate > 0.0f && (gSpeedNative || aspAdDepth() > 0);
    if (gActive && gSpeedVideo && rate > 0.0f && !inAd) {
        NSMapTable *players = aspPlayers();
        @synchronized (players) { [players setObject:@(CFAbsoluteTimeGetCurrent()) forKey:self]; }
    }
    // Speed native video: in a detected ad VC always, or anywhere if the user lets us
    // (most AVPlayer activity in these ad-heavy games is the ad itself).
    if (inAd) {
        @synchronized (aspBoosted()) { [aspBoosted() addObject:self]; }
        %orig(rate * gVideoRate);
    } else {
        %orig(rate);
    }
}
%end

#pragma mark - Web ad speed-up (WKWebView)

// Many ad SDKs (Unity Ads, VAST/HTML5 creatives) play video inside a WKWebView, where
// AVPlayer hooking can't reach. Inject JS at document start that (a) compresses JS
// timers so countdowns / "skip"/"reward" gating elapse faster, and (b) bumps the
// playbackRate of any <video>. Applies to every webview the app creates while active.
// Gentle mode (default): only bump <video> playbackRate, so the creative still plays
// through to its completion/quartile events and the SDK credits the reward.
// Aggressive mode (CompressTimers): also divide JS timers — faster, but can let the
// "close" gate fire before completion, voiding the reward (seen on AppLovin/Mintegral).
// Two opt-in aggressive layers on top of the always-on <video> playbackRate bump:
//   compressTimers: divide setTimeout/setInterval delays (timer-driven countdowns).
//   accelClock:     run Date.now()/performance.now() fast (wall-clock countdowns).
// Both suit timer-gated playables (reward fires on the timer); on video they can close
// the ad before completion and void the reward.
// The timer/clock acceleration only runs while `fast` is true. As soon as a <video>
// appears we set fast=false, so video ads (which sync the picture to their own clock)
// don't desync/freeze — they just get playbackRate. Playables (no <video>) keep
// fast=true and their countdown is accelerated.
// Builds the injected JS from independent layers:
//   speedVideo:     bump <video> playbackRate (event-driven, so it doesn't fight the
//                   player and stutter). Honors forceInline.
//   compressTimers: divide setTimeout/setInterval delays.
//   accelClock:     run Date.now()/performance.now() fast.
// The timer/clock layers work on their own (no video speed needed) — they're the path
// for ads where the video can't be sped up. They auto-pause (`fast=false`) once a
// <video> is on screen, so they don't desync/freeze a video ad.
static NSString *webSpeedJS(float rate, BOOL speedVideo, BOOL compressTimers, BOOL accelClock, BOOL forceInline) {
    NSMutableString *js = [NSMutableString stringWithFormat:
        @"(function(){var R=%0.1f;if(R<1)R=1;"
         "var oST=window.setTimeout,oSI=window.setInterval,oDN=Date.now;var fast=true;"
         // A hidden page (web view off screen: preloaded or closed ad) runs at normal speed.
         "var vis=!document.hidden;function on(){return fast&&vis;}", rate];

    if (compressTimers) {
        [js appendString:
            @"window.setTimeout=function(f,t){return oST.apply(this,[f,on()?(t||0)/R:(t||0)].concat([].slice.call(arguments,2)));};"
             "window.setInterval=function(f,t){return oSI.apply(this,[f,on()?(t||0)/R:(t||0)].concat([].slice.call(arguments,2)));};"];
    }
    if (accelClock) {
        [js appendString:
            @"try{var _l=oDN(),_v=oDN();Date.now=function(){var n=oDN();_v+=(on()?(n-_l)*R:(n-_l));_l=n;return Math.round(_v);};}catch(e){}"
             "try{if(window.performance&&performance.now){var _opn=performance.now.bind(performance),_pl=_opn(),_pv=_opn();"
             "performance.now=function(){var n=_opn();_pv+=(on()?(n-_pl)*R:(n-_pl));_pl=n;return _pv;};}}catch(e){}"];
    }
    if ((compressTimers || accelClock) && speedVideo) {
        // Only when also fast-forwarding video: pause timer/clock accel while a video is
        // on screen so the sped video doesn't desync/freeze. When timers run on their own
        // (video speed off), the user wants the countdown rushed regardless of any video.
        [js appendString:@"oSI(function(){if(document.getElementsByTagName('video').length)fast=false;},400);"];
    }
    if (speedVideo) {
        NSString *inlineJS = forceInline ?
            @"x.setAttribute('playsinline','');x.setAttribute('webkit-playsinline','');x.playsInline=true;" : @"";
        [js appendFormat:
            @"function setR(x,r){try{if(x.playbackRate!==r)x.playbackRate=r;}catch(e){}}"
             "function bv(){var v=document.getElementsByTagName('video');for(var i=0;i<v.length;i++){var x=v[i];%@setR(x,vis?R:1);"
             // Hidden page (preloaded ad): pause its video so it isn't decoded in the
             // background; play again once the page is shown.
             "if(!vis){if(!x.paused){x.__aspP=1;try{x.pause();}catch(e){}}}"
             "else if(x.__aspP){x.__aspP=0;try{var q=x.play();if(q&&q.catch)q.catch(function(){});}catch(e){}}"
             "if(!x.__asp){x.__asp=1;x.addEventListener('ratechange',function(){if(vis&&this.playbackRate<R)this.playbackRate=R;},true);}}}"
             "oSI(function(){if(vis)bv();},1000);document.addEventListener('play',bv,true);document.addEventListener('loadedmetadata',bv,true);", inlineJS];
    }
    // Track visibility; on hide, put sped-up videos back to normal speed.
    [js appendString:speedVideo
        ? @"document.addEventListener('visibilitychange',function(){vis=!document.hidden;bv();},true);"
        : @"document.addEventListener('visibilitychange',function(){vis=!document.hidden;},true);"];
    [js appendString:@"})();"];
    return js;
}

%hook WKWebView
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    if (gActive && (gSpeedVideo || gWebTimers || gWebClock) && configuration) {
        // Force-inline only when the user opts in AND we're speeding video: a fullscreen
        // <video> is handed to the native player (out of our JS reach), so this keeps
        // playbackRate applying — but it rewrites the SDK's webview config and can break
        // some players (AppLovin).
        if (gForceInline && gSpeedVideo) {
            configuration.allowsInlineMediaPlayback = YES;
            configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
        }
        WKUserScript *s = [[WKUserScript alloc] initWithSource:webSpeedJS(gVideoRate, gSpeedVideo, gWebTimers, gWebClock, gForceInline)
                                                 injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                              forMainFrameOnly:NO];
        [configuration.userContentController addUserScript:s];
#ifdef ADSPEED_DEBUG
        aspLog(@"WKWebView created -> injected web speed-up");
#endif
    }
    return %orig;
}
%end

#pragma mark - Network-level ad blocking ("Block ad servers")

// Ad hosts, matched with subdomains. Shared hosts (CDNs, facebook.com, unity3d.com,
// yandex.net) are left out so logins and game services keep working.
static const char *const kAdHostSuffixes[] = {
    // Google Mobile Ads
    "doubleclick.net", "googlesyndication.com", "googleadservices.com",
    "googleads.g.doubleclick-cn.net", "admob-gmats.uc.r.appspot.com",
    // AppLovin
    "applovin.com", "applvn.com",
    // ironSource / Unity LevelPlay, Unity Ads, Tapjoy (Unity offerwall)
    "supersonicads.com", "ironsrc.com", "ironsrc.mobi", "mediation.unity3d.com",
    "unityads.unity3d.com", "offerwall.unity3d.com", "tapjoy.com", "tapjoyads.com",
    // Meta Audience Network
    "an.facebook.com",
    // Liftoff / Vungle
    "vungle.com",
    // Pangle
    "pangle.io", "pangleglobal.com", "tiktokpangle-cdn-us.com",
    // Mintegral
    "mtgglobals.com", "rayjump.com", "mintegral.com", "mintegral.net",
    // InMobi
    "inmobi.com", "inmobicdn.net",
    // Chartboost
    "chartboost.com",
    // Digital Turbine (FairBid, DT Exchange / Inneractive, Heyzap)
    "fyber.com", "inner-active.mobi", "heyzap.com", "sponsorpay.com",
    // Moloco
    "adsmoloco.com", "dsp-api.moloco.com",
    // BidMachine
    "bidmachine.io",
    // Amazon Publisher Services
    "amazon-adsystem.com", "publishers.advertising.a2z.com",
    // Verve / PubNative HyBid
    "pubnative.net", "vrvm.com",
    // Ogury
    "presage.io", "ogury.io",
    // MobileFuse
    "mobilefuse.com",
    // myTarget (VK Ads)
    "ad.mail.ru",
    // HyprMX
    "hyprmx.com",
    // Start.io
    "startappservice.com", "mobileadexchange.net",
    // Appodeal
    "appodeal.com", "appbaqend.com",
    // Yandex Mobile Ads
    "yandexadexchange.net", "adsdk.yandex.ru",
    // Bigo Ads
    "maxesads.com", "sonicsads.com",
    // Smaato
    "smaato.net", "smaato.com",
    // AdColony
    "adcolony.com",
};

// Host + path fragment for shared hosts.
static const char *const kAdPathRules[][2] = {
    {"graph.facebook.com", "network_ads_common"},   // Meta Audience Network ad requests
};

static BOOL aspIsAdURL(NSURL *url) {
    NSString *h = url.host.lowercaseString;
    if (h.length == 0) return NO;
    const char *host = h.UTF8String;
    size_t hl = strlen(host);
    for (size_t i = 0; i < sizeof(kAdHostSuffixes) / sizeof(kAdHostSuffixes[0]); i++) {
        const char *s = kAdHostSuffixes[i];
        size_t sl = strlen(s);
        if (hl == sl && strcmp(host, s) == 0) return YES;
        if (hl > sl && host[hl - sl - 1] == '.' && strcmp(host + hl - sl, s) == 0) return YES;
    }
    for (size_t i = 0; i < sizeof(kAdPathRules) / sizeof(kAdPathRules[0]); i++) {
        if (strcmp(host, kAdPathRules[i][0]) == 0 &&
            [url.path rangeOfString:@(kAdPathRules[i][1])].location != NSNotFound) return YES;
    }
    return NO;
}

// Fails ad requests with "cannot find host", like a DNS block. The failure comes after a
// delay: an instant one makes SDKs and games retry in a tight loop on the main thread.
static const NSTimeInterval kAspBlockDelay = 3.0;

@interface ASPAdBlockProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@property (nonatomic, strong) NSThread *loadThread;
@end

@implementation ASPAdBlockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return gBlockNet && aspIsAdURL(request.URL);
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}
- (void)startLoading {
#ifdef ADSPEED_DEBUG
    aspLog(@"blocked ad request: %@", self.request.URL.host);
#endif
    // Client callbacks belong on the thread that called -startLoading (it runs a run loop).
    self.loadThread = [NSThread currentThread];
    __weak ASPAdBlockProtocol *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAspBlockDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ASPAdBlockProtocol *me = weakSelf;
        if (!me || me.stopped || !me.loadThread) return;
        [me performSelector:@selector(aspFail) onThread:me.loadThread withObject:nil
              waitUntilDone:NO modes:@[NSRunLoopCommonModes]];
    });
}
- (void)aspFail {
    if (self.stopped) return;
    self.stopped = YES;
    NSError *err = [NSError errorWithDomain:NSURLErrorDomain
                                       code:NSURLErrorCannotFindHost
                                   userInfo:@{NSURLErrorFailingURLErrorKey: self.request.URL ?: [NSNull null],
                                              NSLocalizedDescriptionKey: @"A server with the specified hostname could not be found."}];
    [self.client URLProtocol:self didFailWithError:err];
}
- (void)stopLoading {
    self.stopped = YES;
}
@end

// registerClass: covers NSURLConnection and sharedSession; sessions created from a
// configuration need the protocol in their own protocolClasses.
static void aspInjectProtocol(NSURLSessionConfiguration *config) {
    if (!gBlockNet || !config || config.identifier) return;  // skip background sessions
    NSArray *current = config.protocolClasses ?: @[];
    if ([current containsObject:[ASPAdBlockProtocol class]]) return;
    config.protocolClasses = [@[[ASPAdBlockProtocol class]] arrayByAddingObjectsFromArray:current];
}

%group NetBlock

%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    aspInjectProtocol(configuration);
    return %orig;
}
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id)delegate
                             delegateQueue:(NSOperationQueue *)queue {
    aspInjectProtocol(configuration);
    return %orig;
}
%end

%end // group NetBlock

#pragma mark - App Store block ("Block App Store")

// Ads open the store on their own (auto-redirect, end card, mis-tap). Blocked here:
//   - the in-app store sheet (SKStoreProductViewController) and the SKOverlay banner;
//   - openURL to App Store links or ad hosts (click trackers that redirect to the store);
//   - any openURL / Safari view while an ad is on screen.
// Only the SDK's own completion handlers are called (with a failure); its delegates are
// never called on its behalf, since some are forwarding proxies that crash on it.

static BOOL aspIsStoreURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([scheme hasPrefix:@"itms"]) return YES;   // itms, itms-apps, itms-appss, itmss
    NSString *h = url.host.lowercaseString ?: @"";
    return [h isEqualToString:@"apps.apple.com"] || [h isEqualToString:@"itunes.apple.com"]
        || [h isEqualToString:@"appsto.re"] || [h hasSuffix:@".apps.apple.com"];
}

static BOOL aspShouldBlockURL(NSURL *url) {
    if (!gBlockStore || !url) return NO;
    BOOL block = aspIsStoreURL(url) || aspIsAdURL(url) || aspAdDepth() > 0;
#ifdef ADSPEED_DEBUG
    if (block) aspLog(@"blocked open: %@", url);
#endif
    return block;
}

static NSError *aspStoreError(void) {
    return [NSError errorWithDomain:@"SKErrorDomain" code:0 /* SKErrorUnknown */ userInfo:nil];
}

%group StoreBlock

%hook UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    if (aspShouldBlockURL(url)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    %orig;
}
- (BOOL)openURL:(NSURL *)url {
    if (aspShouldBlockURL(url)) return NO;
    return %orig;
}
%end

%hook UIScene
- (void)openURL:(NSURL *)url options:(id)options completionHandler:(void (^)(BOOL))completion {
    if (aspShouldBlockURL(url)) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
        return;
    }
    %orig;
}
%end

%hook SKStoreProductViewController
- (void)loadProductWithParameters:(NSDictionary *)params completionBlock:(void (^)(BOOL, NSError *))block {
#ifdef ADSPEED_DEBUG
    aspLog(@"blocked store sheet: %@", params);
#endif
    if (block) dispatch_async(dispatch_get_main_queue(), ^{ block(NO, aspStoreError()); });
}
- (void)loadProductWithParameters:(NSDictionary *)params impression:(id)impression completionBlock:(void (^)(BOOL, NSError *))block {
    if (block) dispatch_async(dispatch_get_main_queue(), ^{ block(NO, aspStoreError()); });
}
%end

%hook SKOverlay
- (void)presentInScene:(id)scene {
#ifdef ADSPEED_DEBUG
    aspLog(@"blocked SKOverlay");
#endif
    // Not shown, and no delegate is called on the SDK's behalf (see presentViewController).
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    static Class storeVC, safariVC;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        storeVC = objc_getClass("SKStoreProductViewController");
        safariVC = objc_getClass("SFSafariViewController");
    });
    BOOL isStore = storeVC && [vc isKindOfClass:storeVC];
    BOOL isSafari = safariVC && [vc isKindOfClass:safariVC] && aspAdDepth() > 0;
    if (gBlockStore && (isStore || isSafari)) {
#ifdef ADSPEED_DEBUG
        aspLog(@"blocked %s", class_getName(object_getClass(vc)));
#endif
        // Not shown; only the caller's own completion runs. Its delegate is never called on
        // its behalf: in Unity games it can be a forwarding proxy that crashes on a call it
        // did not expect (EXC_BAD_ACCESS in objc_retain under -forwardInvocation:).
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    %orig;
}
%end

%end // group StoreBlock

#pragma mark - Bootstrap

static BOOL resolveActive(NSDictionary *prefs) {
#ifdef ADSPEED_FORCE_ON
    return YES; // standalone / TrollFools build: always on, ignore prefs
#else
    if (!prefBool(prefs, kKeyMaster, YES)) return NO;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSString *appKey = [kKeyAppPrefix stringByAppendingString:bid];
    return prefBool(prefs, appKey, NO); // default OFF until enabled in Settings
#endif
}

// Which hook tables to (re)install. Ad SDKs load their frameworks lazily after
// launch, so hooking only once at %ctor misses them — we re-install whenever a new
// image is loaded.
static BOOL gInstallAds = NO;
static BOOL gInstallJB  = NO;

static void installEnabled(void) {
    if (gInstallAds) {
        installAll(kAdHooks, sizeof(kAdHooks) / sizeof(kAdHooks[0]));
        installAllClass(kAdClassHooks, sizeof(kAdClassHooks) / sizeof(kAdClassHooks[0]));
    }
    if (gInstallJB)  installAll(kJailbreakHooks, sizeof(kJailbreakHooks) / sizeof(kJailbreakHooks[0]));
}

// Coalesce bursts of image loads into a single install on the main queue (never hook
// from inside the dyld callback itself — its lock may be held).
static void scheduleInstall(void) {
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = NO;
        installEnabled();
    });
}

static void imageAdded(const struct mach_header *mh, intptr_t slide) {
    scheduleInstall();
}

#ifdef ADSPEED_JAILED
// Jailed build: optional settings file (adspeed.plist or adspeed.json) next to the injected
// dylib, in the app bundle root, or in the app's Documents folder. Same keys as the Settings
// panel, without the bundle-id prefix.
static NSDictionary *aspJailedConfig(void) {
    NSMutableOrderedSet *dirs = [NSMutableOrderedSet orderedSet];
    Dl_info info;
    if (dladdr((const void *)&aspJailedConfig, &info) && info.dli_fname)
        [dirs addObject:[@(info.dli_fname) stringByDeletingLastPathComponent]];
    if ([NSBundle mainBundle].bundlePath) [dirs addObject:[NSBundle mainBundle].bundlePath];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs) [dirs addObject:docs];
    for (NSString *dir in dirs) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"adspeed.plist"]];
        if (!d) {
            NSData *json = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"adspeed.json"]];
            id obj = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
            if ([obj isKindOfClass:[NSDictionary class]]) d = obj;
        }
        if (d) {
#ifdef ADSPEED_DEBUG
            aspLog(@"jailed config from %@", dir);
#endif
            return d;
        }
    }
    return nil;
}
#endif

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
#ifdef ADSPEED_JAILED
        // Inject with TrollFools or Sideloadly ("Cydia Substrate"). Without a settings file:
        // always on, web <video> speed-up only.
        #ifndef ADSPEED_JAILED_RATE
        #define ADSPEED_JAILED_RATE kDefaultVideoRate
        #endif
        NSDictionary *prefs = aspJailedConfig();
        BOOL haveConfig = prefs != nil;
        gActive = prefBool(prefs, kKeyMaster, YES);
        NSString *(^key)(NSString *) = ^NSString *(NSString *s) { return s; };
        float defaultRate = ADSPEED_JAILED_RATE;
        BOOL defaultBypassJB = NO;
#else
        NSDictionary *prefs = loadPrefs();
        BOOL haveConfig = YES;
        gActive = resolveActive(prefs);
        NSString *(^key)(NSString *) = ^NSString *(NSString *s) { return appKey(bid, s); };
        float defaultRate = kDefaultVideoRate;
        BOOL defaultBypassJB = YES;
#endif
#ifdef ADSPEED_DEBUG
        aspLog(@"==== AdSpeed loaded in %@ ====", bid);
        aspLog(@"prefs found: %@  active=%d", prefs ? @"YES" : @"NO", gActive);
#endif
#ifdef ADSPEED_DUMP
        // opt-in only; objc_copyClassList crashes some apps even when deferred
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ aspDumpAdClasses(); });
#endif

        if (!gActive) return;

        gSpeedVideo  = prefBool(prefs, key(kKeySpeedVideo), YES);
        gWebTimers   = prefBool(prefs, key(kKeyWebTimers), NO);
        gWebClock    = prefBool(prefs, key(kKeyWebClock), NO);
        gForceInline = prefBool(prefs, key(kKeyForceInline), NO);
        gSpeedNative = prefBool(prefs, key(kKeySpeedNative), NO);
        id rateVal = prefs[key(kKeyVideoRate)];
        gVideoRate = rateVal ? [rateVal floatValue] : defaultRate;
        if (gVideoRate < 1.0f) gVideoRate = 1.0f;

        gBlockNet   = prefBool(prefs, key(kKeyBlockNet), NO);
        gInstallAds = prefBool(prefs, key(kKeyBlockAds), NO) || prefBool(prefs, key(kKeyBlockStubsOld), NO);
        gBlockStore = prefBool(prefs, key(kKeyBlockStore), NO);
        gInstallJB  = prefBool(prefs, key(kKeyBypassJB), defaultBypassJB);

        if (gBlockNet) {
            [NSURLProtocol registerClass:[ASPAdBlockProtocol class]];
            %init(NetBlock);
        }

        installEnabled();                              // classes already loaded
        _dyld_register_func_for_add_image(&imageAdded); // + lazily-loaded ad SDKs

        // Jailed without a settings file keeps the old web-only behaviour.
        if ((gSpeedVideo && haveConfig) || gBlockStore) {
            %init(AdContext);
        }
        if (gBlockStore) {
            // Load the classes so the hooks find them even if no SDK has loaded StoreKit yet.
            dlopen("/System/Library/Frameworks/StoreKit.framework/StoreKit", RTLD_LAZY);
            dlopen("/System/Library/Frameworks/SafariServices.framework/SafariServices", RTLD_LAZY);
            %init(StoreBlock);
        }
        // Single ungrouped %init (logos counts %init across the file, ignoring #ifdef):
        // installs the AVPlayer + WKWebView hooks, which self-gate on the flags above.
        %init;
    }
}
