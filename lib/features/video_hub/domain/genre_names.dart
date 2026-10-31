import 'package:flutter/foundation.dart';

/// What a genre CODE means, in each language the app speaks.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE DATABASE STORES CODES; THE WORDS LIVE IN ONE TABLE
/// ═══════════════════════════════════════════════════════════════════════
///
/// Since migration 058 a title's genres are `genre_codes` (`G001`, `G002`),
/// assigned by the database and never reused, and the names are rows in
/// `public.genres` that the console owns: renamed, translated, merged or
/// retired there, and nowhere else. The app learns the names from
/// `rpc/taxonomy`, once, and keeps them.
///
/// So the code is the IDENTITY — what a filter sends, what a saved filter
/// holds — and the label is PRESENTATION, chosen by the phone's language at
/// the moment of drawing. Renaming "Animation" in the console changes every
/// screen at the next launch and no filter breaks, because no filter ever
/// held the word.
///
/// A MERGED code resolves to the genre it was merged into, so a title or a
/// saved filter still holding the old code shows the surviving name. A
/// RETIRED code still has its name (titles may carry it until the operator
/// re-files them); [offered] is what the filter sheet may show.
@immutable
class GenreNames {
  final Map<String, GenreName> byCode;

  const GenreNames(this.byCode);

  static const GenreNames empty = GenreNames(<String, GenreName>{});

  bool get isEmpty => byCode.isEmpty;

  /// What `G###` looks like. Anything else is a word from an older server
  /// or from the demo catalogue, and is shown as it is.
  static final RegExp _code = RegExp(r'^G[0-9]{3}$');

  static bool isCode(String key) => _code.hasMatch(key);

  /// Whether every key is a code this table can name.
  bool knowsAll(Iterable<String> keys) {
    for (final k in keys) {
      if (_resolve(k) == null) return false;
    }
    return true;
  }

  /// The name for [key] in [languageCode], or null for a code nobody has
  /// described. A key that is not a code at all IS its own name.
  String? labelOf(String key, String? languageCode) {
    if (!isCode(key)) return key;
    return _resolve(key)?.label(languageCode);
  }

  /// [codes] as names, in order, without repeats (two codes merged into one
  /// genre would otherwise say the same word twice). Null when any code is
  /// unknown: the caller then shows the words the server sent beside them
  /// rather than half a list.
  List<String>? labelsOf(List<String> codes, String? languageCode) {
    final out = <String>[];
    final seen = <String>{};
    for (final c in codes) {
      final g = _resolve(c);
      if (g == null) return null;
      if (seen.add(g.code)) out.add(g.label(languageCode));
    }
    return out;
  }

  /// The filter sheet's genre chips: [codes] (what the catalogue's titles
  /// carry) resolved through merges, without repeats, without the genres the
  /// console has retired or stopped offering, in the console's order.
  List<String> offered(Iterable<String> codes) {
    final picked = <String, GenreName>{};
    for (final c in codes) {
      final g = _resolve(c);
      if (g == null || g.retired || !g.visible) continue;
      picked[g.code] = g;
    }
    final out = picked.values.toList()
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.code.compareTo(b.code);
      });
    return <String>[for (final g in out) g.code];
  }

  GenreName? _resolve(String code) {
    var g = byCode[code];
    // A merge chain is one step in practice (the console refuses to merge
    // into a merged genre), but a loop must not hang a frame: bounded.
    for (var hops = 0; g != null && g.mergedInto != null && hops < 8; hops++) {
      final next = byCode[g.mergedInto];
      if (next == null) break;
      g = next;
    }
    return g;
  }

  /// Read the `genres` array of `rpc/taxonomy`. Rows with no code or no
  /// English label are skipped: there is nothing to file or nothing to show.
  factory GenreNames.fromJson(Object? list) {
    if (list is! List) return GenreNames.empty;
    final byCode = <String, GenreName>{};
    for (final row in list) {
      if (row is! Map) continue;
      final code = '${row['code'] ?? ''}'.trim();
      final label = '${row['label'] ?? ''}'.trim();
      if (!isCode(code) || label.isEmpty) continue;
      final into = row['merged_into'];
      byCode[code] = GenreName(
        code: code,
        en: label,
        mm: row['label_mm'] is String ? row['label_mm'] as String : null,
        th: row['label_th'] is String ? row['label_th'] as String : null,
        retired: row['retired'] == true,
        visible: row['visible'] != false,
        sortOrder: row['sort_order'] is num ? (row['sort_order'] as num).toInt() : 0,
        mergedInto: into is String && isCode(into) ? into : null,
      );
    }
    return GenreNames(byCode);
  }
}

@immutable
class GenreName {
  final String code;
  final String en;
  final String? mm;
  final String? th;
  final bool retired;
  final bool visible;
  final int sortOrder;
  final String? mergedInto;

  const GenreName({
    required this.code,
    required this.en,
    this.mm,
    this.th,
    this.retired = false,
    this.visible = true,
    this.sortOrder = 0,
    this.mergedInto,
  });

  /// Same fallback rule as a category's label: a blank translation falls
  /// back to English rather than drawing an empty chip.
  String label(String? languageCode) {
    final local = switch (languageCode) {
      'my' => mm,
      'th' => th,
      _ => null,
    }
        ?.trim();
    return (local == null || local.isEmpty) ? en : local;
  }
}
