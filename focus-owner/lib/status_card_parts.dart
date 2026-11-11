/// The card's list, field and age sub-widgets.
///
/// Split out of enforcement_status_card.dart to keep it under the 250-line cap. A `part`
/// because Dart privates are library-scoped and these widgets are private.

part of 'enforcement_status_card.dart';

/// Opens the hidden apps, each with the glyph of the rule that hid it, in a
/// sheet. A sheet rather than an in-place expansion: dozens of apps would
/// push the page's actions off the screen.
class _HiddenList extends StatelessWidget {
  const _HiddenList({required this.hidden});

  final List<HiddenPackage> hidden;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: const Key('hidden-list'),
      onPressed: () => unawaited(
        showModalBottomSheet<void>(
          context: context,
          backgroundColor: kSurface,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(kGap),
              children: [for (final entry in hidden) HiddenEntry(entry)],
            ),
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility_off,
            size: 18,
            semanticLabel: 'Why these ${hidden.length} apps are hidden',
          ),
          const SizedBox(width: 4),
          ExcludeSemantics(child: Text('${hidden.length}')),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
    );
  }
}

/// One hidden package: its name (policy data) and the hiding rule's glyph.
class HiddenEntry extends StatelessWidget {
  const HiddenEntry(this.entry, {super.key});

  final HiddenPackage entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          GlyphIcon(
            hideReasonGlyph(entry.reason),
            spoken: entry.reason.explanation,
          ),
          const SizedBox(width: kGap / 2),
          Expanded(
            child: Text(
              entry.package,
              style: const TextStyle(color: kText, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Time since the pass. Turns into a danger-coloured timer-off glyph when
/// stale, which replaces the old "schedule may have stalled" note.
class _Age extends StatelessWidget {
  const _Age({required this.at, required this.stale});

  final DateTime at;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final colour = stale ? kDanger : kMuted;
    return Semantics(
      label: stale ? 'last pass over 30 minutes ago' : 'last pass',
      child: Row(
        key: Key(stale ? 'age-stale' : 'age'),
        children: [
          Icon(
            stale ? Icons.timer_off : Icons.schedule,
            size: 16,
            color: colour,
          ),
          const SizedBox(width: 4),
          Text(
            agoLabel(at, DateTime.now()),
            style: TextStyle(color: colour, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  // A Material rather than a plain decorated box: the rows' InkWell paints
  // its ink on the nearest Material ancestor, and a DecoratedBox in between
  // swallows the ripple.
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

/// One card row: a muted icon naming the field, then its value widget.
class _Field extends StatelessWidget {
  const _Field({
    required this.icon,
    required this.child,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final Widget child;

  /// Makes the row tappable; the ripple paints because _Card is a Material.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: kMuted),
          const SizedBox(width: kGap),
          // Aligned so a lone glyph sits by its row icon, not mid-card.
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: child,
            ),
          ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }
}
