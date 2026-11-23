// The public widget that marks part of the UI as secure. Exported from package:bugsee_flutter.
import 'package:flutter/widgets.dart';

import 'secure_region.dart';

/// Hides its [child] from Bugsee: the area it occupies is blanked in the recorded video and in the
/// report screenshot, and taps on it are dropped from the report. Use it around passwords, card
/// numbers, personal data.
///
/// ```dart
/// BugseeSecureView(child: TextField(obscureText: true))
/// ```
///
/// The child is shown as usual to the user. The widget needs nothing to be set up and costs nothing
/// when [enabled] is `false`. Where the child is (on screen, scrolled, transformed, animated) is
/// measured every frame and handed to the SDK, which reads it a few times a second; a region that
/// is moving is covered along its path, and anything the plugin cannot place is covered whole
/// (it fails closed). Known limits:
///
///  * a region that has just appeared is recorded in the clear for its first frame or so, because
///    Dart can only publish it after layout has placed it;
///  * a rotated region is covered by its bounding box, and a partly clipped one is covered whole;
///  * pixels drawn outside the region's own subtree (an `Overlay` tooltip or magnifier) are not
///    covered;
///  * only the app's main view is placed on mobile.
///
/// This hides the child from Bugsee's capture, not from the user or the OS (it does not set
/// `FLAG_SECURE`; Bugsee's `captureRespectFlagSecure` option covers windows that do).
class BugseeSecureView extends StatelessWidget {
  const BugseeSecureView({super.key, this.enabled = true, required this.child});

  /// `false` removes the redaction; the child is recorded as usual.
  final bool enabled;

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      BugseeSecureRegion(enabled: enabled, child: child);
}
