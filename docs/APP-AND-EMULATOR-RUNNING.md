# Running the Android App on an Emulator

This note documents what was tried on this machine so another agent can reproduce the setup and avoid re-discovering the same failures.

## Environment Observed

- Repo root: `/home/raul/Code/bullbitcoin-mobile`
- Flutter project with Android app under `android/`
- `.fvmrc` requests Flutter `3.38.5`
- Shell Flutter available at `/snap/bin/flutter`
- Actual Flutter SDK used by Snap:
  `/home/raul/snap/flutter/common/flutter/bin/flutter`
- Snap Flutter observed:
  `Flutter 3.41.7`, Dart `3.11.5`
- Successful non-Snap Flutter SDK:
  `/home/raul/development/flutter-3.38.5/bin/flutter`
- Successful Flutter observed:
  `Flutter 3.38.5`, Dart `3.10.4`
- Android SDK:
  `/home/raul/Android/Sdk`
- ADB:
  `/home/raul/Android/Sdk/platform-tools/adb`
- Android emulator binary:
  `/home/raul/Android/Sdk/emulator/emulator`
- Configured emulator:
  `Pixel_6_API_34`
- Emulator device ID after launch:
  `emulator-5554`
- JDK 21 configured in Flutter:
  `/home/raul/.local/toolchains/jdk-21.0.10+7`
- Rust default observed:
  `stable-x86_64-unknown-linux-gnu`, `rustc 1.94.1`
- Rust version used successfully for cargokit Android builds:
  `1.89.0`
- App package ID:
  `com.bullbitcoin.mobile`

## Important Repo State

The working tree already had unrelated local modifications before emulator work started. Do not reset or revert them just to run the app.

## Start the Emulator

`adb` was not on `PATH`, so use the full SDK path.

```bash
/home/raul/Android/Sdk/platform-tools/adb devices
flutter emulators
flutter emulators --launch Pixel_6_API_34
```

The Flutter emulator launch command returned cleanly but did not attach a device. Launching the emulator binary directly worked and exposed useful logs:

```bash
/home/raul/Android/Sdk/emulator/emulator -avd Pixel_6_API_34 -verbose
```

Wait until ADB sees the device:

```bash
/home/raul/Android/Sdk/platform-tools/adb wait-for-device
/home/raul/Android/Sdk/platform-tools/adb devices
flutter devices
```

Expected device output includes:

```text
sdk gphone64 x86 64 (mobile) • emulator-5554 • android-x64 • Android 14 (API 34)
```

## Basic App Run Command

Once the emulator is visible:

```bash
flutter run -d emulator-5554
```

This reached Gradle but failed during the Android debug build.

## First Build Failure: Rust 1.94 Host Linker

The first failure happened in the `ark_wallet` cargokit build:

```text
Execution failed for task ':ark_wallet:cargokitCargoBuildArk_walletDebug'
rustup "run" "stable" "cargo" "build" ... "--target" "x86_64-linux-android"
rust-lld: error: undefined reference: pthread_getspecific@GLIBC_2.34
rust-lld: error: undefined reference: _dl_find_object@GLIBC_2.35
```

Rust observed:

```bash
rustup show
rustup run stable rustc -Vv
```

The host had only stable installed initially, with `rustc 1.94.1`.

Installing Rust `1.89.0` made the same cargo build progress past the `rust-lld` failure. Both emulator Android targets were needed:

```bash
rustup toolchain install 1.89.0 --target x86_64-linux-android
rustup target add i686-linux-android --toolchain 1.89.0
```

Direct validation command:

```bash
rustup run 1.89.0 cargo build \
  --manifest-path /home/raul/.pub-cache/git/ark-wallet-dart-847342ecd4a2d70bea5a0755e4152d1cb7e68493/rust/Cargo.toml \
  -p ark_wallet \
  --target x86_64-linux-android \
  --target-dir /tmp/arkwallet-test-build -vv
```

This direct command got past the original host-linking error, then failed later because cargo could not find `x86_64-linux-android-clang`. That is expected outside cargokit because cargokit normally wires the Android NDK linker environment.

## Cargokit Toolchain Override Issue

Cargokit hardcodes/defaults to:

```text
rustup run stable cargo build ...
```

Relevant code in the pub-cache copy:

- `cargokit/build_tool/lib/src/builder.dart`
- `cargokit/build_tool/lib/src/options.dart`
- `cargokit/build_tool/lib/src/rustup.dart`

The options only accept `stable`, `beta`, or `nightly`, not a pinned `1.89.0`.

Also, cargokit resolves `rustup` by checking `$HOME/.cargo/bin` before `PATH`, so simply prepending a wrapper to `PATH` is not enough.

Temporary workaround that successfully made cargokit use Rust `1.89.0`:

```bash
mkdir -p /tmp/codex-rustup-wrapper
cat > /tmp/codex-rustup-wrapper/rustup <<'EOF'
#!/usr/bin/env bash
set -e

REAL_RUSTUP="/home/raul/.cargo/bin/rustup"

if [[ "$1" == "run" && "$2" == "stable" ]]; then
  shift 2
  exec "$REAL_RUSTUP" run 1.89.0 "$@"
fi

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--toolchain" && $((i + 1)) -lt ${#args[@]} && "${args[$((i + 1))]}" == "stable" ]]; then
    args[$((i + 1))]="1.89.0"
  fi
done

exec "$REAL_RUSTUP" "${args[@]}"
EOF
chmod +x /tmp/codex-rustup-wrapper/rustup

mkdir -p /tmp/codex-home/.cargo/bin
ln -sf /tmp/codex-rustup-wrapper/rustup /tmp/codex-home/.cargo/bin/rustup
```

Then launch Flutter with a temporary `HOME`, while pointing all caches/toolchains back to the real locations:

```bash
env \
  HOME=/tmp/codex-home \
  RUSTUP_HOME=/home/raul/.rustup \
  CARGO_HOME=/home/raul/.cargo \
  PUB_CACHE=/home/raul/.pub-cache \
  GRADLE_USER_HOME=/home/raul/.gradle \
  ANDROID_HOME=/home/raul/Android/Sdk \
  ANDROID_SDK_ROOT=/home/raul/Android/Sdk \
  JAVA_HOME=/home/raul/.local/toolchains/jdk-21.0.10+7 \
  PATH=/tmp/codex-home/.cargo/bin:/home/raul/.local/toolchains/jdk-21.0.10+7/bin:/home/raul/.local/bin:/home/raul/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /home/raul/snap/flutter/common/flutter/bin/flutter run -d emulator-5554
```

Without the explicit `JAVA_HOME`, the build fails at:

```text
:camera_android_camerax:compileDebugJavaWithJavac
error: invalid source release: 21
```

## Failed Path: Snap Flutter Linker Environment

After forcing cargokit through Rust `1.89.0` and using JDK 21, the build still failed because Snap Flutter injects/uses Snap linker libraries:

```text
/snap/flutter/current/usr/bin/ld:
/usr/libexec/gcc/x86_64-linux-gnu/13/liblto_plugin.so:
error loading plugin:
/snap/flutter/149/usr/bin/../../lib/x86_64-linux-gnu/libc.so.6:
version `GLIBC_2.33' not found
```

Attempts to remove Snap paths from `PATH`, clear `LD_LIBRARY_PATH`, and force `/usr/bin/gcc` did not stop GCC from picking:

```text
/snap/flutter/current/usr/bin/ld
```

Example attempted override:

```bash
CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=/usr/bin/gcc
CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS='-C link-arg=-B/usr/bin'
```

The error still referenced `/snap/flutter/current/usr/bin/ld`.

## Successful Non-Snap Flutter Setup

The working fix was to use a non-Snap Flutter SDK at the version requested by `.fvmrc`:

```bash
git clone --depth 1 --branch 3.38.5 https://github.com/flutter/flutter.git /home/raul/development/flutter-3.38.5
/home/raul/development/flutter-3.38.5/bin/flutter --version
```

Expected version output:

```text
Flutter 3.38.5
Dart 3.10.4
```

Then run the app with the temporary `HOME` and rustup wrapper described above:

```bash
cd /home/raul/Code/bullbitcoin-mobile

env \
  HOME=/tmp/codex-home \
  RUSTUP_HOME=/home/raul/.rustup \
  CARGO_HOME=/home/raul/.cargo \
  PUB_CACHE=/home/raul/.pub-cache \
  GRADLE_USER_HOME=/home/raul/.gradle \
  ANDROID_HOME=/home/raul/Android/Sdk \
  ANDROID_SDK_ROOT=/home/raul/Android/Sdk \
  JAVA_HOME=/home/raul/.local/toolchains/jdk-21.0.10+7 \
  PATH=/tmp/codex-home/.cargo/bin:/home/raul/.local/toolchains/jdk-21.0.10+7/bin:/home/raul/.local/bin:/home/raul/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /home/raul/development/flutter-3.38.5/bin/flutter run -d emulator-5554
```

On this machine the first successful debug build took about 41 minutes because it compiled many native Rust libraries for the emulator. It produced:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

Flutter installed and launched the app. Successful output included:

```text
Installing build/app/outputs/flutter-apk/app-debug.apk...
App started: BULL v6.8.0+172
Flutter run key commands.
```

ADB confirmed the running process:

```bash
/home/raul/Android/Sdk/platform-tools/adb shell pidof com.bullbitcoin.mobile
```

This returned process ID `5894` during the successful run.

## What Was Successfully Completed

- Android emulator `Pixel_6_API_34` was started.
- ADB detected it as `emulator-5554`.
- Non-Snap Flutter `3.38.5` detected it as an Android 14 API 34 device.
- Rust `1.89.0` was installed with `x86_64-linux-android` and `i686-linux-android`.
- The cargokit `rustup run stable` calls were redirected to Rust `1.89.0`.
- The debug APK was built, installed, and launched.
- The app started as `BULL v6.8.0+172`.

## Terminal Commands to Start the App

From a terminal, start in the repo root:

```bash
cd /home/raul/Code/bullbitcoin-mobile
```

Start the emulator:

```bash
/home/raul/Android/Sdk/emulator/emulator -avd Pixel_6_API_34
```

In a second terminal, wait for the emulator and confirm Flutter sees it:

```bash
cd /home/raul/Code/bullbitcoin-mobile
/home/raul/Android/Sdk/platform-tools/adb wait-for-device
/home/raul/Android/Sdk/platform-tools/adb devices
/home/raul/development/flutter-3.38.5/bin/flutter devices
```

If you want Flutter to build, install, start, and attach logs/hot reload, run:

```bash
env \
  HOME=/tmp/codex-home \
  RUSTUP_HOME=/home/raul/.rustup \
  CARGO_HOME=/home/raul/.cargo \
  PUB_CACHE=/home/raul/.pub-cache \
  GRADLE_USER_HOME=/home/raul/.gradle \
  ANDROID_HOME=/home/raul/Android/Sdk \
  ANDROID_SDK_ROOT=/home/raul/Android/Sdk \
  JAVA_HOME=/home/raul/.local/toolchains/jdk-21.0.10+7 \
  PATH=/tmp/codex-home/.cargo/bin:/home/raul/.local/toolchains/jdk-21.0.10+7/bin:/home/raul/.local/bin:/home/raul/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /home/raul/development/flutter-3.38.5/bin/flutter run -d emulator-5554
```

If the APK is already installed on the emulator and you only want to start the Bull Bitcoin app from a terminal, run:

```bash
/home/raul/Android/Sdk/platform-tools/adb shell monkey \
  -p com.bullbitcoin.mobile \
  -c android.intent.category.LAUNCHER \
  1
```

If the APK was built but is not installed, install it first:

```bash
cd /home/raul/Code/bullbitcoin-mobile
/home/raul/Android/Sdk/platform-tools/adb install -r build/app/outputs/flutter-apk/app-debug.apk
/home/raul/Android/Sdk/platform-tools/adb shell monkey -p com.bullbitcoin.mobile -c android.intent.category.LAUNCHER 1
```

## Running on a Real Android Phone

The same non-Snap Flutter and Rust wrapper setup should be used for a physical phone. The main difference is that phones usually use ARM Android targets instead of the emulator's x86/x86_64 targets.

On the phone:

1. Enable Developer options.
2. Enable USB debugging.
3. Plug the phone into the computer over USB.
4. Accept the RSA debugging prompt on the phone when it appears.

On the computer, confirm ADB can see the phone:

```bash
/home/raul/Android/Sdk/platform-tools/adb devices
```

If the phone shows as `unauthorized`, unlock the phone and accept the USB debugging prompt. If more than one Android device is connected, note the phone's device ID from the first column.

Install the ARM Rust targets used by physical Android devices:

```bash
rustup target add aarch64-linux-android --toolchain 1.89.0
rustup target add armv7-linux-androideabi --toolchain 1.89.0
```

Most modern phones use `aarch64-linux-android`. The `armv7-linux-androideabi` target is included for older or 32-bit devices.

Confirm Flutter sees the phone:

```bash
cd /home/raul/Code/bullbitcoin-mobile
/home/raul/development/flutter-3.38.5/bin/flutter devices
```

Run the app on the phone. Replace `<PHONE_DEVICE_ID>` with the device ID shown by `adb devices` or `flutter devices`:

```bash
cd /home/raul/Code/bullbitcoin-mobile

env \
  HOME=/tmp/codex-home \
  RUSTUP_HOME=/home/raul/.rustup \
  CARGO_HOME=/home/raul/.cargo \
  PUB_CACHE=/home/raul/.pub-cache \
  GRADLE_USER_HOME=/home/raul/.gradle \
  ANDROID_HOME=/home/raul/Android/Sdk \
  ANDROID_SDK_ROOT=/home/raul/Android/Sdk \
  JAVA_HOME=/home/raul/.local/toolchains/jdk-21.0.10+7 \
  PATH=/tmp/codex-home/.cargo/bin:/home/raul/.local/toolchains/jdk-21.0.10+7/bin:/home/raul/.local/bin:/home/raul/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /home/raul/development/flutter-3.38.5/bin/flutter run -d <PHONE_DEVICE_ID>
```

If the phone is the only connected Android device, this also works:

```bash
env \
  HOME=/tmp/codex-home \
  RUSTUP_HOME=/home/raul/.rustup \
  CARGO_HOME=/home/raul/.cargo \
  PUB_CACHE=/home/raul/.pub-cache \
  GRADLE_USER_HOME=/home/raul/.gradle \
  ANDROID_HOME=/home/raul/Android/Sdk \
  ANDROID_SDK_ROOT=/home/raul/Android/Sdk \
  JAVA_HOME=/home/raul/.local/toolchains/jdk-21.0.10+7 \
  PATH=/tmp/codex-home/.cargo/bin:/home/raul/.local/toolchains/jdk-21.0.10+7/bin:/home/raul/.local/bin:/home/raul/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /home/raul/development/flutter-3.38.5/bin/flutter run
```

After Flutter installs the app once, you can start it again from the terminal without rebuilding:

```bash
/home/raul/Android/Sdk/platform-tools/adb -s <PHONE_DEVICE_ID> shell monkey \
  -p com.bullbitcoin.mobile \
  -c android.intent.category.LAUNCHER \
  1
```

If you built an APK and want to install it manually on the phone:

```bash
cd /home/raul/Code/bullbitcoin-mobile
/home/raul/Android/Sdk/platform-tools/adb -s <PHONE_DEVICE_ID> install -r build/app/outputs/flutter-apk/app-debug.apk
/home/raul/Android/Sdk/platform-tools/adb -s <PHONE_DEVICE_ID> shell monkey -p com.bullbitcoin.mobile -c android.intent.category.LAUNCHER 1
```
