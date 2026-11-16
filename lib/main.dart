import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'branding/brand_logo.dart';
import 'branding/branding.dart';
import 'branding/branding_providers.dart';
import 'core/theme/app_colors.dart';
import 'branding/branding_service.dart';
import 'config/app_config.dart';
import 'services/api_service.dart';
import 'services/background_service.dart';
import 'core/alarms/alarm_controller.dart';
import 'core/alarms/alarm_service.dart';
import 'core/providers.dart';
import 'core/push/driver_push.dart';
import 'core/readiness/readiness.dart';
import 'core/session/session.dart';
import 'core/tracking/tracking_gate.dart';
import 'features/alarm/alarm_screen.dart';
import 'features/auth/scan_setup_screen.dart';
import 'features/readiness/readiness_screen.dart';
import 'features/today/today_screen.dart';

// =============================================================================
// MAIN
// =============================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load cached (or compile-time fallback) branding BEFORE the first frame so the
  // app opens instantly and offline, already themed (plan §5.1 N2). Never throws.
  final brand = (await BrandingService.loadCached()).effective;
  AppColors.applyBranding(brand);

  // A platform plugin may fail on a cold relaunch. Do not leave the driver
  // stuck before the first frame because one optional service failed.
  try {
    await initializeService();
  } catch (error, stack) {
    debugPrint('[DRIVER STARTUP] Service configuration failed: $error\n$stack');
  }

  // The container is built by hand rather than by ProviderScope so the alarm
  // plugin — which is initialised before the first frame and calls back from
  // outside the widget tree — can push into the same state the UI reads.
  final container = ProviderContainer();

  // Seed the brand before the first frame so the login screen paints the
  // school's logo immediately instead of the bundled one.
  container.read(brandingProvider.notifier).state = brand;

  try {
    await AlarmService.init(
      onSelect: (target, actionId) {
        // Opening an alarm must still pass through the tracking readiness gate.
        container.read(pendingAlarmProvider.notifier).raise(target);
      },
    );

    final launchedBy = await AlarmService.launchTarget();
    if (launchedBy != null) {
      container.read(pendingAlarmProvider.notifier).raise(launchedBy);
    }
  } catch (error, stack) {
    debugPrint('[DRIVER STARTUP] Alarm initialization failed: $error\n$stack');
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: DriverApp(initialBranding: brand),
    ),
  );
}

class DriverApp extends ConsumerStatefulWidget {
  final Branding initialBranding;
  const DriverApp({super.key, required this.initialBranding});

  @override
  ConsumerState<DriverApp> createState() => _DriverAppState();
}

class _DriverAppState extends ConsumerState<DriverApp> {
  late Branding _branding = widget.initialBranding;

  @override
  void initState() {
    super.initState();
    // Background refresh of the platform brand after the first frame. A failure
    // is silently ignored (plan E7) — branding is cosmetic.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final fetched = (await BrandingService.fetchAndCache()).effective;
      if (!mounted) return;
      AppColors.applyBranding(fetched);
      // Colours go to the token class, the logo goes to the provider — the
      // widgets that draw it are rebuilt by this, not by the setState below.
      ref.read(brandingProvider.notifier).state = fetched;
      setState(() => _branding = fetched);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _branding.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: AppColors.primary,
        colorScheme: ColorScheme.light(
          primary: AppColors.accent,
          secondary: AppColors.accentDark,
          surface: AppColors.surface,
          onPrimary: Colors.white,
          onSurface: AppColors.textPrimary,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
        // Bigger than Material's defaults across the board. The reader is
        // often 50+, holding the phone at arm's length in a moving bus.
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 17, color: AppColors.textPrimary),
          bodyMedium: TextStyle(fontSize: 15, color: AppColors.textPrimary),
          bodySmall: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          centerTitle: false,
          // Dark status-bar icons now that the canvas is light.
          systemOverlayStyle: SystemUiOverlayStyle.dark,
        ),
        cardTheme: CardThemeData(
          color: AppColors.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          contentTextStyle: TextStyle(color: Colors.white, fontSize: 15),
        ),
      ),
      home: const _Root(),
    );
  }
}

// =============================================================================
// ROOT — session gate
// =============================================================================
/// Decides what the app shows, from one piece of state.
///
/// Routing off the session (rather than pushing screens from inside the login
/// flow) is what makes sign-out, a revoked device and a 401 all behave
/// identically: clear the session, and every screen unwinds by itself.
class _Root extends ConsumerStatefulWidget {
  const _Root();

  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> with WidgetsBindingObserver {
  bool _restoring = true;

  // A saved login fires both the Riverpod session listener and the restore
  // callback on cold launch. Only one should initialize push, alarms and GPS.
  bool _initializingSession = false;

  /// Null until the first sweep finishes. §7 Layer 1 gates on this: a driver
  /// must not reach the Today screen on a phone that cannot track.
  bool? _ready;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(sessionProvider.notifier).restore();
      if (!mounted) return;

      setState(() => _restoring = false);
      await _afterSignIn();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (ref.read(sessionProvider) == null) return;

    // A permission revoked while the app was in the background is one of the
    // five §7 failure modes, and it looks identical to every other one from the
    // parent's side. Catch it the moment the driver comes back.
    _refreshReadiness();

    // Pick up a mode change the office made while the app was away, so
    // switching a driver to `full` takes effect without a re-login.
    ref
        .read(sessionProvider.notifier)
        .refreshProfile(ref.read(driverApiProvider));
  }

  /// Everything that has to happen once there is a signed-in driver: check the
  /// phone, arm the week's alarms, and put the duty service on watch.
  Future<void> _afterSignIn() async {
    if (!mounted || _initializingSession || ref.read(sessionProvider) == null) {
      return;
    }

    _initializingSession = true;
    try {
      // Restored sessions are cached. Refresh in the background so an offline
      // launch never waits for the school server.
      unawaited(
        ref.read(sessionProvider.notifier).refreshProfile(ref.read(driverApiProvider)),
      );

      await _refreshReadiness();
      if (!mounted || _ready != true || ref.read(sessionProvider) == null) {
        return;
      }

      // Push already isolates its own errors. Local reminders must still be
      // attempted if FCM is unavailable on this iPhone.
      await DriverPush.start();

      try {
        await ref.read(adherenceProvider.notifier).refreshAndArm();
      } catch (error, stack) {
        debugPrint('[DRIVER STARTUP] Alarm refresh failed: $error\n$stack');
      }

      // A failed reminder refresh must not prevent bus tracking from starting.
      if (!mounted || ref.read(sessionProvider) == null) return;
      try {
        await TrackingGate.startService();
      } catch (error, stack) {
        debugPrint('[DRIVER STARTUP] Tracking startup failed: $error\n$stack');
      }
    } catch (error, stack) {
      debugPrint('[DRIVER STARTUP] Session initialization failed: $error\n$stack');
      // Avoid a splash screen that never ends after a platform-plugin error.
      // The regular readiness screen remains the safe fallback.
      if (mounted && _ready == null) {
        setState(() => _ready = false);
      }
    } finally {
      _initializingSession = false;
    }
  }

  Future<void> _refreshReadiness() async {
    final report = await ReadinessService.evaluate();

    if (!mounted) return;

    setState(() => _ready = report.canProceed);
  }

  @override
  Widget build(BuildContext context) {
    // Sign-in and sign-out both run through here, so the checklist, the alarms
    // and the duty service follow the session rather than being kicked off from
    // inside the login form.
    ref.listen<Session?>(sessionProvider, (previous, next) {
      if (next == null) {
        setState(() => _ready = null);
      } else if (previous == null) {
        _afterSignIn();
      }
    });

    if (_restoring) return const SplashScreen();

    final session = ref.watch(sessionProvider);

    if (session == null) return const LoginScreen();

    // Warm the outbox watcher so a queue left over from a previous run starts
    // draining as soon as the driver is signed in again.
    ref.watch(outboxProvider);

    if (_ready == null) return const SplashScreen();

    if (_ready == false) {
      return ReadinessScreen(onPassed: _afterSignIn);
    }

    // An alarm outranks everything else on screen. It is not pushed as a route
    // — it is what the app IS while it is unanswered, which is why there is no
    // back gesture off it.
    final alarm = ref.watch(pendingAlarmProvider);

    if (alarm != null) return AlarmScreen(target: alarm);

    return const TodayScreen();
  }
}

// =============================================================================
// SPLASH SCREEN — Premium animated entry
// =============================================================================
/// Purely a visual while the session is restored from disk.
///
/// It no longer decides anything: _Root owns that, so there is exactly one
/// place that answers "signed in or not".
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _scaleAnim = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.elasticOut),
    );
    _animController.forward();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.primary, AppColors.cardDark, AppColors.primaryLight],
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnim,
            child: ScaleTransition(
              scale: _scaleAnim,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Glowing icon
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [AppColors.accent, AppColors.accentDark],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accent.withOpacity(0.4),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.local_shipping_rounded,
                      size: 48,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    AppConfig.appName,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'School Vehicle GPS Tracking',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppColors.accent.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// LOGIN SCREEN — Premium glass-morphism style
// =============================================================================
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _loginCodeController = TextEditingController();
  final _pinController = TextEditingController();
  final _setupCodeController = TextEditingController();
  final _newPinController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _isDemoMode = false;
  bool _isSetupMode = false;
  String _errorMessage = '';

  late AnimationController _animController;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic));
    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
    _animController.forward();
    _checkDemoMode();
  }

  Future<void> _checkDemoMode() async {
    final isDemo = await ApiService.checkDemoMode();
    if (mounted) setState(() => _isDemoMode = isDemo);
  }

  @override
  void dispose() {
    _animController.dispose();
    _loginCodeController.dispose();
    _pinController.dispose();
    _setupCodeController.dispose();
    _newPinController.dispose();
    super.dispose();
  }

  /// Sign in with the Driver ID and PIN issued by the school office.
  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    await _submit(() => ApiService.loginWithCode(
          _loginCodeController.text,
          _pinController.text,
        ));
  }

  /// Read the token off the office's printed QR.
  ///
  /// Fills the field rather than submitting: the driver still has to choose a
  /// PIN, and silently signing them in from a scan would skip that.
  Future<void> _scanSetupCode() async {
    final token = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanSetupScreen()),
    );

    if (token == null || !mounted) return;

    setState(() {
      _setupCodeController.text = token;
      _errorMessage = '';
    });
  }

  /// First run: exchange the setup code from the office for a session and set
  /// a PIN the driver chooses themselves.
  Future<void> _setup() async {
    if (!_formKey.currentState!.validate()) return;

    await _submit(() => ApiService.enrol(
          _setupCodeController.text,
          _newPinController.text,
        ));
  }

  /// Everything after a successful sign-in is identical whichever door was
  /// used, so the navigation and error handling live in one place.
  Future<void> _submit(Future<Map<String, dynamic>> Function() request) async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final result = await request();

      if (!mounted) return;

      if (result['status'] == 'success') {
        // Hand the payload to the session; _Root swaps the screen. No
        // navigation from here, so sign-in and session-restore take exactly the
        // same path into the app.
        await ref
            .read(sessionProvider.notifier)
            .signIn(Session.fromPayload(result['data'] as Map<String, dynamic>));
      } else {
        setState(() {
          _errorMessage = result['message'] ?? 'Sign-in failed. Please try again.';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Connection error. Please check your internet.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _demoLogin() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final result = await ApiService.demoLogin();
      if (!mounted) return;

      if (result['status'] == 'success') {
        await ref
            .read(sessionProvider.notifier)
            .signIn(Session.fromPayload(result['data'] as Map<String, dynamic>));
      } else {
        setState(() {
          _errorMessage = result['message'] ?? 'Demo login is unavailable right now.';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Connection error. Please check your internet.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
      prefixIcon: Icon(icon, color: AppColors.accent, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: AppColors.surface.withOpacity(0.5),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.textMuted.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.textMuted.withOpacity(0.15)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: AppColors.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.danger),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.cardDark, AppColors.primary],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: FadeTransition(
                opacity: _fadeAnim,
                child: SlideTransition(
                  position: _slideAnim,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The brand mark. A WHITE plate, not the accent circle
                        // it replaces: a school logo is almost always dark ink
                        // on transparency, and dropping one onto a saturated
                        // brand-coloured disc turns it into a smudge. The
                        // coloured glow keeps the accent doing the work the
                        // filled circle used to do.
                        Container(
                          width: 104,
                          height: 104,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: AppColors.accent.withValues(alpha: 0.18),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent.withValues(alpha: 0.22),
                                blurRadius: 28,
                                spreadRadius: 1,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const BrandLogo(),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _isSetupMode ? 'Set Up This Phone' : 'Driver Login',
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _isSetupMode
                              ? 'Enter the setup code from your school office'
                              : 'Sign in to start tracking',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 36),

                        // Error message
                        if (_errorMessage.isNotEmpty)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            margin: const EdgeInsets.only(bottom: 20),
                            decoration: BoxDecoration(
                              color: AppColors.danger.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppColors.danger.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _errorMessage,
                                    style: const TextStyle(color: AppColors.danger, fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          ),

                        // ── FIRST-RUN SETUP ────────────────────────────────
                        // The setup code comes from the school office (printed
                        // under the QR on the driver's card). The driver then
                        // picks their OWN PIN — nobody reads one out to them.
                        if (_isSetupMode) ...[
                          // Scanning first, typing as the fallback. The office
                          // prints the QR already, and a driver hand-entering a
                          // 40-character token at the counter is where first-run
                          // setup actually fails.
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: OutlinedButton.icon(
                              onPressed: _isLoading ? null : _scanSetupCode,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.accent,
                                side: BorderSide(
                                    color: AppColors.accent.withValues(alpha: 0.6)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.qr_code_scanner_rounded),
                              label: const Text('SCAN SETUP QR',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          const Text('or type it',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.textMuted)),
                          const SizedBox(height: 10),
                          TextFormField(
                            controller: _setupCodeController,
                            decoration: _inputDecoration(
                              label: 'Setup Code',
                              icon: Icons.qr_code_rounded,
                            ),
                            style: const TextStyle(color: AppColors.textPrimary),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Scan the QR, or type the setup code'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _newPinController,
                            decoration: _inputDecoration(
                              label: 'Choose a PIN',
                              icon: Icons.lock_outline_rounded,
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: AppColors.textMuted,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            obscureText: _obscurePassword,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(
                                color: AppColors.textPrimary, letterSpacing: 4),
                            onFieldSubmitted: (_) => _setup(),
                            validator: (v) => v == null || v.length < 4
                                ? 'Use at least 4 digits'
                                : null,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Remember this PIN. You will use it every time you sign in.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                          ),
                        ]

                        // ── NORMAL SIGN-IN ─────────────────────────────────
                        else ...[
                          TextFormField(
                            controller: _loginCodeController,
                            decoration: _inputDecoration(
                              label: 'Driver ID',
                              icon: Icons.badge_rounded,
                            ),
                            keyboardType: TextInputType.number,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 18,
                              letterSpacing: 2,
                              fontWeight: FontWeight.w600,
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Enter your Driver ID'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _pinController,
                            decoration: _inputDecoration(
                              label: 'PIN',
                              icon: Icons.lock_outline_rounded,
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: AppColors.textMuted,
                                  size: 20,
                                ),
                                onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword),
                              ),
                            ),
                            obscureText: _obscurePassword,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(
                                color: AppColors.textPrimary, letterSpacing: 4),
                            onFieldSubmitted: (_) => _login(),
                            validator: (v) =>
                                v == null || v.isEmpty ? 'Enter your PIN' : null,
                          ),
                        ],
                        const SizedBox(height: 32),

                        // Login button
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [AppColors.accent, AppColors.accentDark],
                              ),
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.accent.withOpacity(0.35),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: _isLoading
                                  ? null
                                  : (_isSetupMode ? _setup : _login),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      height: 22,
                                      width: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(
                                      _isSetupMode ? 'FINISH SETUP' : 'SIGN IN',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                            ),
                          ),
                        ),

                        // Toggle between first-run setup and normal sign-in.
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: _isLoading
                              ? null
                              : () => setState(() {
                                    _isSetupMode = !_isSetupMode;
                                    _errorMessage = '';
                                    _formKey.currentState?.reset();
                                  }),
                          child: Text(
                            _isSetupMode
                                ? 'I already have a PIN — sign in'
                                : 'First time on this phone? Set it up',
                            // Not const: AppColors.accent is resolved from the
                            // school's branding at runtime, not a literal.
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),

                        // Demo quick-access (only when server is in demo mode)
                        if (_isDemoMode) ...[
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: OutlinedButton.icon(
                              onPressed: _isLoading ? null : _demoLogin,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.accent,
                                side: BorderSide(
                                    color: AppColors.accent.withOpacity(0.6)),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.bolt_rounded, size: 20),
                              label: const Text(
                                'DEMO LOGIN',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 40),

                        // Footer
                        Text(
                          AppConfig.poweredBy,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted.withOpacity(0.5),
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
