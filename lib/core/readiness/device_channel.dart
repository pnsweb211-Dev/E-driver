import 'dart:io';

import 'package:flutter/services.dart';

/// The handful of device facts no plugin gives us (see MainActivity.kt).
///
/// Every method fails soft: an unimplemented channel, a non-Android platform or
/// a manufacturer ROM that refuses to answer must never take the app down or
/// paint a red row the driver cannot clear.
class DeviceChannel {
  const DeviceChannel._();

  static const _channel = MethodChannel('pw.driver/device');

  static Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) return null;

    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Deep-link to one notification channel's own settings page — the one-tap
  /// fix for a muted "Trip Alarms" channel.
  static Future<bool> openChannelSettings(String channelId) async =>
      await _invoke<bool>('openChannelSettings', {'channelId': channelId}) ?? false;

  /// Automatic date & time. A handset an hour out silently mis-fires every
  /// local alarm, and nothing else in the app would ever notice.
  static Future<bool> isAutoTimeEnabled() async =>
      await _invoke<bool>('isAutoTimeEnabled') ?? true;

  static Future<void> openDateTimeSettings() => _invoke<bool>('openDateTimeSettings');

  /// Whether this ROM even has an autostart screen we can reach. Stock Android
  /// and Pixels do not, and the row is hidden rather than shown as unfixable.
  static Future<bool> hasAutostartSettings() async =>
      await _invoke<bool>('hasAutostartSettings') ?? false;

  static Future<bool> openAutostartSettings() async =>
      await _invoke<bool>('openAutostartSettings') ?? false;

  static Future<String> manufacturer() async =>
      (await _invoke<String>('manufacturer')) ?? '';

  /// `{level: 0-100 or null, is_charging: bool or null}` for the Layer 5
  /// heartbeat — "battery 6%, will die before the drop run" is a diagnosis a
  /// transport manager can act on.
  static Future<({int? level, bool? charging})> battery() async {
    final raw = await _invoke<Map<Object?, Object?>>('batteryStatus');

    if (raw == null) return (level: null, charging: null);

    return (
      level: raw['level'] is int ? raw['level'] as int : null,
      charging: raw['is_charging'] is bool ? raw['is_charging'] as bool : null,
    );
  }
}
