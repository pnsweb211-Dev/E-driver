import 'package:flutter/material.dart';

import 'app_colors.dart';

/// The shared surface. White, generously rounded, hairline border rather than
/// a shadow — shadows on a light canvas read as grubby at this radius.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );

    if (onTap == null) return card;

    return Pressable(onTap: onTap!, child: card);
  }
}

/// Press feedback.
///
/// This is small and it is the whole difference between an app that feels
/// built and one that feels like a web page: the surface moves under the
/// thumb. Every tappable thing in the app goes through it, so the response is
/// identical everywhere.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.scale = 0.97,
  });

  final Widget child;
  final VoidCallback onTap;
  final double scale;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        // Fast enough to feel like a response, not an animation.
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// The primary action. Amber by default — see [AppColors.cta] for why it is
/// deliberately not the school's own colour.
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color,
    this.foreground,
    this.height = 60,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? color;
  final Color? foreground;
  final double height;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final bg = color ?? AppColors.cta;
    final fg = foreground ?? AppColors.ctaText;
    final enabled = onPressed != null && !busy;

    final body = Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: enabled ? bg : bg.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: busy
          ? SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.6, color: fg),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 24, color: fg),
                  const SizedBox(width: 9),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: fg,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
    );

    return enabled ? Pressable(onTap: onPressed!, child: body) : body;
  }
}

/// A number, its label, and a solid icon chip, on a fill tinted by meaning.
///
/// Deliberately NOT an [AppCard]: three white boxes in a row read as one grey
/// block at a glance, and the counters are the one thing on the screen a driver
/// checks without stopping to read. Carrying the colour across the whole tile —
/// fill, border, chip and ink — means green/amber/blue is legible from a metre
/// away in a cradle.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    required this.tone,
    required this.toneSoft,
    this.toneText,
  });

  final String value;
  final String label;
  final IconData icon;
  final Color tone;
  final Color toneSoft;

  /// The dark variant of [tone], used for the number and label. See
  /// [AppColors.successDark] and friends for why the solid tone is not it.
  /// Falls back to [tone] so older call sites still render.
  final Color? toneText;

  @override
  Widget build(BuildContext context) {
    final ink = toneText ?? tone;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        // Top-left stays nearly white so the tile still reads as a raised
        // surface; the tint deepens towards the chip.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(toneSoft.withValues(alpha: 0.45), AppColors.surface),
            toneSoft,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Scaled down rather than clipped. Three tiles across a small
                // handset leaves ~80dp of content width, which "23h 20m" — or
                // a three-digit count on a big route — does not fit at 26px.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: ink,
                      height: 1.1,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: tone,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: tone.withValues(alpha: 0.32),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(icon, size: 18, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// One line of state, tinted by meaning. The colour is the message; the words
/// confirm it.
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    required this.icon,
    required this.title,
    required this.tone,
    required this.toneSoft,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color tone;
  final Color toneSoft;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: toneSoft,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 21, color: tone),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: tone),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                        fontSize: 12.5, color: tone.withValues(alpha: 0.85)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small rounded badge — "In progress", "On board", "Absent".
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    required this.tone,
    required this.toneSoft,
  });

  final String label;
  final Color tone;
  final Color toneSoft;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: toneSoft,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tone),
      ),
    );
  }
}

/// Initials in a tinted circle.
///
/// Replaces the grey silhouette. Most students have no photo, and a row of
/// identical grey figures identifies nobody — initials at least differ.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({
    super.key,
    required this.name,
    this.size = 42,
    this.tone,
    this.background,
  });

  final String name;
  final double size;

  /// Override the auto-picked pair — used on the coloured header band, where
  /// the pastel palette turns to mud.
  final Color? tone;
  final Color? background;

  static const _palette = [
    (Color(0xFFE0E9FE), Color(0xFF2563EB)),
    (Color(0xFFDCFCE7), Color(0xFF16A34A)),
    (Color(0xFFFEF3C7), Color(0xFFD97706)),
    (Color(0xFFEDE9FE), Color(0xFF7C3AED)),
    (Color(0xFFFCE7F3), Color(0xFFDB2777)),
  ];

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);

    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();

    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // Stable per name, so the same child is the same colour every morning.
    final pair = _palette[name.hashCode.abs() % _palette.length];

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration:
          BoxDecoration(color: background ?? pair.$1, shape: BoxShape.circle),
      child: Text(
        _initials,
        style: TextStyle(
          fontSize: size * 0.34,
          fontWeight: FontWeight.w800,
          color: tone ?? pair.$2,
        ),
      ),
    );
  }
}
