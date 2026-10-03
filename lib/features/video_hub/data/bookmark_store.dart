import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';
import 'api/api_exception.dart';

/// One saved title and when it was saved.
@immutable
class BookmarkEntry {
  final String id;
  final DateTime at;
  const BookmarkEntry(this.id, this.at);

  Map<String, dynamic> toJson() => {'id': id, 'at': at.toUtc().toIso8601String()};

  static BookmarkEntry? fromJson(Object? o) {
    if (o is! Map) return null;
    final id = o['id'];
    final at = DateTime.tryParse('${o['at']}');
    if (id is! String || id.isEmpty || at == null) return null;
    return BookmarkEntry(id, at);
  }
}

/// The bookmarks as this phone knows them, and what it still owes the server.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE SHAPE, AND WHY
/// ═══════════════════════════════════════════════════════════════════════
///
/// LOCAL FIRST. A tap saves at once — offline, signed out, on a train — and
/// the shelf draws from this. The server copy (migration 036) is what makes a
/// bookmark outlive a reinstall or follow the viewer to another phone.
///
/// THE TWO PENDING SETS are the outbox: adds and removes made here that the
/// server has not acknowledged. A sync pushes them, then takes the server's
/// list as the truth — minus what is still pending removal, plus what is still
/// pending addition — so a change made offline is never undone by a pull, and
/// a change made on another phone still arrives.
///
/// [owner] IS WHOSE LIST THIS IS: a user id, or null for a viewer who has not
/// signed in. When someone else signs in on this phone, the previous owner's
/// list is not pushed into their account — it is dropped (it is safe on the
/// server) and theirs is pulled. A signed-out list is adopted by whoever signs
/// in first, which is the person who made it.
///
/// Immutable: every change returns a new ledger, so a notifier can hold it as
/// state and a test can assert on it without a phone.
@immutable
class BookmarkLedger {
  final List<BookmarkEntry> items; // newest first
  final Set<String> pendingAdd;
  final Set<String> pendingRemove;
  final String? owner;

  const BookmarkLedger({
    this.items = const <BookmarkEntry>[],
    this.pendingAdd = const <String>{},
    this.pendingRemove = const <String>{},
    this.owner,
  });

  static const BookmarkLedger empty = BookmarkLedger();

  bool contains(String id) => items.any((e) => e.id == id);
  List<String> get ids => items.map((e) => e.id).toList(growable: false);
  int get length => items.length;
  bool get hasPending => pendingAdd.isNotEmpty || pendingRemove.isNotEmpty;

  BookmarkLedger add(String id, DateTime now) {
    if (contains(id)) return this;
    return BookmarkLedger(
      items: <BookmarkEntry>[BookmarkEntry(id, now), ...items],
      pendingAdd: {...pendingAdd, id},
      pendingRemove: {...pendingRemove}..remove(id),
      owner: owner,
    );
  }

  BookmarkLedger remove(String id) {
    if (!contains(id) && !pendingAdd.contains(id)) return this;
    final wasOnlyLocal = pendingAdd.contains(id);
    return BookmarkLedger(
      items: items.where((e) => e.id != id).toList(growable: false),
      pendingAdd: {...pendingAdd}..remove(id),
      // An add the server never saw needs no delete.
      pendingRemove: wasOnlyLocal ? pendingRemove : {...pendingRemove, id},
      owner: owner,
    );
  }

  /// Puts back an entry exactly as it was — the Undo after a remove.
  BookmarkLedger restore(BookmarkEntry e) {
    if (contains(e.id)) return this;
    final next = <BookmarkEntry>[...items, e]..sort((a, b) => b.at.compareTo(a.at));
    final wasPendingRemove = pendingRemove.contains(e.id);
    return BookmarkLedger(
      items: next,
      // If the delete was not sent yet, cancelling it is enough; otherwise the
      // server needs the add again.
      pendingAdd: wasPendingRemove ? pendingAdd : {...pendingAdd, e.id},
      pendingRemove: {...pendingRemove}..remove(e.id),
      owner: owner,
    );
  }

  /// The server acknowledged these.
  BookmarkLedger acked({Set<String> adds = const {}, Set<String> removes = const {}}) =>
      BookmarkLedger(
        items: items,
        pendingAdd: pendingAdd.difference(adds),
        pendingRemove: pendingRemove.difference(removes),
        owner: owner,
      );

  /// The server's list, with this phone's unsent changes laid over it.
  BookmarkLedger mergeServer(List<BookmarkEntry> server) {
    final byId = <String, BookmarkEntry>{
      for (final e in server)
        if (!pendingRemove.contains(e.id)) e.id: e,
    };
    for (final e in items) {
      if (pendingAdd.contains(e.id)) byId.putIfAbsent(e.id, () => e);
    }
    final next = byId.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    return BookmarkLedger(
      items: next,
      pendingAdd: pendingAdd,
      pendingRemove: pendingRemove,
      owner: owner,
    );
  }

  BookmarkLedger ownedBy(String? user) => BookmarkLedger(
        items: items,
        pendingAdd: pendingAdd,
        pendingRemove: pendingRemove,
        owner: user,
      );

  Map<String, dynamic> toJson() => {
        'v': 1,
        'owner': owner,
        'items': items.map((e) => e.toJson()).toList(),
        'add': pendingAdd.toList(),
        'remove': pendingRemove.toList(),
      };

  static BookmarkLedger fromJson(Object? o) {
    if (o is! Map) return empty;
    final items = <BookmarkEntry>[
      for (final raw in (o['items'] as List?) ?? const <Object?>[])
        if (BookmarkEntry.fromJson(raw) case final e?) e,
    ]..sort((a, b) => b.at.compareTo(a.at));
    Set<String> set(Object? v) =>
        {for (final x in (v as List?) ?? const <Object?>[]) if (x is String) x};
    return BookmarkLedger(
      items: items,
      pendingAdd: set(o['add']),
      pendingRemove: set(o['remove']),
      owner: o['owner'] as String?,
    );
  }
}

/// Where the ledger is kept on the phone.
class BookmarkStore {
  const BookmarkStore();
  static const String _key = 'vh_bookmarks_v1';

  Future<BookmarkLedger> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw == null) return BookmarkLedger.empty;
      return BookmarkLedger.fromJson(jsonDecode(raw));
    } catch (e) {
      if (kDebugMode) debugPrint('BookmarkStore.load: $e');
      return BookmarkLedger.empty;
    }
  }

  Future<void> save(BookmarkLedger ledger) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_key, jsonEncode(ledger.toJson()));
    } catch (e) {
      if (kDebugMode) debugPrint('BookmarkStore.save: $e');
    }
  }
}

/// The server half: push the outbox, pull the list. Signed-in only.
class BookmarkRemote {
  const BookmarkRemote(this._api);
  final ApiClient _api;

  static const String _path = '/rest/v1/bookmarks';

  /// Sends the outbox and returns the ledger with what was acknowledged.
  ///
  /// One failure stops the push and keeps the rest pending: on a connection
  /// that has just dropped, the next request will fail too, and the outbox is
  /// exactly where those changes should wait.
  Future<BookmarkLedger> push(BookmarkLedger ledger) async {
    final addsDone = <String>{};
    final removesDone = <String>{};
    try {
      for (final id in ledger.pendingAdd) {
        final at = ledger.items
            .firstWhere((e) => e.id == id, orElse: () => BookmarkEntry(id, DateTime.now()))
            .at;
        try {
          await _api.postJson(
            _path,
            body: {'title_id': id, 'added_at': at.toUtc().toIso8601String()},
            // Saved on another phone already: not an error, just done.
            extraHeaders: const {'Prefer': 'resolution=ignore-duplicates,return=minimal'},
          );
        } on ApiException catch (e) {
          // A title that no longer exists (foreign key) or an id that is not
          // a title at all: it can never be saved, so it leaves the outbox.
          if (e.statusCode == 409 || e.statusCode == 400) {
            addsDone.add(id);
            continue;
          }
          rethrow;
        }
        addsDone.add(id);
      }
      for (final id in ledger.pendingRemove) {
        await _api.deleteJson(_path, query: {'title_id': 'eq.$id'});
        removesDone.add(id);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('BookmarkRemote.push: $e');
    }
    return ledger.acked(adds: addsDone, removes: removesDone);
  }

  /// The signed-in user's bookmarks, newest first. Throws on failure.
  Future<List<BookmarkEntry>> pull() async {
    final body = await _api.getJson(_path, query: const {
      'select': 'title_id,added_at',
      'order': 'added_at.desc',
      'limit': '1000',
    });
    if (body is! List) return const <BookmarkEntry>[];
    return <BookmarkEntry>[
      for (final row in body)
        if (row is Map &&
            row['title_id'] is String &&
            DateTime.tryParse('${row['added_at']}') != null)
          BookmarkEntry(row['title_id'] as String, DateTime.parse('${row['added_at']}')),
    ];
  }
}
