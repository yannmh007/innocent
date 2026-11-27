import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/localization/app_strings.dart';
import '../../data/online_subtitles.dart';
import 'player_toast.dart';
import 'player_ui.dart';

/// CC → Online (P5, 28 Nov 2026): subtitles found on OpenSubtitles.com and
/// loaded into the film without leaving the app. Searched by the film's name
/// (the file's, cleaned) and, for a file on the phone, by its hash — a
/// subtitle made for this very file comes first. A row tapped downloads it
/// as SubRip into the app's cache and loads it; the sheet then closes.
/// Built from player_ui (skill ui-design): the sheet's shade, its header,
/// rows and choice chips.
class OnlineSubtitlesSheet extends StatefulWidget {
  const OnlineSubtitlesSheet({
    super.key,
    required this.client,
    required this.filmName,
    required this.onLoad,
    this.file,
    this.cacheDir,
  });

  final OnlineSubtitles client;

  /// The film's name as the player shows it (a file's name, cleaned here).
  final String filmName;

  /// A file on the phone, for its hash; null for anything else.
  final File? file;

  /// Loads the downloaded file into the film.
  final Future<void> Function(String path) onLoad;

  /// Where downloads go (tests); else the app's cache.
  final Directory? cacheDir;

  static Future<void> show(
    BuildContext context, {
    required OnlineSubtitles client,
    required String filmName,
    required Future<void> Function(String path) onLoad,
    File? file,
  }) {
    return showPlayerSheet<void>(
      context,
      builder: (_) => OnlineSubtitlesSheet(
        client: client,
        filmName: filmName,
        onLoad: onLoad,
        file: file,
      ),
    );
  }

  @override
  State<OnlineSubtitlesSheet> createState() => _OnlineSubtitlesSheetState();
}

enum _Langs { myEn, en, all }

class _OnlineSubtitlesSheetState extends State<OnlineSubtitlesSheet> {
  late final TextEditingController _query =
      TextEditingController(text: cleanFilmName(widget.filmName));
  _Langs _langs = _Langs.myEn;
  List<OnlineSubtitle>? _rows;
  bool _busy = false;
  int? _loading;
  OnlineSubtitleFailure? _failure;
  String? _hash;
  bool _hashRead = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<String> get _languages => switch (_langs) {
        _Langs.myEn => const <String>['my', 'en'],
        _Langs.en => const <String>['en'],
        _Langs.all => const <String>[],
      };

  Future<void> _search() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      if (!_hashRead) {
        _hashRead = true;
        final f = widget.file;
        if (f != null) _hash = await movieHash(f);
      }
      final rows = await widget.client.search(
        query: _query.text,
        moviehash: _hash,
        languages: _languages,
      );
      if (!mounted) return;
      setState(() => _rows = rows);
    } on OnlineSubtitleError catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = e.why;
        _rows = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _take(OnlineSubtitle s) async {
    if (_loading != null) return;
    setState(() {
      _loading = s.fileId;
      _failure = null;
    });
    try {
      final dir = widget.cacheDir ??
          Directory('${(await getTemporaryDirectory()).path}/online_subtitles');
      final f = await widget.client.download(s, dir);
      await widget.onLoad(f.path);
      if (!mounted) return;
      PlayerToastController.current?.show(AppStrings.of(context).osLoaded,
          kind: PlayerToastKind.success, icon: Icons.subtitles_outlined);
      Navigator.of(context).pop();
    } on OnlineSubtitleError catch (e) {
      if (mounted) setState(() => _failure = e.why);
    } catch (_) {
      if (mounted) setState(() => _failure = OnlineSubtitleFailure.unavailable);
    } finally {
      if (mounted) setState(() => _loading = null);
    }
  }

  String _failureText(AppStrings s, OnlineSubtitleFailure f) => switch (f) {
        OnlineSubtitleFailure.offline => s.osOffline,
        OnlineSubtitleFailure.busy => s.osBusy,
        OnlineSubtitleFailure.dayUsedUp => s.osDayUsedUp,
        OnlineSubtitleFailure.notReady => s.osNotReady,
        OnlineSubtitleFailure.unavailable => s.osFailed,
      };

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final pad = PlayerUi.pad(context);
    final rows = _rows;
    final failure = _failure;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerSheetHeader(title: s.osTitle),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, 4),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => unawaited(_search()),
                style: PlayerUi.rowTitle,
                cursorColor: PlayerUi.accent,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: s.osSearchHint,
                  hintStyle: PlayerUi.rowTitle.copyWith(color: PlayerUi.textDisabled),
                  filled: true,
                  fillColor: PlayerUi.raised,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: s.osSearch,
              onPressed: _busy ? null : () => unawaited(_search()),
              icon: const Icon(Icons.search, color: PlayerUi.textPrimary),
            ),
          ]),
        ),
        // One row: the results are what the sheet is for, and sideways it
        // has ~380 dp (three chips stacked left room for two rows).
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad - 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final l in _Langs.values)
              Expanded(child: PanelChoiceChip(
                label: switch (l) {
                  _Langs.myEn => s.osLangMyEn,
                  _Langs.en => s.osLangEn,
                  _Langs.all => s.osLangAll,
                },
                selected: _langs == l,
                onTap: () {
                  if (_langs == l) return;
                  setState(() => _langs = l);
                  unawaited(_search());
                },
              )),
          ]),
        ),
        if (_busy || failure != null || (rows != null && rows.isEmpty))
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 12, pad, 8),
            child: Text(
              _busy
                  ? s.osSearching
                  : failure != null
                      ? _failureText(s, failure)
                      : s.osNone,
              style: PlayerUi.body,
            ),
          ),
        if (rows != null && rows.isNotEmpty)
          Flexible(
            child: PlayerUi.ownLayer(ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.symmetric(horizontal: pad - 12),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final r = rows[i];
                return PanelRow(
                  icon: _loading == r.fileId
                      ? Icons.downloading
                      : r.hashMatch
                          ? Icons.verified_outlined
                          : Icons.subtitles_outlined,
                  title: r.label,
                  value: '${r.lang.toUpperCase()} · ${_count(r.downloads)}',
                  onTap: () => unawaited(_take(r)),
                );
              },
            )),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 8, pad, 16),
          child: Text(s.osCredit,
              style: PlayerUi.rowValue.copyWith(
                  fontSize: 11, color: PlayerUi.textSecondary)),
        ),
      ],
    );
  }
}

/// 1234 → "1.2k", for a row's download count.
String _count(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

/// A film's name for a search: the file's name without its extension,
/// dots and underscores as spaces, and nothing from the first release tag
/// on (a year is kept: it tells two films apart).
String cleanFilmName(String name) {
  var s = name.trim();
  s = s.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
  s = s.replaceAll(RegExp(r'[._]+'), ' ');
  s = s.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*(?:rip|web|x26|hevc|1080|720|480)[^)]*\)',
      caseSensitive: false), ' ');
  final tag = RegExp(
      r'\b(2160p|1080p|720p|480p|360p|4k|web-?dl|webrip|bluray|brrip|bdrip|'
      r'dvdrip|hdtv|hdrip|x264|x265|h ?264|h ?265|hevc|aac|ac3|ddp?5 ?1|'
      r'yify|yts|rarbg|proper|repack|extended|unrated)\b',
      caseSensitive: false);
  final m = tag.firstMatch(s);
  if (m != null) s = s.substring(0, m.start);
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
