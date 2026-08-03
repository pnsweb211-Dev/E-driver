import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_service.dart';
import 'branding.dart';

/// Loads white-label branding for the driver app. No Riverpod here — plain
/// static helpers over `http` + `SharedPreferences`. Every method is total and
/// degrades to the cached value / compile-time fallback (plan §5.1).
class BrandingService {
  static const String _key = 'branding_payload';
  static const Duration _timeout = Duration(seconds: 10);

  /// Which app this binary is, for the per-app brand. Sent as `?app=` so the
  /// driver's action colour is configured independently of the staff app's FAB
  /// — the two used to share one field (see backend
  /// docs/per-app-branding-plan.md).
  static const String _app = 'driver';

  /// Read the cached branding for instant, offline bootstrap.
  static Future<Branding> loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return Branding.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {
      // Corrupt cache → fallback.
    }
    return const Branding.fallback();
  }

  /// Fetch the driver brand and cache the raw payload. Once the driver has
  /// logged in, the stored school is sent so the school's own driver brand is
  /// resolved; before that (and if the backend predates it) the platform brand
  /// comes back. On any failure returns the cached/fallback brand — never throws.
  static Future<Branding> fetchAndCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final schoolId = prefs.getInt('school_id');

      final response = await http.get(
        Uri.parse('${ApiService.baseUrl}/api/v1/branding').replace(
          queryParameters: {
            'app': _app,
            if (schoolId != null) 'school_id': '$schoolId',
          },
        ),
        headers: {'Accept': 'application/json'},
      ).timeout(_timeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          await prefs.setString(_key, response.body);
          return Branding.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {
      // Network/parse failure → keep whatever is cached.
    }
    return loadCached();
  }
}
