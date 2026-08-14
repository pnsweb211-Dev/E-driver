import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_colors.dart';
import 'branding_providers.dart';

/// The brand mark, with a fallback chain that cannot produce a broken image:
///   network `logo_url`  →  bundled `assets/logo.png`  →  a themed bus icon.
///
/// Same contract as the parent and staff apps' `BrandLogo`, so a school that
/// uploads one logo gets it in all three. The one difference is the last
/// resort: a school crest is the wrong icon on a driver's handset, so this
/// falls back to a bus.
///
/// While the network image is still loading it shows the bundled asset rather
/// than a spinner. A logo that pops in is fine; a login screen that reflows
/// around a progress indicator is not.
class BrandLogo extends ConsumerWidget {
  const BrandLogo({
    super.key,
    this.height,
    this.width,
    this.fit = BoxFit.contain,
  });

  final double? height;
  final double? width;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logoUrl = ref.watch(brandingProvider.select((b) => b.logoUrl));

    if (logoUrl == null || logoUrl.isEmpty) return _bundled();

    return Image.network(
      logoUrl,
      height: height,
      width: width,
      fit: fit,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : _bundled(),
      errorBuilder: (context, error, stack) => _bundled(),
    );
  }

  Widget _bundled() {
    return Image.asset(
      'assets/logo.png',
      height: height,
      width: width,
      fit: fit,
      errorBuilder: (context, error, stack) => Icon(
        Icons.directions_bus_rounded,
        size: (height ?? width ?? 40) * 0.7,
        color: AppColors.accent,
      ),
    );
  }
}
