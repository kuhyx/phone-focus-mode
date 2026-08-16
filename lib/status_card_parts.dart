/// The card's list, field and note sub-widgets.
///
/// Split out of enforcement_status_card.dart to keep it under the 250-line cap. A `part`
/// because Dart privates are library-scoped and these widgets are private.

part of 'enforcement_status_card.dart';

/// The hidden apps, each with the rule that hid it.
class _HiddenList extends StatelessWidget {
  const _HiddenList({required this.hidden});

  final List<HiddenPackage> hidden;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(
          'Why these ${hidden.length} apps are hidden',
          style: const TextStyle(color: kAccent, fontSize: 14),
        ),
        children: [
          for (final entry in hidden)
            Padding(
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
                      color: entry.reason == HideReason.alwaysBlocked
                          ? kDanger
                          : kMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
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
  const _Field({required this.label, required this.value, this.danger = false});

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) => Padding(
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
                style: TextStyle(
                  color: danger ? kDanger : kText,
                  fontSize: 13,
                ),
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
