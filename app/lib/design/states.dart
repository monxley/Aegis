import 'package:flutter/material.dart';

import '../theme.dart';

/// Empty and error states.
///
/// These are part of the product, not a fallback for when there is nothing to
/// render. An empty screen is often a user's *first* screen, so it has to say
/// what this place is for and what to do next — never just "No data".
///
/// Both states share one composition: a restrained mark, a short title, one
/// sentence of orientation, and at most one action. No illustration, because a
/// decorative graphic on every empty screen is filler that ages badly.

/// A screen (or list) with nothing in it yet.
class EmptyState extends StatelessWidget {
  /// A geometric icon from the app's single icon set.
  final IconData icon;

  /// What is empty, stated plainly. Not "No data".
  final String title;

  /// One sentence: why it's empty, and what the user can do about it.
  final String message;

  /// Optional single action. More than one turns an empty state into a menu.
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        // Held to a readable measure so the sentence doesn't stretch across a
        // tablet.
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.all(ShoalSpace.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A quiet framed glyph rather than an illustration: it marks the
              // spot without pretending to be art.
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(ShoalRadius.md),
                  border: Border.all(color: ShoalColor.border),
                ),
                child: Icon(icon, size: 20, color: ShoalColor.textMuted),
              ),
              const SizedBox(height: ShoalSpace.s5),
              Text(title, style: ShoalType.heading, textAlign: TextAlign.center),
              const SizedBox(height: ShoalSpace.s2),
              Text(
                message,
                textAlign: TextAlign.center,
                style: ShoalType.secondary,
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: ShoalSpace.s6),
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: ShoalColor.accent,
                    minimumSize: const Size(0, ShoalLayout.minTouchTarget),
                  ),
                  child: Text(
                    actionLabel!,
                    style: ShoalType.secondary.copyWith(
                      color: ShoalColor.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Something went wrong.
///
/// Answers the three questions an error has to answer: what happened, whether
/// the user's data is safe, and what they can do next. The raw exception is
/// available behind "Technical details" — useful in a bug report, never the
/// first thing a user is shown.
class ErrorStateView extends StatefulWidget {
  /// What happened, in plain language. Not an exception string.
  final String title;

  /// What it means for the user, including whether their data is affected.
  final String message;

  /// The underlying error, for the expandable section.
  final Object? details;

  final String? actionLabel;
  final VoidCallback? onAction;

  const ErrorStateView({
    super.key,
    required this.title,
    required this.message,
    this.details,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<ErrorStateView> createState() => _ErrorStateViewState();
}

class _ErrorStateViewState extends State<ErrorStateView> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(ShoalSpace.s8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(ShoalRadius.md),
                  border: Border.all(color: ShoalColor.danger),
                ),
                child: const Icon(Icons.priority_high_rounded,
                    size: 20, color: ShoalColor.danger),
              ),
              const SizedBox(height: ShoalSpace.s5),
              Text(widget.title,
                  style: ShoalType.heading, textAlign: TextAlign.center),
              const SizedBox(height: ShoalSpace.s2),
              Text(widget.message,
                  textAlign: TextAlign.center, style: ShoalType.secondary),
              if (widget.actionLabel != null && widget.onAction != null) ...[
                const SizedBox(height: ShoalSpace.s6),
                TextButton(
                  onPressed: widget.onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: ShoalColor.accent,
                    minimumSize: const Size(0, ShoalLayout.minTouchTarget),
                  ),
                  child: Text(
                    widget.actionLabel!,
                    style: ShoalType.secondary.copyWith(
                      color: ShoalColor.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              if (widget.details != null) ...[
                const SizedBox(height: ShoalSpace.s4),
                Semantics(
                  button: true,
                  expanded: _showDetails,
                  child: InkWell(
                    onTap: () =>
                        setState(() => _showDetails = !_showDetails),
                    borderRadius: BorderRadius.circular(ShoalRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: ShoalSpace.s2, vertical: ShoalSpace.s2),
                      child: Text('Technical details',
                          style: ShoalType.meta
                              .copyWith(color: ShoalColor.textSecondary)),
                    ),
                  ),
                ),
                if (_showDetails)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: ShoalSpace.s2),
                    padding: const EdgeInsets.all(ShoalSpace.s3),
                    decoration: BoxDecoration(
                      color: ShoalColor.surface,
                      borderRadius: BorderRadius.circular(ShoalRadius.sm),
                      border: Border.all(color: ShoalColor.border),
                    ),
                    child: SelectableText(
                      '${widget.details}',
                      style: ShoalType.code.copyWith(
                          fontSize: 11, color: ShoalColor.textSecondary),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A one-line notice pinned above content: connection state, a blocked contact,
/// a disappearing-message timer, an available update, a device that looks
/// compromised.
///
/// One component, because these were five hand-rolled bars with five different
/// paddings, four type sizes and four ideas of what "quiet" means. A notice
/// states the fact and, where there is one, its consequence — and it never uses
/// colour alone to carry meaning, so the icon and the words still work in
/// greyscale.
///
/// [emphasis] is for the small number of notices a user must not scroll past
/// (their device looks compromised; their client is about to stop working). If
/// everything is emphasised, nothing is.
class NoticeBar extends StatelessWidget {
  /// A glyph from the app's single icon set.
  final IconData icon;

  /// The state, in one or two words.
  final String label;

  /// What it means for the user.
  final String? detail;

  /// The tone the icon and label take. Defaults to neutral.
  final Color tone;

  /// Tint the whole bar in [tone] and let the detail wrap. Reserve it for
  /// notices that carry a real consequence.
  final bool emphasis;

  /// Makes the whole bar a button — used when there is exactly one obvious
  /// thing to do about it.
  final VoidCallback? onTap;

  /// Adds a dismiss control. Only for notices the user is allowed to ignore.
  final VoidCallback? onDismiss;

  const NoticeBar({
    super.key,
    required this.icon,
    required this.label,
    this.detail,
    this.tone = ShoalColor.textSecondary,
    this.emphasis = false,
    this.onTap,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    // The text of the bar. Wrapped in ExcludeSemantics because the whole bar
    // already carries one composed label — without this a screen reader reads
    // the icon, the label and the detail as three separate nodes.
    final content = ExcludeSemantics(
      child: Row(
        children: [
          Icon(icon, size: 14, color: tone),
          const SizedBox(width: ShoalSpace.s2),
          Text(
            label,
            style: ShoalType.meta
                .copyWith(color: tone, fontWeight: FontWeight.w600),
          ),
          if (detail != null) ...[
            const SizedBox(width: ShoalSpace.s2),
            Expanded(
              child: Text(
                detail!,
                // An emphasised notice is allowed the room to be understood;
                // a quiet one stays exactly one line tall.
                maxLines: emphasis ? 3 : 1,
                overflow: TextOverflow.ellipsis,
                style: ShoalType.meta.copyWith(
                  color: emphasis ? tone : ShoalColor.textMuted,
                  height: emphasis ? 1.35 : null,
                ),
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );

    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ShoalSpace.s4,
        vertical: ShoalSpace.s2,
      ),
      child: Row(
        children: [
          // Semantics(label:) sits on the bar itself, so the content is the
          // labelled thing and the dismiss button stays a separate target.
          Expanded(
            child: Semantics(
              label: _spoken,
              button: onTap != null,
              child: content,
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, size: 16, color: tone),
              onPressed: onDismiss,
            )
          else if (onTap != null)
            ExcludeSemantics(
              child: Icon(Icons.chevron_right_rounded, size: 16, color: tone),
            ),
        ],
      ),
    );

    return Semantics(
      // Announced when it appears: a connection dropping is exactly the kind of
      // change a screen-reader user otherwise never learns about.
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: emphasis ? tone.withValues(alpha: 0.12) : ShoalColor.surface,
          border: const Border(bottom: BorderSide(color: ShoalColor.border)),
        ),
        child: Material(
          color: Colors.transparent,
          child: onTap == null
              ? row
              : InkWell(onTap: onTap, child: row),
        ),
      ),
    );
  }

  String get _spoken => detail == null ? label : '$label. $detail';
}

/// Report a failure the user did not cause and cannot be shown in place.
///
/// The message is plain language: what did not happen, and what they can do.
/// The exception goes behind "Details" — useful in a bug report, never the
/// first thing a user is handed. `Exception: FormatException: Invalid
/// argument(s)` tells a person nothing except that the app broke.
void showFailure(
  BuildContext context, {
  required String message,
  Object? details,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: details == null
            ? null
            : SnackBarAction(
                label: 'Details',
                textColor: ShoalColor.accent,
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: ShoalColor.surface,
                    title: const Text('Technical details',
                        style: ShoalType.heading),
                    content: SingleChildScrollView(
                      child: SelectableText(
                        '$details',
                        style: ShoalType.code.copyWith(
                          fontSize: 12,
                          color: ShoalColor.textSecondary,
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Close',
                            style: TextStyle(color: ShoalColor.textSecondary)),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
}
