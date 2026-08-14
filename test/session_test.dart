import 'package:driver_app/core/session/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Capabilities', () {
    test('defaults to simple mode', () {
      const caps = Capabilities();

      expect(caps.appMode, 'simple');
      expect(caps.isSimple, isTrue);
      expect(caps.showsRunList, isFalse);
    });

    test('fails closed to simple when the server says nothing', () {
      expect(Capabilities.fromJson(null).appMode, 'simple');
      expect(Capabilities.fromJson({}).appMode, 'simple');
    });

    test('fails closed on an unrecognised mode', () {
      // A future mode this build does not understand must show LESS, not more.
      expect(Capabilities.fromJson({'app_mode': 'experimental'}).appMode, 'simple');
    });

    test('honours full mode', () {
      final caps = Capabilities.fromJson({
        'app_mode': 'full',
        'can_mark_boarding': true,
      });

      expect(caps.isFull, isTrue);
      expect(caps.canMarkBoarding, isTrue);
      expect(caps.showsRunList, isTrue);
    });

    test('privacy toggles default ON but are respected when off', () {
      expect(Capabilities.fromJson({}).canViewGuardianPhone, isTrue);
      expect(
        Capabilities.fromJson({'can_view_guardian_phone': false}).canViewGuardianPhone,
        isFalse,
      );
    });
  });

  group('Session.fromPayload', () {
    test('reads the new driver-token shape', () {
      final session = Session.fromPayload({
        'token': 'sanctum-abc',
        'driver_name': 'Ramesh Kumar',
        'school_name': 'Yug International',
        'school_id': 1,
        'login_code': '4821-7734',
        'vehicle': {'vehicle_number': 'CG04AB1234'},
        'capabilities': {'app_mode': 'full', 'can_mark_boarding': true},
      });

      expect(session.token, 'sanctum-abc');
      expect(session.isDriverToken, isTrue);
      expect(session.vehicleNumber, 'CG04AB1234');
      expect(session.capabilities.isFull, isTrue);
      expect(session.loginCode, '4821-7734');
    });

    test('still reads the legacy vehicle-token shape', () {
      final session = Session.fromPayload({
        'api_token': 'legacy-xyz',
        'driver_name': 'Driver',
        'vehicle_number': 'CG04AB1234',
        'school_name': 'Yug International',
      });

      expect(session.token, 'legacy-xyz');
      // Decides whether the token travels as a header or in the body — getting
      // this wrong makes every tracking call fail for no visible reason.
      expect(session.isDriverToken, isFalse);
      expect(session.vehicleNumber, 'CG04AB1234');
      expect(session.capabilities.isSimple, isTrue);
    });

    test('a driver with no bus assigned is represented, not crashed', () {
      final session = Session.fromPayload({
        'token': 'abc',
        'driver_name': 'New Driver',
        'vehicle': null,
      });

      expect(session.hasVehicle, isFalse);
      expect(session.vehicleNumber, '');
    });

    test('tolerates a school_id sent as a string', () {
      expect(Session.fromPayload({'token': 'a', 'school_id': '7'}).schoolId, 7);
    });

    test('reads the school contact block', () {
      final session = Session.fromPayload({
        'token': 'a',
        'school_name': 'Yug International',
        'school': {
          'name': 'Yug International',
          'phone': '+91 98765 43210',
          'email': 'office@yug.edu',
          'address': '12 Station Road, Raipur',
        },
      });

      expect(session.schoolPhone, '+91 98765 43210');
      expect(session.schoolEmail, 'office@yug.edu');
      expect(session.schoolAddress, '12 Station Road, Raipur');
      expect(session.hasSchoolContact, isTrue);
    });

    test('blank contact fields become null, not empty buttons', () {
      // An office that saved the phone field as spaces must not produce a Call
      // button that dials nothing.
      final session = Session.fromPayload({
        'token': 'a',
        'school': {'phone': '  ', 'email': ''},
      });

      expect(session.schoolPhone, isNull);
      expect(session.schoolEmail, isNull);
      expect(session.hasSchoolContact, isFalse);
    });

    test('a server with no school block still names the school', () {
      // Older backends send only the flat key; the card degrades to the name
      // alone rather than disappearing.
      final session = Session.fromPayload({
        'token': 'a',
        'school_name': 'Yug International',
      });

      expect(session.schoolName, 'Yug International');
      expect(session.hasSchoolContact, isFalse);
    });
  });

  group('Session.withProfile', () {
    const base = Session(
      token: 'keep-me',
      isDriverToken: true,
      driverName: 'Ramesh',
      schoolName: 'Yug International',
      vehicleNumber: 'CG04AB1234',
      capabilities: Capabilities(),
      schoolPhone: '+91 98765 43210',
    );

    test('keeps the token and fills only what was supplied', () {
      final updated = base.withProfile(
        capabilities: const Capabilities(appMode: 'full', canMarkBoarding: true),
        schoolEmail: 'office@yug.edu',
      );

      expect(updated.token, 'keep-me');
      expect(updated.capabilities.isFull, isTrue);
      expect(updated.schoolEmail, 'office@yug.edu');
      // Absent from the payload → keep what we had, rather than blanking a
      // number the driver may need on a route with no signal.
      expect(updated.schoolPhone, '+91 98765 43210');
      expect(updated.schoolName, 'Yug International');
    });
  });
}
