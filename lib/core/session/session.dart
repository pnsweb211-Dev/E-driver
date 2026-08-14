import 'package:shared_preferences/shared_preferences.dart';

/// What the driver app is allowed to show.
///
/// Server-decided, never hardcoded: one APK serves every school, and a school
/// can change what its drivers see without a new release. Unknown or missing
/// values fail closed to `simple` — an app that cannot tell what it may show
/// must show the least, not the most.
class Capabilities {
  const Capabilities({
    this.appMode = 'simple',
    this.canMarkBoarding = false,
    this.canViewStudentPhoto = true,
    this.canViewGuardianPhone = true,
  });

  final String appMode;
  final bool canMarkBoarding;
  final bool canViewStudentPhoto;
  final bool canViewGuardianPhone;

  bool get isSimple => appMode == 'simple';
  bool get isFull => appMode == 'full';

  /// Show the list of today's runs at all? In simple mode the app auto-selects
  /// and renders a single Start/Stop button instead.
  bool get showsRunList => appMode != 'simple';

  factory Capabilities.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const Capabilities();

    final mode = json['app_mode'] as String?;

    return Capabilities(
      appMode: (mode == 'standard' || mode == 'full') ? mode! : 'simple',
      canMarkBoarding: json['can_mark_boarding'] == true,
      canViewStudentPhoto: json['can_view_student_photo'] != false,
      canViewGuardianPhone: json['can_view_guardian_phone'] != false,
    );
  }
}

/// The signed-in driver.
class Session {
  const Session({
    required this.token,
    required this.isDriverToken,
    required this.driverName,
    required this.schoolName,
    required this.vehicleNumber,
    required this.capabilities,
    this.loginCode,
    this.schoolId,
    this.schoolPhone,
    this.schoolEmail,
    this.schoolAddress,
    this.firebaseConfig,
  });

  final String token;

  /// True for a Sanctum driver token, false for the legacy per-vehicle one.
  /// Decides whether the token travels as a header or in the body.
  final bool isDriverToken;

  final String driverName;
  final String schoolName;
  final String vehicleNumber;
  final Capabilities capabilities;
  final String? loginCode;
  final int? schoolId;

  /// The school office's own contact details.
  ///
  /// Persisted like everything else here, and that is the point: the moment a
  /// driver most needs to phone the office is a breakdown on a route with no
  /// signal, which is exactly when a network fetch would fail.
  final String? schoolPhone;
  final String? schoolEmail;
  final String? schoolAddress;

  bool get hasSchoolContact =>
      (schoolPhone ?? '').isNotEmpty || (schoolEmail ?? '').isNotEmpty;

  /// Firebase client config for the driver package, resolved per school by the
  /// server. Null when the deployment has no FCM configured — push is then off
  /// and the on-device alarms carry §7 alone.
  final Map<String, dynamic>? firebaseConfig;

  bool get hasVehicle => vehicleNumber.isNotEmpty;

  /// Same session (and token) with whatever `/me` refreshed.
  ///
  /// A school switching a driver to `full` mode — or correcting the office
  /// phone number — has to take effect without a reinstall or a re-login, so
  /// the session is replaced rather than mutated in place.
  ///
  /// Each field falls back to the one already held, so a partial payload
  /// degrades to "keep what we had" rather than blanking the card. The
  /// consequence is that a value the school CLEARS server-side stays until the
  /// next sign-in; keeping a stale phone number beats showing none.
  Session withProfile({
    Capabilities? capabilities,
    String? schoolName,
    String? schoolPhone,
    String? schoolEmail,
    String? schoolAddress,
  }) =>
      Session(
        token: token,
        isDriverToken: isDriverToken,
        driverName: driverName,
        schoolName: schoolName ?? this.schoolName,
        vehicleNumber: vehicleNumber,
        capabilities: capabilities ?? this.capabilities,
        loginCode: loginCode,
        schoolId: schoolId,
        schoolPhone: schoolPhone ?? this.schoolPhone,
        schoolEmail: schoolEmail ?? this.schoolEmail,
        schoolAddress: schoolAddress ?? this.schoolAddress,
        firebaseConfig: firebaseConfig,
      );

  /// Rebuild from disk so a cold start opens in the right mode even offline.
  static Future<Session?> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('api_token');

    if (token == null || token.isEmpty) return null;

    final mode = prefs.getString('app_mode') ?? 'simple';

    return Session(
      token: token,
      isDriverToken: prefs.getBool('is_driver_token') ?? false,
      driverName: prefs.getString('driver_name') ?? 'Driver',
      schoolName: prefs.getString('school_name') ?? '',
      vehicleNumber: prefs.getString('vehicle_number') ?? '',
      loginCode: prefs.getString('login_code'),
      schoolId: prefs.getInt('school_id'),
      schoolPhone: prefs.getString('school_phone'),
      schoolEmail: prefs.getString('school_email'),
      schoolAddress: prefs.getString('school_address'),
      capabilities: Capabilities(
        appMode: mode,
        canMarkBoarding: mode == 'full',
      ),
    );
  }

  /// Build from a `/login`, `/enrol` or `/me` payload. Tolerates both the new
  /// shape (`token`, nested `vehicle`) and the legacy one (`api_token`, flat).
  factory Session.fromPayload(Map<String, dynamic> data) {
    final driverToken = data['token'] as String?;
    final vehicle = data['vehicle'] as Map<String, dynamic>?;
    final school = data['school'] as Map<String, dynamic>?;

    // Blank-to-null, so an office that saved an empty phone field does not
    // produce a Call button that dials nothing.
    String? text(dynamic v) {
      final s = (v as String?)?.trim();

      return (s == null || s.isEmpty) ? null : s;
    }

    return Session(
      token: driverToken ?? (data['api_token'] as String? ?? ''),
      isDriverToken: driverToken != null,
      driverName: data['driver_name'] as String? ?? 'Driver',
      // The flat key stays the source of truth for the name so an older server
      // that predates the `school` block still names the school.
      schoolName: data['school_name'] as String? ?? text(school?['name']) ?? '',
      schoolPhone: text(school?['phone']),
      schoolEmail: text(school?['email']),
      schoolAddress: text(school?['address']),
      vehicleNumber:
          (vehicle?['vehicle_number'] ?? data['vehicle_number'] ?? '') as String,
      loginCode: data['login_code'] as String?,
      schoolId: data['school_id'] is int
          ? data['school_id'] as int
          : int.tryParse('${data['school_id'] ?? ''}'),
      capabilities: Capabilities.fromJson(data['capabilities'] as Map<String, dynamic>?),
      firebaseConfig: data['firebase_config'] as Map<String, dynamic>?,
    );
  }

  Future<void> persist() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString('api_token', token);
    await prefs.setBool('is_driver_token', isDriverToken);
    await prefs.setString('driver_name', driverName);
    await prefs.setString('school_name', schoolName);
    await prefs.setString('vehicle_number', vehicleNumber);
    await prefs.setString('app_mode', capabilities.appMode);

    if (loginCode != null) await prefs.setString('login_code', loginCode!);
    if (schoolId != null) await prefs.setInt('school_id', schoolId!);

    // Written OR removed, never skipped. A plain `if (x != null) set(...)`
    // would leave the previous driver's school phone on the handset after a
    // school that has since cleared it signs someone in.
    for (final entry in {
      'school_phone': schoolPhone,
      'school_email': schoolEmail,
      'school_address': schoolAddress,
    }.entries) {
      if (entry.value == null) {
        await prefs.remove(entry.key);
      } else {
        await prefs.setString(entry.key, entry.value!);
      }
    }
  }

  /// Clear every key this session wrote.
  ///
  /// `is_driver_token` matters as much as the token itself: leaving it set would
  /// make a subsequent legacy sign-in send a vehicle token as a Bearer header
  /// and fail for no visible reason.
  static Future<void> forget() async {
    final prefs = await SharedPreferences.getInstance();

    for (final key in [
      'api_token',
      'is_driver_token',
      'driver_name',
      'school_name',
      'vehicle_number',
      'app_mode',
      'login_code',
      'school_id',
      'school_phone',
      'school_email',
      'school_address',
    ]) {
      await prefs.remove(key);
    }
  }
}
