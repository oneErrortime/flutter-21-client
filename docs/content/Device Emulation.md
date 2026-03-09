# Device Emulation

Four ways to test the app — from safest to most hands-on.

## Option A — Android Studio Emulator *(Recommended)*

Runs in a virtual machine on your PC. **Your real phone is never involved.**

```bash
# 1. Install Android Studio
#    https://developer.android.com/studio

# 2. Device Manager → Create Virtual Device
#    Recommended: Pixel 6, API 34 (Android 14), "Play Store" image

# 3. Start the emulator, then:
flutter run
```

> **Key:** `10.0.2.2` inside the emulator equals `localhost` on your PC.  
> Your server at `localhost:3000` is accessible as `http://10.0.2.2:3000` from inside the emulator.

## Option B — Genymotion

Faster startup than Android Studio's emulator. Free for personal use.

1. Download from [genymotion.com](https://www.genymotion.com/)
2. Create a virtual device
3. `flutter run` — Flutter detects it automatically

## Option C — Physical Device

```bash
# 1. Enable Developer Mode:
#    Settings → About Phone → tap "Build Number" 7 times

# 2. Enable USB Debugging:
#    Settings → Developer Options → USB Debugging → ON

# 3. Connect via USB, accept the trust prompt
adb devices

# 4. Run
flutter run
```

> **Safe:** `flutter run` installs a normal debug APK — uninstall it like any app.  
> **Do NOT** unlock the bootloader — that can brick devices and flutter run doesn't need it.

## Option D — Two Clients Simultaneously

To test an actual call, run two instances at the same time.

```bash
# Terminal 1: emulator
flutter run -d emulator-5554

# Terminal 2: physical device
flutter run -d <your-device-id>

# Or two emulators — start both from Android Studio Device Manager first
flutter run -d emulator-5554  # terminal 1
flutter run -d emulator-5556  # terminal 2
```

List available devices with:

```bash
flutter devices
```
