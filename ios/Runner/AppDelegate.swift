import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // permission_handler can report an unavailable/denied status on iOS when
    // its optional notification Pod macro is not configured. Read the actual
    // system setting so an already-authorized driver is not trapped at setup.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "pw.driver/ios_permissions",
        binaryMessenger: controller.binaryMessenger
      )

      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "notificationsAuthorized":
          UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
            DispatchQueue.main.async { result(authorized) }
          }

        case "requestNotifications":
          UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
          ) { granted, error in
            DispatchQueue.main.async {
              if let error = error {
                result(FlutterError(code: "NOTIFICATION_REQUEST_FAILED",
                                    message: error.localizedDescription,
                                    details: nil))
              } else {
                result(granted)
              }
            }
          }

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
