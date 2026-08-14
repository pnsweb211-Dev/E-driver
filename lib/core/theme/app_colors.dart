import 'package:flutter/material.dart';

import '../../branding/branding.dart';

/// Design tokens.
///
/// Lives here rather than in main.dart so feature screens can use it without
/// importing the app entry point.
///
/// **Light, not dark.** The palette used to be a fixed dark navy, on the
/// argument that a driver reads this at 6am and again in direct sunlight and
/// "a light theme loses in both". That was half wrong: outdoor readability
/// tracks screen luminance, so dark-on-dark is the *worst* case in sunlight —
/// and about 90% of a school run happens in daylight. Optimise for the 90%.
///
/// Token NAMES are unchanged from the dark palette on purpose, so every screen
/// picked this up without edits. `primary` is the page canvas, `surface` is a
/// card. Only the values moved.
abstract final class AppColors {
  // ── Canvas ───────────────────────────────────────────────────────────────
  /// Page background. Very slightly cool so white cards read as raised.
  static const Color primary = Color(0xFFF4F6FC);
  static const Color primaryLight = Color(0xFFFFFFFF);

  /// Cards and sheets.
  static const Color surface = Color(0xFFFFFFFF);

  /// A tinted panel — grouped rows, secondary blocks.
  static const Color surfaceLight = Color(0xFFEDF0F9);

  /// Slightly recessed, for headers and section bands.
  static const Color cardDark = Color(0xFFE8ECF6);

  // ── Brand accent ─────────────────────────────────────────────────────────
  /// The school's colour. RUNTIME-mutable via [applyBranding]; never use in a
  /// `const` expression.
  static Color accent = const Color(0xFF00A388);
  static Color accentDark = const Color(0xFF00806B);

  /// The call-to-action colour, and the single biggest source of "pop" in the
  /// whole palette.
  ///
  /// Deliberately NOT the school accent: a button in the same hue as the card
  /// it sits on disappears, which is exactly what made the old screens feel
  /// flat. Amber is legible against every brand colour a school is likely to
  /// pick, and against white. It stays fixed while [accent] changes.
  static const Color cta = Color(0xFFFFC02E);
  static const Color ctaText = Color(0xFF3D2B00);

  /// Apply a resolved [Branding] to the runtime-mutable accent tokens.
  static void applyBranding(Branding b) {
    accent = b.accent;
    accentDark = b.accentDark;
  }

  // ── Status ───────────────────────────────────────────────────────────────
  // Fixed semantics, never brand-configurable: green means running, amber
  // means attention, red means stop or emergency. A driver learns these once.
  static const Color success = Color(0xFF16A34A);
  static const Color successDark = Color(0xFF15803D);
  static const Color warning = Color(0xFFD97706);
  static const Color warningDark = Color(0xFFB45309);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerDark = Color(0xFFB91C1C);
  static const Color info = Color(0xFF2563EB);
  static const Color infoDark = Color(0xFF1D4ED8);

  /// Pale fills for chips, tiles and status strips.
  ///
  /// **Ink on these is the `*Dark` token, not the solid one.** The solid status
  /// colours measure ~2.9–4.2:1 on their own pale fill — under the 4.5:1
  /// minimum — which is fine for a 15px bold strip title but not for a 12.5px
  /// tile label. The dark variants clear AA on every pairing here.
  static const Color successSoft = Color(0xFFDCFCE7);
  static const Color warningSoft = Color(0xFFFEF3C7);
  static const Color dangerSoft = Color(0xFFFEE2E2);
  static const Color infoSoft = Color(0xFFE0E9FE);

  /// Pale wash of the school accent, recomputed whenever branding changes.
  static Color get accentSoft => Color.alphaBlend(
        accent.withValues(alpha: 0.12),
        surface,
      );

  // ── Text ─────────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFF1A1D2E);
  static const Color textSecondary = Color(0xFF5A6472);

  /// Hints and metadata only.
  ///
  /// The old value (#5A6A8A on navy) measured ~2.7:1 — below the 4.5:1
  /// minimum — and was used for stop names and subtitles all over the app. It
  /// looked moody indoors and vanished in a sunlit bus. This one clears AA on
  /// both the canvas and a white card; keep it that way.
  static const Color textMuted = Color(0xFF767F8C);

  /// Hairlines. Deliberately faint — the cards do the separating.
  static const Color border = Color(0xFFE5E7EB);
}
