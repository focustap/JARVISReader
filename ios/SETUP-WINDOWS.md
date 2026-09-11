# JARVIS Reader — Windows + free Apple signing

This project is set up so GitHub Actions does the Xcode/iOS compilation on a macOS 26 runner. Your Windows PC only needs to install/refresh the resulting IPA on your iPhone.

## 1. Install AltStore Classic / AltServer on Windows

Follow the official Windows guide: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows

Important Windows requirements from AltStore:
- Install iTunes directly from Apple, not the Microsoft Store version.
- Install iCloud directly from Apple unless you use AltStore's documented workaround.
- Install and run AltServer as administrator.
- Connect the iPhone once by USB, unlock it, and trust the computer.
- Enable Wi-Fi sync in iTunes if you want automatic refreshes over your home network.
- On iPhone, enable Developer Mode under Settings > Privacy & Security > Developer Mode.

## 2. Build JARVIS on GitHub

The workflow is `.github/workflows/ios-native-build.yml`.

It runs on `macos-26`, generates the Xcode project with XcodeGen, resolves Meta's Device Access Toolkit 0.9.0 package, builds an unsigned arm64 iPhone app, packages it as `JARVISReader-unsigned.ipa`, and uploads it as a GitHub Actions artifact.

## 3. Install the IPA

After a successful GitHub Actions run:
1. Download the `JARVISReader-unsigned-ipa` artifact from the workflow run on GitHub.
2. Extract the ZIP to get `JARVISReader-unsigned.ipa`.
3. Keep AltServer running on Windows.
4. Install the IPA with AltStore on the iPhone, which signs it using your free Apple ID.

A free Apple ID signs sideloaded apps for about 7 days. AltStore can refresh them while the phone can reach AltServer on the same Wi-Fi network. Leaving AltServer running at PC startup makes this much less annoying.

## 4. Meta glasses setup

Before the native app can control the glasses:
1. Update Meta AI and the glasses firmware.
2. Enable Developer Mode for the glasses in Meta AI.
3. Launch JARVIS Reader.
4. Tap Register Glasses and approve the registration in Meta AI.

The project currently uses Meta's Developer Mode configuration (`MetaAppID = 0`) while the first native prototype is being built.

## Current native branch

Branch: `native-ios`

Initial goal:
- compile the Meta iOS SDK on GitHub
- install the unsigned build through AltStore
- prove registration with the Display glasses

Next code milestone:
- direct glasses camera capture
- send image to the Gemini backend
- render the short answer directly on Meta Ray-Ban Display
