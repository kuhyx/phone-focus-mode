/// The StatusPage AppBar, its refresh action and the shared SnackBar helper.
///
/// Split out of status_page_state.dart to keep it under the 250-line cap. A
/// `part` because the builders are library-private, same as the rest of the
/// StatusPage split.

part of 'main.dart';

/// The refresh action runs a full enforcement pass with a fresh fix rather
/// than re-reading the stored record: re-reading never acquired a location,
/// so the fix age on the card never moved and the icon looked broken. While
/// busy the icon is replaced by a spinner instead of silently greyed out.
PreferredSizeWidget _statusAppBar({
  required bool busy,
  required Future<void> Function() onRefresh,
}) {
  return AppBar(
    backgroundColor: kField,
    foregroundColor: kText,
    title: const Text('Focus Owner'),
    actions: [
      if (busy)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: kGap),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      else
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
        ),
    ],
  );
}

void _showSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
