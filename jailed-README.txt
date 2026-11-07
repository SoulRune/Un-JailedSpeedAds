Ads Speed — jailed build
========================

Files
  adspeed-jailed.dylib   the tweak
  adspeed.plist          settings (optional)
  README.txt             this file

Install
  1. Inject adspeed-jailed.dylib into the .ipa with TrollFools, or with Sideloadly
     ("Cydia Substrate" enabled).
  2. Optional: edit adspeed.plist and put it next to the injected dylib, in the .app
     root, or in the app's Documents folder. adspeed.json with the same keys works too.
  3. Restart the app.
  Without a settings file only web video is sped up (5x).

Options (missing keys use the default)
  Enabled           true   Turn the tweak on or off in this app.
  SpeedUpVideo      true   Speed up ad video: web always, native while an ad screen is open.
  VideoRate         5      Speed multiplier. Higher uses more battery; try 3-4 if rewards
                           stop counting.
  SpeedNativeVideo  false  Speed up all AVPlayer video in the app (cutscenes too).
  CompressTimers    false  Speed up ad countdowns (setTimeout / setInterval).
  AccelerateClock   false  Also speed up Date.now / performance.now.
  ForceInline       false  Keep web video inline; can break some ads.
  BlockAds          false  Block requests to ad servers.
  BlockAdsStubs     false  Patch ad SDK methods; can stall apps that wait for an ad.
  BypassJailbreak   false  Stub jailbreak checks in some ad SDKs (not needed without a
                           jailbreak).
