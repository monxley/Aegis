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
          padding: const EdgeInsets.all(AegisSpace.s8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A quiet framed glyph rather than an illustration: it marks the
              // spot without pretending to be art.
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AegisRadius.md),
                  border: Border.all(color: AegisColor.border),
                ),
                child: Icon(icon, size: 20, color: AegisColor.textMuted),
              ),
              const SizedBox(height: AegisSpace.s5),
              Text(title, style: AegisType.heading, textAlign: TextAlign.center),
              const SizedBox(height: AegisSpace.s2),
              Text(
                message,
                textAlign: TextAlign.center,
                style: AegisType.secondary,
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AegisSpace.s6),
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: AegisColor.accent,
                    minimumSize: const Size(0, AegisLayout.minTouchTarget),
                  ),
                  child: Text(
                    actionLabel!,
                    style: AegisType.secondary.copyWith(
                      color: AegisColor.accent,
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
        padding: const EdgeInsets.all(AegisSpace.s8),
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
                  borderRadius: BorderRadius.circular(AegisRadius.md),
                  border: Border.all(color: AegisColor.danger),
                ),
                child: const Icon(Icons.priority_high_rounded,
                    size: 20, color: AegisColor.danger),
              ),
              const SizedBox(height: AegisSpace.s5),
              Text(widget.title,
                  style: AegisType.heading, textAlign: TextAlign.center),
              const SizedBox(height: AegisSpace.s2),
              Text(widget.message,
                  textAlign: TextAlign.center, style: AegisType.secondary),
              if (widget.actionLabel != null && widget.onAction != null) ...[
                const SizedBox(height: AegisSpace.s6),
                TextButton(
                  onPressed: widget.onAction,
                  style: TextButton.styleFrom(
                    foregroundColor: AegisColor.accent,
                    minimumSize: const Size(0, AegisLayout.minTouchTarget),
                  ),
                  child: Text(
                    widget.actionLabel!,
                    style: AegisType.secondary.copyWith(
                      color: AegisColor.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              if (widget.details != null) ...[
                const SizedBox(height: AegisSpace.s4),
                Semantics(
                  button: true,
                  expanded: _showDetails,
                  child: InkWell(
                    onTap: () =>
                        setState(() => _showDetails = !_showDetails),
                    borderRadius: BorderRadius.circular(AegisRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AegisSpace.s2, vertical: AegisSpace.s2),
                      child: Text('Technical details',
                          style: AegisType.meta
                              .copyWith(color: AegisColor.textSecondary)),
                    ),
                  ),
                ),
                if (_showDetails)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: AegisSpace.s2),
                    padding: const EdgeInsets.all(AegisSpace.s3),
                    decoration: BoxDecoration(
                      color: AegisColor.surface,
                      borderRadius: BorderRadius.circular(AegisRadius.sm),
                      border: Border.all(color: AegisColor.border),
                    ),
                    child: SelectableText(
                      '${widget.details}',
                      style: AegisType.code.copyWith(
                          fontSize: 11, color: AegisColor.textSecondary),
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
