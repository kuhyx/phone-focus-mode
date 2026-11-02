/// The card's list, field and note sub-widgets.
///
/// Split out of enforcement_status_card.dart to keep it under the 250-line cap. A `part`
/// because Dart privates are library-scoped and these widgets are private.

part of 'enforcement_status_card.dart';

/// A link that opens the hidden apps, each with the rule that hid it, in a
/// sheet. A sheet rather than an in-place expansion: dozens of apps would
/// push the page's actions off the screen.
class _HiddenList extends StatelessWidget {
  const _HiddenList({required this.hidden});

  final List<HiddenPackage> hidden;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => unawaited(
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: kSurface,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(kGap),
              children: [for (final entry in hidden) _HiddenEntry(entry)],
            ),
          ),
        ),
      ),
      child: Text(
        'Why these ${hidden.length} apps are hidden',
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14),
      ),
    );
  }
}

class _HiddenEntry extends StatelessWidget {
  const _HiddenEntry(this.entry);

  final HiddenPackage entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              entry.package,
              style: const TextStyle(color: kText, fontSize: 12),
            ),
          ),
          const SizedBox(width: kGap / 2),
          Text(
            entry.reason.explanation,
            style: TextStyle(
              color: entry.reason == HideReason.alwaysBlocked ? kDanger : kMuted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  // A Material rather than a plain decorated box: the hidden-apps
  // ExpansionTile paints its ink on the nearest Material ancestor, and a
  // DecoratedBox in between swallows the ripple.
  @override
  Widget build(BuildContext context) => Material(
    color: kSurface,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(kGap),
      child: child,
    ),
  );
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    this.danger = false,
    this.onTap,
  });

  final String label;
  final String value;
  final bool danger;

  /// Makes the row tappable; the ripple paints because _Card is a Material.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = _row();
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }

  Widget _row() => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 150,
          child: Text(
            label,
            style: const TextStyle(color: kMuted, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: danger ? kDanger : kText, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        color: danger ? kDanger : kWarn,
        fontSize: 12,
        height: 1.3,
      ),
    ),
  );
}
