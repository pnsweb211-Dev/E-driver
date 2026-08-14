import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'branding.dart';

/// The resolved brand, so widgets deep in the tree can read the logo and the
/// app name without threading them through constructors.
///
/// [AppColors.applyBranding] already handles the colours, but a logo is an
/// image, not a token — it has to be readable from the widget that draws it.
///
/// Seeded in `main()` from the cache BEFORE the first frame and overwritten
/// once `/branding` answers, so a phone that has run the app before opens
/// straight onto the school's own logo rather than flashing the bundled one.
final brandingProvider =
    StateProvider<Branding>((ref) => const Branding.fallback());
