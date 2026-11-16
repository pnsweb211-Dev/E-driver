import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Reads the OS notification authorization, independently of Android-specific
/// permission checks. iOS uses UNUserNotificationCenter via AppDelegate.swift.
class NotificationPermission {
  const NotificationPermission._();

  static const _iosChannel = MethodChannel('pw.driver/ios_permissions');

  /// Null means the native iOS channel was not available in this engine.
  /// A background heartbeat should omit an unknown status, never send `false`.
  static Future<bool?> iosNativeStatus() async {
    if (!Platform.isIOS) return null;

    try {
      return await _iosChannel.invokeMethod<bool>('notificationsAuthorized');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> isGranted() async {
    if (!Platform.isIOS) return Permission.notification.isGranted;

    // Keep older builds functional until the new native channel is installed.
    return await iosNativeStatus() ?? await Permission.notification.isGranted;
  }

  static Future<void> requestOrOpenSettings() async {
    if (!Platform.isIOS) {
      final result = await Permission.notification.request();
      if (!result.isGranted) await openAppSettings();
      return;
    }

    try {
      final granted = await _iosChannel.invokeMethod<bool>('requestNotifications');
      if (granted != true) await openAppSettings();
    } on PlatformException {
      await openAppSettings();
    } on MissingPluginException {
      await openAppSettings();
    }
  }
}
