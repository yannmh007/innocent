import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api/backend_config.dart';
import '../data/api/event_sender.dart';
import '../data/bookmark_store.dart';
import '../domain/video_content.dart';
import 'account_provider.dart';
import 'video_hub_provider.dart';

/// The viewer's bookmarks. See [BookmarkLedger] for the model and why it is
/// shaped the way it is.
///
/// Reads come from the ledger in memory, so the bookmark icon on a detail
/// screen is right on its first frame. Writes go to the phone at once and to
/// the server when signed in — never blocking the tap on the network.
class TitleBookmarksNotifier extends StateNotifier<BookmarkLedger> {
  TitleBookmarksNotifier(this._ref, {BookmarkStore store = const BookmarkStore()})
      : _store = store,
        super(BookmarkLedger.empty) {
    unawaited(_boot());
  }

  final Ref _ref;
  final BookmarkStore _store;
  bool _loaded = false;
  Future<void>? _syncing;
  bool _syncAgain = false;

  Future<void> _boot() async {
    final saved = await _store.load();
    if (!mounted) return;
    // A tap that landed before the load finished is kept on top of it.
    state = saved.mergeLocal(state);
    _loaded = true;
    _ref.listen<AccountState>(accountProvider, (prev, next) {
      if (next.isLoading) return;
      if (prev?.user?.id != next.user?.id || prev?.isLoading == true) {
        unawaited(sync());
      }
    }, fireImmediately: true);
  }

  bool isSaved(String id) => state.contains(id);

  /// Saves or unsaves [content]. Returns true when it is now saved.
  bool toggle(VideoContent content) {
    final saved = state.contains(content.id);
    _set(saved ? state.remove(content.id) : state.add(content.id, DateTime.now()));
    _log(saved ? Ev.bookmarkRemove : Ev.bookmarkAdd, content.id);
    unawaited(sync());
    return !saved;
  }

  /// Takes a bookmark back out, keeping what is needed to put it back.
  BookmarkEntry? remove(String id) {
    final entry = state.items.where((e) => e.id == id).firstOrNull;
    if (entry == null) return null;
    _set(state.remove(id));
    _log(Ev.bookmarkRemove, id);
    unawaited(sync());
    return entry;
  }

  /// The Undo after [remove]: back in its old place, with its old date.
  void restore(BookmarkEntry entry) {
    _set(state.restore(entry));
    _log(Ev.bookmarkAdd, entry.id);
    unawaited(sync());
  }

  void _set(BookmarkLedger next) {
    state = next;
    unawaited(_store.save(next));
  }

  void _log(String kind, String titleId) {
    try {
      _ref.read(eventSenderProvider).log(kind, titleId: titleId);
    } catch (e) {
      if (kDebugMode) debugPrint('bookmark event: $e');
    }
  }

  /// Pushes the outbox and pulls the server's list, when signed in.
  ///
  /// One at a time: a tap during a sync asks for one more pass afterwards
  /// rather than starting a second, interleaved one.
  Future<void> sync() {
    if (!_loaded) return Future.value();
    if (_syncing != null) {
      _syncAgain = true;
      return _syncing!;
    }
    final run = _syncOnce().whenComplete(() {
      _syncing = null;
      if (_syncAgain && mounted) {
        _syncAgain = false;
        unawaited(sync());
      }
    });
    _syncing = run;
    return run;
  }

  Future<void> _syncOnce() async {
    final account = _ref.read(accountProvider);
    final user = account.user?.id;
    if (account.isLoading) return;

    if (user == null) {
      // Signed out. A list that belonged to an account leaves with it — it is
      // safe on the server, and the next person to use this phone should not
      // see it or, worse, have it pushed into their own account.
      if (state.owner != null) _set(BookmarkLedger.empty);
      return;
    }
    if (!BackendConfig.isConfigured) return;

    var ledger = state;
    if (ledger.owner != null && ledger.owner != user) {
      ledger = BookmarkLedger.empty; // someone else's: drop, then pull ours
    }
    ledger = ledger.ownedBy(user);
    final remote = BookmarkRemote(_ref.read(apiClientProvider));
    try {
      ledger = await remote.push(ledger);
      final server = await remote.pull();
      if (!mounted) return;
      // Changes made while the network was busy are laid over the result.
      _set(ledger.mergeServer(server).mergeLocal(state.owner == user ? state : null));
    } catch (e) {
      // Offline or the server is unhappy: keep everything, try next time.
      if (kDebugMode) debugPrint('bookmarks sync: $e');
      if (mounted && state.owner != user) _set(ledger);
    }
  }
}

extension on BookmarkLedger {
  /// Lays the unsent changes of [newer] — made while a sync was in flight —
  /// over this ledger, so a tap is never lost to a pull that started first.
  BookmarkLedger mergeLocal(BookmarkLedger? newer) {
    if (newer == null) return this;
    var out = this;
    for (final id in newer.pendingAdd) {
      final e = newer.items.where((x) => x.id == id).firstOrNull;
      if (e != null && !out.contains(id)) out = out.restore(e);
    }
    for (final id in newer.pendingRemove) {
      if (out.contains(id)) out = out.remove(id);
    }
    return out;
  }
}

final titleBookmarksProvider =
    StateNotifierProvider<TitleBookmarksNotifier, BookmarkLedger>(
        (ref) => TitleBookmarksNotifier(ref));

/// Whether one title is saved. Selected, so a detail screen rebuilds when its
/// own title flips and not when any other does.
final isTitleBookmarkedProvider = Provider.family<bool, String>(
    (ref, id) => ref.watch(titleBookmarksProvider.select((l) => l.contains(id))));

/// The saved titles themselves, in bookmark order.
final bookmarkedTitlesProvider =
    FutureProvider.autoDispose<List<VideoContent>>((ref) async {
  final ids = ref.watch(titleBookmarksProvider.select((l) => l.ids.join(',')));
  if (ids.isEmpty) return const <VideoContent>[];
  final order = ids.split(',');
  final found = await ref.watch(contentRepositoryProvider).getByIds(order);
  final byId = {for (final c in found) c.id: c};
  return <VideoContent>[
    for (final id in order)
      if (byId[id] case final c?) c,
  ];
});
