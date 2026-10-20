# Un-JailedSpeedAds

Blocks known advertising SDKs and speeds up reward videos in selected iOS apps.

## Modes

| Build | Use |
| --- | --- |
| Rootless `.deb` | iOS 15+ jailbreaks such as Dopamine and rootless palera1n |
| Rootful `.deb` | Rootful jailbreak environments |
| Jailed `.dylib` | Injection into one IPA; web video speed only |

The jailed build does not include native AVPlayer acceleration, timer changes, ad blocking, or a Settings bundle. It needs a substrate provider supplied by the injection tool.

## Behavior

- The tweak hooks selected methods in known ad SDK classes to suppress display ads.
- `AVPlayer` videos speed up inside recognized Google and AppLovin ad controllers. Enable **Include native video** to speed up other `AVPlayer` videos too.
- HTML video in `WKWebView` speeds up in enabled apps when **Speed up video** is on, including non-ad web video.
- Jailbreak detection bypasses are controlled by a separate option.
- The tweak runs only in apps enabled from its Settings list.

Supported SDK patterns include Google AdMob, AppLovin, ironSource, Meta Audience Network, Google IMA, Vungle, Snap Ads, and React Native Google Mobile Ads.

## Build

Install [Theos](https://theos.dev), then run one of these commands:

```sh
# Rootless package
make package

# Rootful package
make package THEOS_PACKAGE_SCHEME=

# Jailed dylib
make jailed
```

See [BUILD.md](BUILD.md) for the Debian and WSL setup.

## Install

For the jailbreak package, enable target apps in **Settings > Ads Speed**, then reopen them. Apps start disabled. The jailed dylib is always active when injected.

For a jailed build, inject `packages/adspeed-jailed.dylib` with TrollFools or with Sideloadly's Cydia Substrate option.

## Source layout

| Path | Contents |
| --- | --- |
| `Tweak.xm` | Hooks, SDK matching, and per-app gating |
| `adspeedprefs/` | Preference bundle shown in Settings |
| `adspeed.plist` | UIKit process injection filter |
| `layout/` | PreferenceLoader files |

## License

Licensed under the GNU General Public License v3.0 (see [LICENSE](LICENSE)).

The tweak started as a fork of [34306/JailedSpeedAds](https://github.com/34306/JailedSpeedAds)
and was rewritten almost from scratch by SoulRune, starting with commit
[`2085624`](https://github.com/SoulRune/Un-JailedSpeedAds/commit/2085624ea5551efc95e7775394e3e24b1893efbb).
The license covers all of that work, including the commits made before the LICENSE file
was added (`2085624` to `c899665`). No code from the original project remains.

## Credits

Documentation rewrite and build fixes by [maxblox2999](https://github.com/maxblox2999)
([commits](https://github.com/SoulRune/Un-JailedSpeedAds/compare/25d22dc...2f9d7b6)).
