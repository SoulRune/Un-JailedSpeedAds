# JailedSpeedAds

Block ads and speed up reward-ad videos in iOS apps — works as a rootless jailbreak
tweak (`.deb`, iOS 15.0+) with a per-app Settings panel, or statically injected into
a single `.ipa`.

## How it works

There is no content analysis. The tweak neutralises ads by name:

- **Display ads** (banner / interstitial / native / app-open) from known SDKs
  (Google AdMob `GAD*`, AppLovin `AL*`/`MA*`, ironSource `IS*`, Meta `FBAd*`,
  Google IMA `IMAAd`, Vungle, Snap `SCSnapAds*`, React-Native Google Mobile Ads…)
  have their `load` / `render` / `isReady` methods stubbed, so the host app believes
  no ad is available.
- **Reward / video ads** are *sped up* (not blocked) so you still get the reward,
  but only while a known ad view-controller is on screen — your normal app video is
  left untouched.
- An optional, separate toggle bypasses common jailbreak-detection checks.

## Settings (deb)

After installing the `.deb`, open **Settings → Ads Speed**:

- Master on/off, "Block display ads", "Speed up reward-ad video",
  "Bypass jailbreak detection".
- "Video speed → Multiplier" (default 8).
- **Apps**: a list of every installed app. The tweak only runs in apps you enable
  here. Changes apply the next time the app is launched.

By default nothing happens until you enable an app in the list.

## Building

Requires [Theos](https://theos.dev) (macOS, or Linux/WSL — see [BUILD.md](BUILD.md)).

```sh
# rootless .deb (iOS 15.0+)
make package
```

### Standalone injection (TrollFools / no Settings panel)

Build with the always-on flag so it activates without a preferences file:

```sh
make package adspeed_CFLAGS+=-DADSPEED_FORCE_ON
```

Then inject the resulting `adspeed.dylib` into the target `.ipa`.

## Layout

- `Tweak.xm` — hooks + per-app gating.
- `adspeedprefs/` — the Settings panel (PreferenceBundle).
- `adspeed.plist` — injection filter (all UIKit apps; the runtime gate decides).
- `layout/` — PreferenceLoader entry.
