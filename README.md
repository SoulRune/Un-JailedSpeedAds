# Un-JailedSpeedAds

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
  "Bypass ads jailbreak detection".
- "Video speed → Multiplier" (default 8).
- **Apps**: a list of every installed app. The tweak only runs in apps you enable
  here. Changes apply the next time the app is launched.

By default nothing happens until you enable an app in the list.

## Building

Requires [Theos](https://theos.dev) (macOS, or Linux/WSL — see [BUILD.md](BUILD.md)).

```sh
# rootless .deb (Dopamine, palera1n rootless …), iOS 15.0+
make package

# rootful .deb (palera1n rootful, XinaA15 …), same iOS versions
make package THEOS_PACKAGE_SCHEME=
```

Both share the same source; Theos sets the install paths, architecture and substrate
linkage per scheme, and the Settings panel auto-detects the jailbreak root.

### Jailed devices (inject into an .ipa)

For non-jailbroken devices there is no package manager, Settings panel or prefs, so
build the **jailed** variant: always-on, **web video speed-up only** (no native
AVPlayer — it could also speed in-game cutscenes you couldn't turn off — no timer/clock
tricks, no ad blocking).

```sh
make jailed     # outputs packages/adspeed-jailed.dylib
```

Inject `packages/adspeed-jailed.dylib` into the target `.ipa`. The hooks need a substrate
provider bundled into the app, so use either:
- **TrollStore + TrollFools** (bundles the substrate automatically), or
- **Sideloadly** with its **“Cydia Substrate”** option enabled when injecting the dylib.

A sideload *without* a substrate option has nothing to resolve the hooks against, so
they won't load.

> `-DADSPEED_FORCE_ON` is the other always-on flag: same "ignore prefs / always active"
> behaviour but with the **full** feature set (blocking, native, etc.) at their defaults.
> Use `ADSPEED_JAILED` for the safe speed-only build.

## Layout

- `Tweak.xm` — hooks + per-app gating.
- `adspeedprefs/` — the Settings panel (PreferenceBundle).
- `adspeed.plist` — injection filter (all UIKit apps; the runtime gate decides).
- `layout/` — PreferenceLoader entry.


## License

This project is licensed under the GNU General Public License v3.0 (see [LICENSE](LICENSE)).

All code in this repository from commit [2085624ea5551efc95e7775394e3e24b1893efbb](https://github.com/SoulRune/Un-JailedSpeedAds/commit/2085624ea5551efc95e7775394e3e24b1893efbb) onwards is licensed under GPLv3.

**Note:** This project based on and rewritten from [34306/JailedSpeedAds](https://github.com/34306/JailedSpeedAds), which is not explicitly licensed. The original foundation belongs to its author; all extensive rewrites, optimizations, and new code starting from the specified commit are fully covered by the GPLv3 license.
