import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// Holds content to a readable measure and centres it once the window is wider
/// than that.
///
/// The app is phone-first and until now it was *only* phone-shaped: on a Linux
/// desktop window or a tablet every list row, every settings card and the
/// composer stretched the full width, so a conversation name sat a thousand
/// pixels away from its timestamp and the eye had to travel the whole way. The
/// breakpoints in [AegisLayout] existed but nothing consulted them.
///
/// This is deliberately not a two-pane layout. A real side-by-side list and
/// conversation is worth building, but it is a navigation change, not a padding
/// change, and pretending otherwise produces the worst of both. This does the
/// one thing that is true at every size: text has a width beyond which it stops
/// being comfortable to read.
///
/// On a phone it costs nothing — the constraint is never the binding one.
class ReadingColumn extends StatelessWidget {
  final Widget child;

  /// Defaults to [AegisLayout.medium], the point at which a single column of
  /// list rows stops looking like a column.
  final double maxWidth;

  const ReadingColumn({
    super.key,
    required this.child,
    this.maxWidth = AegisLayout.medium,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      // topCenter, not center: a list that is shorter than the window should
      // start at the top like a list, not float in the middle of the screen.
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
