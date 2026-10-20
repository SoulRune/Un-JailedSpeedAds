# Build on Debian or WSL

These commands build the tweak on Debian, including Debian running under WSL.

## 1. Install Debian packages

```sh
sudo apt update
sudo apt install -y \
    build-essential git perl curl ca-certificates \
    fakeroot zip unzip rsync dpkg-dev \
    libtinfo5 libncurses5 libz3-dev llvm
```

On Windows, install Debian first from an elevated PowerShell window:

```powershell
wsl --install -d Debian
```

## 2. Install Theos

```sh
export THEOS="$HOME/theos"
echo 'export THEOS="$HOME/theos"' >> "$HOME/.profile"

git clone --recursive https://github.com/theos/theos.git "$THEOS"
git clone --depth=1 https://github.com/theos/sdks.git "$THEOS/sdks"

mkdir -p "$THEOS/toolchain/linux/iphone"
url=$(curl -fsSL https://api.github.com/repos/kabiroberai/swift-toolchain-linux/releases/latest \
    | grep browser_download_url \
    | grep 'ubuntu22.04.tar.xz' \
    | grep -v aarch64 \
    | head -n1 \
    | cut -d'"' -f4)
curl -L --fail --retry 5 --retry-delay 3 "$url" -o /tmp/toolchain.tar.xz
tar -xf /tmp/toolchain.tar.xz -C "$THEOS/toolchain/linux/iphone" --strip-components=1
```

For an ARM64 Linux host, select the matching `aarch64` toolchain asset instead.

## 3. Configure the Linux toolchain

```sh
TC="$THEOS/toolchain/linux/iphone"
[ -d "$TC/host/bin" ] && ln -sfn host/bin "$TC/bin" && ln -sfn host/lib "$TC/lib"

rm -f "$TC/host/bin/ld"
printf '#!/bin/sh\nexec "$(dirname "$0")/ld64.lld" "$@"\n' > "$TC/host/bin/ld"
chmod +x "$TC/host/bin/ld"

LLVMDIR=$(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -V | tail -1)
for pair in strip:llvm-strip lipo:llvm-lipo install_name_tool:llvm-install-name-tool \
    nm:llvm-nm otool:llvm-otool objcopy:llvm-objcopy ranlib:llvm-ranlib dsymutil:dsymutil; do
    name=${pair%%:*}
    src=${pair##*:}
    [ -x "$LLVMDIR/$src" ] && ln -sfn "$LLVMDIR/$src" "$TC/host/bin/$name"
done

source "$HOME/.profile"
"$TC/bin/clang" --version
"$TC/bin/ld" --version 2>&1 | head -n1
```

The linker output should mention LLD.

## 4. Install ldid

```sh
url=$(curl -fsSL https://api.github.com/repos/ProcursusTeam/ldid/releases/latest \
    | grep browser_download_url \
    | grep 'ldid_linux_x86_64"' \
    | head -n1 \
    | cut -d'"' -f4)
curl -L --fail --retry 5 "$url" -o "$THEOS/bin/ldid"
chmod +x "$THEOS/bin/ldid"
```

## 5. Clone and build

Clone inside the Linux filesystem to avoid Windows line-ending and filesystem overhead:

```sh
cd "$HOME"
git clone https://github.com/maxblox2999/Un-JailedSpeedAds.git
cd Un-JailedSpeedAds

# Rootless package
make package

# Rootful package
make package THEOS_PACKAGE_SCHEME=

# Jailed dylib
make jailed
```

Packages are written to `packages/`.

## Install a package

```sh
scp packages/*.deb mobile@<device-ip>:/var/mobile/
ssh root@<device-ip> 'dpkg -i /var/mobile/com.34306-sr.adspeed_*.deb; killall -9 SpringBoard'
```

Open **Settings > Ads Speed** and enable the target apps.

## Common failures

- If `libtinfo.so.5` is missing, install `libtinfo5`. Debian 12 may require the bullseye repository for that package.
- If the toolchain cannot emit `arm64e`, run `make package ARCHS=arm64`.
- If a checkout under `/mnt/` has syntax errors, run `sed -i 's/\r$//' Makefile control adspeedprefs/Makefile`.
- If a jailed dylib does not load, inject it with TrollFools or enable Cydia Substrate in Sideloadly.
