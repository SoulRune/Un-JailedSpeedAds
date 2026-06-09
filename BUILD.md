# Building on Debian / WSL Debian

These steps build the `.deb` on a plain Debian system, including **WSL Debian** on
Windows. macOS is not required — Theos runs fine on Linux.

## 0. (Windows only) Install WSL Debian

In an elevated PowerShell:

```powershell
wsl --install -d Debian
```

Reboot if asked, launch **Debian** from the Start menu, and create your user.
Everything below runs **inside** the Debian shell.

## 1. System packages

```bash
sudo apt update
sudo apt install -y \
    build-essential git perl curl ca-certificates \
    fakeroot zip unzip rsync dpkg-dev \
    libtinfo5 libncurses5 libz3-dev \
    llvm
```

> `llvm` provides `llvm-strip`/`llvm-lipo`/`llvm-install-name-tool` (Mach-O capable) —
> the Swift toolchain below ships only `clang`/`lld`/`llvm-ar`, not the cctools that
> Theos needs for stripping, fat-merging and install-name fixups.

> `libtinfo5`/`libncurses5` are needed by the Theos Linux toolchain. On Debian 12
> (bookworm) they are in the default repos. If `libtinfo5` cannot be found, enable it:
> `echo 'deb http://deb.debian.org/debian bullseye main' | sudo tee /etc/apt/sources.list.d/bullseye.list && sudo apt update && sudo apt install -y libtinfo5`

## 2. Install Theos (toolchain + SDKs)

> The one-line `install-theos` script often fails on Linux with
> `xz: File format not recognized` — its toolchain download fetches an HTML redirect
> instead of the archive. The manual steps below are reliable.

```bash
export THEOS=~/theos
echo 'export THEOS=~/theos' >> ~/.profile

# Theos itself
git clone --recursive https://github.com/theos/theos.git $THEOS

# iOS SDKs
git clone --depth=1 https://github.com/theos/sdks.git $THEOS/sdks

# Linux toolchain (clang/lld; works for Objective-C tweaks).
# Pick the x86_64 / ubuntu22.04 build; for an ARM64 Linux host use the *-aarch64 asset.
mkdir -p $THEOS/toolchain/linux/iphone
url=$(curl -fsSL https://api.github.com/repos/kabiroberai/swift-toolchain-linux/releases/latest \
      | grep browser_download_url | grep 'ubuntu22.04.tar.xz' | grep -v aarch64 \
      | head -n1 | cut -d'"' -f4)
curl -L --fail --retry 5 --retry-delay 3 "$url" -o /tmp/toolchain.tar.xz
file /tmp/toolchain.tar.xz   # must say "XZ compressed data" — if it says HTML, GitHub
                             # returned an error page; just re-run the curl above
tar -xf /tmp/toolchain.tar.xz -C $THEOS/toolchain/linux/iphone --strip-components=1

# This archive nests host/ and iphone/ subdirs. Expose the host compiler flat where
# Theos expects it.
TC=$THEOS/toolchain/linux/iphone
[ -d "$TC/host/bin" ] && ln -sfn host/bin "$TC/bin" && ln -sfn host/lib "$TC/lib"

# clang invokes the linker as "ld". lld picks its mode from argv[0]: "ld" => ELF,
# "ld64.lld" => Mach-O. A plain symlink would run in ELF mode and reject all the
# Mach-O flags, so install a tiny wrapper that re-invokes lld as ld64.lld.
rm -f "$TC/host/bin/ld"
printf '#!/bin/sh\nexec "$(dirname "$0")/ld64.lld" "$@"\n' > "$TC/host/bin/ld"
chmod +x "$TC/host/bin/ld"

# Theos calls the cctools tool names (strip/lipo/install_name_tool/...). This Swift
# toolchain doesn't ship them, so alias them to the system LLVM tools (Mach-O capable).
LLVMDIR=$(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -V | tail -1)
for pair in strip:llvm-strip lipo:llvm-lipo install_name_tool:llvm-install-name-tool \
            nm:llvm-nm otool:llvm-otool objcopy:llvm-objcopy ranlib:llvm-ranlib dsymutil:dsymutil; do
  name=${pair%%:*}; src=${pair##*:}
  [ -x "$LLVMDIR/$src" ] && ln -sfn "$LLVMDIR/$src" "$TC/host/bin/$name"
done

# verify
$TC/bin/clang --version
$TC/bin/ld --version 2>&1 | head -1   # should mention LLD
source ~/.profile
```

### Code-signing tool (ldid)

Theos fake-signs the dylib with `ldid`. Install a Linux build into `$THEOS/bin`:

```bash
url=$(curl -fsSL https://api.github.com/repos/ProcursusTeam/ldid/releases/latest \
      | grep browser_download_url | grep 'ldid_linux_x86_64"' | head -n1 | cut -d'"' -f4)
curl -L --fail --retry 5 "$url" -o $THEOS/bin/ldid && chmod +x $THEOS/bin/ldid
```

If `clang` complains about `libtinfo.so.5` (you have `libtinfo6`):

```bash
sudo ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5
```

## 3. Get the source

Clone **inside** the Linux filesystem (faster, and avoids Windows CRLF issues):

```bash
cd ~
git clone https://github.com/SoulRune/Un-JailedSpeedAds.git
cd Un-JailedSpeedAds
```

> If you instead build from a Windows checkout under `/mnt/d/...`, normalise line
> endings first or `make`/`dpkg` will choke:
> `sed -i 's/\r$//' Makefile control adspeedprefs/Makefile`

## 4. Build

```bash
# rootless .deb (Dopamine, palera1n rootless, etc.) — iOS 15.0+
make package

# rootful .deb (palera1n rootful, XinaA15, etc.) — same iOS versions
make package THEOS_PACKAGE_SCHEME=

# jailed build: web video speed-up only, for injecting into an .ipa (TrollFools).
make jailed     # outputs packages/adspeed-jailed.dylib
```

The jailed dylib needs a substrate provider bundled into the app at inject time:
**TrollStore + TrollFools** (bundles it automatically), or **Sideloadly** with its
**“Cydia Substrate”** option enabled. A sideload without a substrate option won't load
the hooks.

The finished package lands in `./packages/`.

## 5. Install on device

```bash
# over SSH to the device (rootless path shown)
scp packages/*.deb mobile@<device-ip>:/var/mobile/
ssh root@<device-ip> 'dpkg -i /var/mobile/com.34306-sr.adspeed_*.deb; killall -9 SpringBoard'
```

Then open **Settings → Ads Speed** and enable the apps you want.

## Troubleshooting

- **`arm64e` build error** — some Linux toolchains don't emit `arm64e`. Drop it:
  `make package ARCHS=arm64`. App Store apps load the `arm64` slice anyway.
- **`make: *** No rule to make target` / weird syntax errors** — almost always CRLF
  line endings; see the `sed` note in step 3.
- **`The futureproof rootless prefix...` / wrong install path** — make sure
  `THEOS_PACKAGE_SCHEME = rootless` is active in the `Makefile` (it is by default).
