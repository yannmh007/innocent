import '../data/watch_state_store.dart';
import '../domain/video_content.dart';

/// The server's key for Continue watching (migration 039).
const String kRowContinue = 'continue';

/// The landing rows with Continue watching as THIS PHONE knows it.
///
/// WHY NOT SIMPLY THE SERVER'S ROW. Progress reaches the server in batches,
/// and the landing page is drawn from a saved copy first (CatalogueCache), so
/// coming back from a film the server's row is a step behind: the film just
/// watched is missing, or not first, or shows where it was an hour ago.
/// Netflix's row is right the moment you leave the player. So the order and
/// the positions come from the phone's own ledger, newest first, and the
/// server's row adds what this phone has not seen — the account's other
/// phones. A title finished or removed here stays out even if the server's
/// copy still lists it.
///
/// Cards are taken from the rows themselves (a ledger holds ids, not cards);
/// a title on no row cannot be drawn and is left out until the server's row
/// carries it.
List<ContentRow> withLocalContinue(List<ContentRow> rows, WatchLedger ledger) {
  final serverIndex = rows.indexWhere((r) => r.key == kRowContinue);
  final server = serverIndex < 0 ? null : rows[serverIndex];

  final cards = <String, VideoContent>{};
  for (final r in rows) {
    for (final c in r.items) {
      cards.putIfAbsent(c.id, () => c);
    }
  }

  final items = <VideoContent>[];
  final resume = <String, ResumeHint>{};
  for (final p in ledger.continueWatching) {
    final card = cards[p.titleId];
    if (card == null) continue;
    items.add(card);
    resume[p.titleId] = ResumeHint(
        assetId: p.assetId, positionS: p.positionS, durationS: p.durationS);
  }
  for (final c in server?.items ?? const <VideoContent>[]) {
    if (resume.containsKey(c.id)) continue;
    if (ledger.hidden.contains(c.id)) continue;
    final mine = ledger.latestFor(c.id);
    // Watched here since: this phone's answer is the newer one.
    if (mine != null && !mine.resumable) continue;
    items.add(c);
    final hint = server!.resume[c.id];
    if (hint != null) resume[c.id] = hint;
  }

  final merged = ContentRow(
    key: kRowContinue,
    fallbackTitle: server?.fallbackTitle ?? 'Continue watching',
    fallbackTitleMm: server?.fallbackTitleMm ?? 'ဆက်ကြည့်ရန်',
    items: items,
    resume: resume,
  );

  final out = <ContentRow>[...rows];
  if (serverIndex >= 0) {
    if (items.isEmpty) {
      out.removeAt(serverIndex);
    } else {
      out[serverIndex] = merged;
    }
  } else if (items.isNotEmpty) {
    out.insert(0, merged);
  }
  return out;
}
