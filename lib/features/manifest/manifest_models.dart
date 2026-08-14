/// A student on the manifest.
class ManifestStudent {
  const ManifestStudent({
    required this.studentId,
    required this.name,
    required this.status,
    this.admissionNo,
    this.photoUrl,
    this.guardianName,
    this.guardianPhone,
    this.eventAt,
  });

  final int studentId;
  final String name;
  final String status;
  final String? admissionNo;
  final String? photoUrl;
  final String? guardianName;
  final String? guardianPhone;
  final String? eventAt;

  bool get isPending => status == 'pending';
  bool get isOnBoard => status == 'picked' || status == 'dropped';
  bool get isAbsent => status == 'absent' || status == 'no_show';

  ManifestStudent copyWith({String? status, String? eventAt}) => ManifestStudent(
        studentId: studentId,
        name: name,
        status: status ?? this.status,
        admissionNo: admissionNo,
        photoUrl: photoUrl,
        guardianName: guardianName,
        guardianPhone: guardianPhone,
        eventAt: eventAt ?? this.eventAt,
      );

  factory ManifestStudent.fromJson(Map<String, dynamic> json) => ManifestStudent(
        studentId: json['student_id'] as int,
        name: json['name'] as String? ?? 'Student',
        status: json['status'] as String? ?? 'pending',
        admissionNo: json['admission_no'] as String?,
        photoUrl: json['photo_url'] as String?,
        guardianName: json['guardian_name'] as String?,
        guardianPhone: json['guardian_phone'] as String?,
        eventAt: json['event_at'] as String?,
      );
}

/// A stop, with the students who board there.
class ManifestStop {
  const ManifestStop({
    required this.stopId,
    required this.name,
    required this.stopOrder,
    required this.students,
    this.pickupTime,
  });

  final int stopId;
  final String name;
  final int stopOrder;
  final List<ManifestStudent> students;
  final String? pickupTime;

  int get total => students.length;
  int get done => students.where((s) => s.isOnBoard).length;
  int get absent => students.where((s) => s.isAbsent).length;
  int get pending => students.where((s) => s.isPending).length;

  ManifestStop copyWithStudents(List<ManifestStudent> next) => ManifestStop(
        stopId: stopId,
        name: name,
        stopOrder: stopOrder,
        students: next,
        pickupTime: pickupTime,
      );

  factory ManifestStop.fromJson(Map<String, dynamic> json) => ManifestStop(
        stopId: json['stop_id'] as int,
        name: json['name'] as String? ?? 'Stop',
        stopOrder: json['stop_order'] as int? ?? 0,
        pickupTime: json['pickup_time'] as String?,
        students: (json['students'] as List<dynamic>? ?? [])
            .map((s) => ManifestStudent.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class ManifestState {
  const ManifestState({
    this.tripId,
    this.routeName,
    this.stops = const [],
    this.loading = false,
    this.error,
    this.canViewGuardianPhone = true,
    this.canViewStudentPhoto = true,
  });

  final int? tripId;
  final String? routeName;
  final List<ManifestStop> stops;
  final bool loading;
  final String? error;
  final bool canViewGuardianPhone;
  final bool canViewStudentPhoto;

  int get total => stops.fold(0, (sum, s) => sum + s.total);
  int get done => stops.fold(0, (sum, s) => sum + s.done);
  int get absent => stops.fold(0, (sum, s) => sum + s.absent);

  ManifestState copyWith({
    int? tripId,
    String? routeName,
    List<ManifestStop>? stops,
    bool? loading,
    String? error,
    bool clearError = false,
    bool? canViewGuardianPhone,
    bool? canViewStudentPhoto,
  }) =>
      ManifestState(
        tripId: tripId ?? this.tripId,
        routeName: routeName ?? this.routeName,
        stops: stops ?? this.stops,
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        canViewGuardianPhone: canViewGuardianPhone ?? this.canViewGuardianPhone,
        canViewStudentPhoto: canViewStudentPhoto ?? this.canViewStudentPhoto,
      );
}
