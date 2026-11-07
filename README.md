# Un-JailedSpeedAds

Blocks known advertising SDKs and speeds up reward videos in selected iOS apps.

## Modes

| Build | Use |
| --- | --- |
| Rootless `.deb` | iOS 15+ jailbreaks such as Dopamine and rootless palera1n |
| Rootful `.deb` | iOS 14+ rootful jailbreaks such as unc0ver, Taurine and rootful palera1n |
| Jailed `.zip` | Injection into one IPA: dylib, `adspeed.plist`, instructions |

iOS 14 support hasn't been tested yet.

The jailed build has no Settings bundle; it reads an optional `adspeed.plist` instead (see Install). Without it, only web video is sped up. It needs a substrate provider supplied by the injection tool.

## Behavior

- **Block ads** fails requests to known ad hosts with "cannot find host", so every SDK, Swift ones included, reports a normal load failure. Shared hosts (`facebook.com`, `unity3d.com`, `yandex.net`) are not blocked.
- **Aggressive SDK stubs** (off by default) also stubs ready/show methods of known ad SDKs. Use it only if ads still appear: it can stall apps that wait for an ad.
- `AVPlayer` videos speed up while a known full-screen ad controller is on screen. Enable **Include native video** to speed up other `AVPlayer` videos too.
- HTML video in `WKWebView` speeds up in enabled apps when **Speed up video** is on, including non-ad web video.
- Jailbreak detection bypasses are controlled by a separate option.
- The tweak runs only in apps enabled from its Settings list.

Supported SDK patterns include Google AdMob, AppLovin, ironSource, Meta Audience Network, Google IMA, Vungle, Snap Ads, React Native Google Mobile Ads, Unity Ads, Pangle, Mintegral, InMobi, Chartboost, FairBid, DT Exchange, Moloco, BidMachine, Amazon APS, Ogury, MobileFuse, myTarget, HyprMX, Start.io, Appodeal, Yandex, Bigo, Smaato, Tapjoy, and AdColony.

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

For the jailbreak package, enable target apps in **Settings > Ads Speed**, then reopen them. Apps start disabled. The jailed dylib is active when injected unless its settings file sets `Enabled` to false.

For a jailed build, unpack `packages/adspeed-jailed.zip` and inject `adspeed-jailed.dylib` with TrollFools or with Sideloadly's Cydia Substrate option. The archive's `README.txt` lists every option.

To configure it, put `adspeed.plist` (or `adspeed.json`) next to the injected dylib, in the `.app` root, or in the app's `Documents` folder. Start from the `adspeed.plist` in the archive; keys are the same as in the Settings panel, without the bundle-id prefix. With a settings file, native ad video speed-up and blocking work as in the jailbreak package.

## Source layout

| Path | Contents |
| --- | --- |
| `Tweak.xm` | Hooks, SDK matching, and per-app gating |
| `adspeedprefs/` | Preference bundle shown in Settings |
| `adspeed.plist` | UIKit process injection filter |
| `adspeed-jailed.example.plist`, `jailed-README.txt` | Settings and instructions packed into the jailed archive |
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
