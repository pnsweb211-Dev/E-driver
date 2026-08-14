// Smoke tests for the driver sign-in screen.
//
// This file previously held the default `flutter create` counter test, which
// had been failing to compile since branding was introduced. A test that does
// not build is worse than no test: it made `flutter analyze` report an error
// permanently, which is exactly the noise that hides a real one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:driver_app/branding/branding.dart';
import 'package:driver_app/main.dart';

void main() {
  setUp(() {
    // The root restores the session from disk before deciding what to show.
    SharedPreferences.setMockInitialValues({});
  });

  // Every screen now reads providers, so the scope is part of the harness.
  Widget harness() => const ProviderScope(child: MaterialApp(home: LoginScreen()));

  testWidgets('app builds with the platform brand', (tester) async {
    await tester.pumpWidget(
      ProviderScope(child: DriverApp(initialBranding: Branding.fallback())),
    );
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });

  testWidgets('with no stored session the app opens on sign-in', (tester) async {
    await tester.pumpWidget(
      ProviderScope(child: DriverApp(initialBranding: Branding.fallback())),
    );
    // Two pumps: one for the post-frame session restore, one for the rebuild.
    await tester.pump();
    await tester.pump();

    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('sign-in asks for a Driver ID and PIN, never a school email',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('Driver ID'), findsOneWidget);
    expect(find.text('PIN'), findsOneWidget);

    // The whole point of the Driver ID: the school's email address — which is
    // also the school admin's login — must never be asked for here.
    expect(find.textContaining('Email'), findsNothing);
    expect(find.textContaining('Vehicle Number'), findsNothing);
  });

  testWidgets('first-run setup swaps in the setup-code fields', (tester) async {
    await tester.pumpWidget(harness());

    // Settle, then scroll into view, before tapping anything. The default test
    // surface is 800×600 — shorter than any phone this ships on — so the
    // bottom of the form sits below the fold, and the screen's entry
    // fade/slide means a widget's painted position is not its laid-out one
    // until the animation finishes. Either alone makes `tap` silently miss.
    // Without this the test breaks on any height change above it, which is
    // what it did when the brand logo replaced the smaller icon.
    await tester.pumpAndSettle();

    final setUp = find.text('First time on this phone? Set it up');
    await tester.ensureVisible(setUp);
    await tester.pumpAndSettle();

    await tester.tap(setUp);
    await tester.pump();

    expect(find.text('Setup Code'), findsOneWidget);
    expect(find.text('Choose a PIN'), findsOneWidget);
    expect(find.text('FINISH SETUP'), findsOneWidget);
    expect(find.text('Driver ID'), findsNothing);
  });

  testWidgets('sign-in validates before calling the server', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    final signIn = find.text('SIGN IN');
    await tester.ensureVisible(signIn);
    await tester.pumpAndSettle();

    await tester.tap(signIn);
    await tester.pump();

    expect(find.text('Enter your Driver ID'), findsOneWidget);
    expect(find.text('Enter your PIN'), findsOneWidget);
  });
}
