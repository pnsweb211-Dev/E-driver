# Driver App — iOS Permission and Readiness Fix V1

Source reviewed: `driver_app_v3.7.0 (1).zip` (`pubspec.yaml` reports `3.7.0+7`).

## What this patch changes

- iOS setup checks only permissions and device capabilities that exist on iOS.
- Notification authorization is read directly from `UNUserNotificationCenter` through an iOS Flutter channel; previously enabled permissions can now be recognized.
- For iOS, the custom location and notification permission buttons say **Continue** instead of **Allow**.
- On iOS, the location flow uses iOS Settings for escalation to **Always** authorization.
- Android exact alarms, notification channels, battery-optimization exemption, autostart, and automatic-time logic remain Android-only.
- The same platform distinction is applied to background heartbeat permission snapshots.
- Local notification initialization includes the iOS platform and defers asking permission until the post-login setup flow.
- The source's iOS Info.plist now declares location-purpose strings and background-location mode.
- Active-trip GPS streaming selects `AppleSettings` on iOS, while preserving the original `AndroidSettings` on Android.

## Files included

Copy these paths over the matching Flutter project root **after making a backup**, keeping the directory structure:

1. `lib/core/readiness/readiness.dart`
2. `lib/core/readiness/notification_permission.dart` (new)
3. `lib/core/readiness/heartbeat.dart`
4. `lib/core/alarms/alarm_service.dart`
5. `lib/services/background_service.dart`
6. `ios/Runner/AppDelegate.swift`
7. `ios/Runner/Info.plist`

This is a **source patch**, not an installable IPA. Do not blindly overwrite a newer project without comparing those files; the uploaded archive contains an older source snapshot and may not be the identical source used for the current TestFlight binary.

## Build and verify on a Mac

1. Confirm the Flutter project is the same revision as the archive. The uploaded archive has **no `ios/Podfile`**; restore the intended CocoaPods configuration in the actual build project before compiling. Do not fabricate credentials or overwrite a working signing setup.
2. Run `flutter pub get`, `dart format lib/core/readiness lib/core/alarms/alarm_service.dart lib/services/background_service.dart`, `flutter analyze`, and `flutter test`.
3. Build and install a **new** iOS TestFlight build. Native Swift/Info.plist changes cannot be delivered by Flutter hot reload.
4. On an iPhone where **Location = Always**, **Precise Location = On**, and **Notifications = On**, the three Android-only red rows must not appear; notification status should be green and Continue should become available.
5. Test the first-run permission request on a fresh installation. Check that the custom buttons say **Continue** and that OS dialogs are native.
6. Start an actual trip. Lock the screen, wait at least 10–15 minutes, and verify server location pings continue while the app is backgrounded. Test route reminders, sound, Focus mode, and notification denial separately. iOS does **not** guarantee Android-style exact/full-screen alarms or continuous work after a force-quit.
7. Regression test Android login, readiness, alarm scheduling, and live GPS tracking; Android code paths are retained.

## Verification status

Static code review and package integrity can be checked in this environment. Flutter/Dart SDK, Xcode, CocoaPods, and an iPhone are not available here, so no iOS build, device run, or end-to-end GPS test has been performed. Do not submit to App Store review without a real-device validation pass.

No backend, database, signing files, Android native files, credentials, or Google/Firebase configuration are included.
