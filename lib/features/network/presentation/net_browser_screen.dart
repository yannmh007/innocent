import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/router/routes.dart';
import '../../../core/services/subtitles/subtitle_download_service.dart';
import '../../player/presentation/up_next.dart';
import '../data/net_repository.dart';
import '../data/net_server.dart';
import 'net_errors.dart';
import 'net_widgets.dart';

enum _Sort { name, date, size }

/// One server's files: folders first, a path bar to jump back up, and a
/// video that plays the moment it is tapped — seekable, with its subtitle
/// and the next episode lined up, the way a file on the phone would.
class NetBrowserScreen extends ConsumerStatefulWidget {
  const NetBrowserScreen({super.key, required this.server, this.home});
  final NetServer server;

  /// Where the sign-in landed (the form already asked); null = ask.
  final String? home;

  @override
  ConsumerState<NetBrowserScreen> createState() => _NetBrowserScreenState();
}

class _NetBrowserScreenState extends ConsumerState<NetBrowserScreen> {
  late NetServer _server = widget.server;
  String? _home;
  String _path = '/';
  List<NetEntry>? _entries;
  NetFailure? _failure;
  bool _loading = true;
  _Sort _sort = _Sort.name;
  bool _mediaOnly = false;
  int _ticket = 0;

  /// Scroll position per folder, so Back lands where you were.
  final Map<String, double> _offsets = <String, double>{};
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _home = widget.home;
    unawaited(ref.read(netServersProvider.notifier).touch(_server.id));
    unawaited(_open(widget.home ??
        (_server.protocol == NetProtocol.smb
            ? '/${_server.path.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '')}'
            : null)));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _spec() =>
      ref.read(netServersProvider.notifier).specOf(_server);

  /// Lists [path] (null = the server's start folder, learned by signing in).
  Future<void> _open(String? path) async {
    final t = ++_ticket;
    if (_entries != null && _scroll.hasClients) {
      _offsets[_path] = _scroll.offset;
    }
    setState(() {
      _loading = true;
      _failure = null;
    });
    final channel = ref.read(netChannelProvider);
    try {
      var target = path;
      if (target == null || target.isEmpty) {
        final r = await channel.connect(await _spec());
        _home = r.home;
        target = r.home;
      }
      final list = await channel.list(await _spec(), target);
      if (!mounted || t != _ticket) return;
      setState(() {
        _path = target!;
        _home ??= target;
        _entries = list;
        _loading = false;
      });
      final off = _offsets[target];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(off ?? 0);
      });
    } on NetFailure catch (f) {
      if (!mounted || t != _ticket) return;
      if (f.code == 'hostkey_changed' &&
          await confirmNewIdentity(context, f, _server)) {
        await ref.read(netServersProvider.notifier).pin(_server.id, f.detail);
        _server = _server.copyWith(pinned: f.detail);
        return _open(path);
      }
      if (!mounted) return;
      setState(() {
        _failure = f;
        _loading = false;
      });
    }
  }

  /// Back leaves the server from where it started (or from the very top);
  /// the path bar still climbs above the start folder.
  bool get _atRoot => _path == '/' || _path == _home;

  String _parent(String p) {
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  Future<bool> _back() async {
    if (_loading && _entries == null) return true;
    if (_atRoot) return true;
    await _open(_parent(_path));
    return false;
  }

  List<NetEntry> get _sorted {
    final all = (_entries ?? const <NetEntry>[])
        .where((e) => !_mediaOnly || e.dir || e.isPlayable)
        .toList();
    int by(NetEntry a, NetEntry b) {
      switch (_sort) {
        case _Sort.date:
          return b.modified.compareTo(a.modified);
        case _Sort.size:
          return b.size.compareTo(a.size);
        case _Sort.name:
          return _natural(a.name, b.name);
      }
    }

    all.sort((a, b) => a.dir != b.dir ? (a.dir ? -1 : 1) : by(a, b));
    return all;
  }

  /// "Episode 2" before "Episode 10".
  static int _natural(String a, String b) {
    final re = RegExp(r'(\d+)|(\D+)');
    final x = re.allMatches(a.toLowerCase()).toList();
    final y = re.allMatches(b.toLowerCase()).toList();
    for (var i = 0; i < x.length && i < y.length; i++) {
      final p = x[i].group(0)!, q = y[i].group(0)!;
      final pn = int.tryParse(p), qn = int.tryParse(q);
      final c = (pn != null && qn != null) ? pn.compareTo(qn) : p.compareTo(q);
      if (c != 0) return c;
    }
    return x.length.compareTo(y.length);
  }

  Future<void> _tap(NetEntry e) async {
    if (e.dir) return _open(e.path);
    if (!e.isPlayable) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text(AppStrings.of(context).netNotPlayable)));
      return;
    }
    await _play(e, _sorted);
  }

  /// Plays [e] through the loopback door, with the same-name subtitle
  /// attached and the next video of the folder offered at the end.
  Future<void> _play(NetEntry e, List<NetEntry> folder) async {
    final channel = ref.read(netChannelProvider);
    try {
      final spec = await _spec();
      final url = await channel.url(spec, e.path);
      // A subtitle beside it — film.mkv + film.srt / film.en.srt — goes in
      // before the player opens, so it is on from the first frame.
      final base = e.name.contains('.')
          ? e.name.substring(0, e.name.lastIndexOf('.'))
          : e.name;
      final subs = folder
          .where((x) => x.isSubtitle && x.name.startsWith(base))
          .toList()
        ..sort((a, b) => a.name.length.compareTo(b.name.length));
      if (subs.isNotEmpty && subs.first.size < 5 * 1024 * 1024) {
        try {
          final subUrl = await channel.url(spec, subs.first.path);
          await ref
              .read(subtitleDownloadServiceProvider)
              .downloadFor(videoUri: url, url: subUrl);
        } catch (_) {}
      }
      final playable =
          folder.where((x) => e.isVideo ? x.isVideo : x.isPlayable).toList();
      final i = playable.indexWhere((x) => x.path == e.path);
      final next = i >= 0 && i + 1 < playable.length ? playable[i + 1] : null;
      UpNext.register(
        url,
        next == null
            ? null
            : UpNextOffer(
                title: next.name,
                play: () async {
                  if (mounted) await _play(next, folder);
                }),
      );
      if (!mounted) return;
      UpNext.noteChosen();
      await context.push(Routes.player,
          extra: <String, dynamic>{'uri': url, 'title': e.name});
    } on NetFailure catch (f) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text(netErrorText(context, f, _server))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final folderName = _path == '/'
        ? _server.title
        : _path.substring(_path.lastIndexOf('/') + 1);
    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFF121212),
          foregroundColor: Colors.white,
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(folderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              Text(_server.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
          actions: <Widget>[
            IconButton(
              tooltip: s.netMediaOnly,
              icon: Icon(
                  _mediaOnly
                      ? Icons.video_library_rounded
                      : Icons.video_library_outlined,
                  color: _mediaOnly ? NetColors.action : Colors.white),
              onPressed: () => setState(() => _mediaOnly = !_mediaOnly),
            ),
            PopupMenuButton<_Sort>(
              icon: const Icon(Icons.sort_rounded, color: Colors.white),
              color: NetColors.dialog,
              initialValue: _sort,
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => <PopupMenuEntry<_Sort>>[
                for (final (v, label) in <(_Sort, String)>[
                  (_Sort.name, s.netSortName),
                  (_Sort.date, s.netSortDate),
                  (_Sort.size, s.netSortSize),
                ])
                  CheckedPopupMenuItem<_Sort>(
                    value: v,
                    checked: _sort == v,
                    child: Text(label,
                        style: const TextStyle(color: Colors.white)),
                  ),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(38),
            child: _PathBar(
              path: _path,
              rootLabel: _server.title,
              onTap: (p) => unawaited(_open(p)),
            ),
          ),
        ),
        body: _body(s),
      ),
    );
  }

  Widget _body(AppStrings s) {
    if (_loading && _entries == null) {
      return const Center(
          child: CircularProgressIndicator(color: NetColors.action));
    }
    if (_failure != null && (_entries == null || !_loading)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Icon(
              _failure!.code == 'unreachable' || _failure!.code == 'timeout'
                  ? Icons.wifi_off_rounded
                  : Icons.lock_outline_rounded,
              color: Colors.white38,
              size: 46,
            ),
            const SizedBox(height: 14),
            Text(netErrorText(context, _failure!, _server),
                key: const ValueKey('net-browse-error'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14.5, height: 1.5)),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: NetColors.fab),
              onPressed: () =>
                  unawaited(_open(_entries == null ? _home : _path)),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(s.netRetry),
            ),
          ]),
        ),
      );
    }
    final items = _sorted;
    return Stack(children: <Widget>[
      RefreshIndicator(
        color: NetColors.action,
        onRefresh: () => _open(_path),
        child: items.isEmpty
            ? ListView(children: <Widget>[
                const SizedBox(height: 120),
                const Icon(Icons.folder_open_rounded,
                    color: Colors.white24, size: 56),
                const SizedBox(height: 12),
                Text(s.netEmptyFolder,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 14)),
              ])
            : ListView.builder(
                controller: _scroll,
                itemCount: items.length,
                itemBuilder: (_, i) => _EntryTile(
                  entry: items[i],
                  share: _path == '/' && _server.protocol == NetProtocol.smb,
                  onTap: () => unawaited(_tap(items[i])),
                ),
              ),
      ),
      if (_loading)
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: LinearProgressIndicator(
              minHeight: 2,
              color: NetColors.action,
              backgroundColor: Colors.transparent),
        ),
    ]);
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar(
      {required this.path, required this.rootLabel, required this.onTap});
  final String path;
  final String rootLabel;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final segs = path.split('/').where((x) => x.isNotEmpty).toList();
    final crumbs = <(String, String)>[('/', rootLabel)];
    var acc = '';
    for (final x in segs) {
      acc = '$acc/$x';
      crumbs.add((acc, x));
    }
    // Left to right like any path, and scrolled so the folder you are in
    // is the part that shows when the path is longer than the screen.
    return SizedBox(
      height: 38,
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: c.maxWidth - 24),
            child: Row(
              children: <Widget>[
                for (var i = 0; i < crumbs.length; i++) ...<Widget>[
                  if (i > 0)
                    const Icon(Icons.chevron_right_rounded,
                        color: Colors.white30, size: 18),
                  _crumb(crumbs[i].$1, crumbs[i].$2, i == crumbs.length - 1),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _crumb(String p, String label, bool last) {
    return InkWell(
      onTap: last ? null : () => onTap(p),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          if (p == '/') ...<Widget>[
            Icon(Icons.dns_rounded,
                size: 14, color: last ? Colors.white : Colors.white54),
            const SizedBox(width: 5),
          ],
          Text(label,
              style: TextStyle(
                color: last ? Colors.white : Colors.white54,
                fontSize: 13,
                fontWeight: last ? FontWeight.w600 : FontWeight.w400,
              )),
        ]),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(
      {required this.entry, required this.share, required this.onTap});
  final NetEntry entry;
  final bool share;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final (IconData icon, Color color) = e.dir
        ? (share
            ? (Icons.folder_shared_rounded, const Color(0xFF5AA9F7))
            : (Icons.folder_rounded, const Color(0xFFF2C14E)))
        : e.isVideo
            ? (Icons.movie_rounded, const Color(0xFF66BB6A))
            : e.isAudio
                ? (Icons.music_note_rounded, const Color(0xFFBA68C8))
                : e.isSubtitle
                    ? (Icons.subtitles_rounded, const Color(0xFF90A4AE))
                    : (
                        Icons.insert_drive_file_rounded,
                        const Color(0xFF757575)
                      );
    final date = e.modified > 0
        ? _date(DateTime.fromMillisecondsSinceEpoch(e.modified))
        : '';
    final sub = e.dir
        ? date
        : <String>[netFmtBytes(e.size), if (date.isNotEmpty) date]
            .join('  ·  ');
    return ListTile(
      key: ValueKey('net-entry-${e.name}'),
      onTap: onTap,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: color, size: 26),
      ),
      title: Text(e.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: e.dir || e.isPlayable ? Colors.white : Colors.white60,
            fontSize: 14.5,
            fontWeight: e.dir ? FontWeight.w600 : FontWeight.w500,
          )),
      subtitle: sub.isEmpty
          ? null
          : Text(sub,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
      trailing: e.dir
          ? const Icon(Icons.chevron_right_rounded, color: Colors.white30)
          : (e.isPlayable
              ? const Icon(Icons.play_circle_outline_rounded,
                  color: Colors.white38)
              : null),
    );
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
