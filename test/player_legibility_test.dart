// Can the player's chrome be read over any film? The player plays whatever
// video it is given, so every word and icon must hold against a dark, a
// bright, a grey, a busy and a colourful frame (skill ui-design §4: at least
// 3:1 for an icon or control, 4.5:1 for text; colour is tested against the
// film, never against another app).
//
// How: the screen is drawn over each frame at the phone's own pixels (the
// owner's phone, 384x823 dp at 2.8125). For every word and icon (each a
// RenderParagraph: Material icons are glyphs) the same text is laid out
// again, opaque and without shadows, to find its glyphs' pixels; the ink is
// what the screen shows there, the background what it shows two to three
// pixels off the glyphs' edges (a shadow or a backing counts, as it does to
// the eye). The contrast is WCAG 2's, ink beside background; the 10th
// percentile over the ring is the figure. A word inside a panel's scroll
// fade is faint on purpose: measured, marked "fade", not judged.
//
// Not measured: what is painted rather than written (the seek bar, the
// play button's ring, the drag handle).
//
//   LEGIBILITY_OUT=<dir> flutter test test/player_legibility_test.dart
// writes one line per element to <dir>/legibility.tsv and a photograph of
// every case. Narrow with SCENES=controls,more FRAMES=white,busy; LANGS=my,en.
// Orientations: port (a wide film upright: the controls on its black bars),
// tall (an upright 9:16 film: the controls on the picture), land.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/models/audio_track_info.dart';
import 'package:innocent/core/services/video_player/models/subtitle_track_info.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

/// The owner's phone: 1080x2316 at 450 dpi (BACKLOG §0, 22 Nov), three
/// buttons, a punch hole.
const _owner =
    Phone('384x823', 384, 823.5, 2.8125, statusBar: 30, navBar: 48, cutout: 30);

class _Frame extends CustomPainter {
  const _Frame(this.kind);
  final String kind;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    switch (kind) {
      case 'black':
        canvas.drawRect(r, Paint()..color = const Color(0xFF000000));
      case 'white':
        canvas.drawRect(r, Paint()..color = const Color(0xFFFFFFFF));
      case 'grey':
        canvas.drawRect(r, Paint()..color = const Color(0xFF808080));
      case 'busy':
        // A fine black-and-white texture, as the measuring film's: the
        // worst case for anything drawn straight on the picture.
        final rnd = math.Random(7);
        canvas.drawRect(r, Paint()..color = const Color(0xFF000000));
        final white = Paint()..color = const Color(0xFFFFFFFF);
        const cell = 3.0;
        for (var y = 0.0; y < size.height; y += cell) {
          for (var x = 0.0; x < size.width; x += cell) {
            if (rnd.nextBool()) {
              canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), white);
            }
          }
        }
      case 'colour':
        const bars = <Color>[
          Color(0xFFFFFF00),
          Color(0xFF00FFFF),
          Color(0xFF00FF00),
          Color(0xFFFF00FF),
          Color(0xFFFF0000),
          Color(0xFF0000FF),
          Color(0xFFFF8800),
          Color(0xFFFFFFFF),
        ];
        final w = size.width / bars.length;
        for (var i = 0; i < bars.length; i++) {
          canvas.drawRect(Rect.fromLTWH(i * w, 0, w + 1, size.height),
              Paint()..color = bars[i]);
        }
    }
  }

  @override
  bool shouldRepaint(covariant _Frame old) => old.kind != kind;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _tapIcon(WidgetTester tester, IconData icon) async {
  final f = find.byIcon(icon);
  await tester.ensureVisible(f.first);
  await tester.pump();
  await tester.tap(f.first, warnIfMissed: false);
  await _settle(tester);
}

final _scenes = <String, Future<void> Function(WidgetTester, PlayerController)>{
  'controls': (t, c) async {},
  'more': (t, c) => _tapIcon(t, Icons.more_vert),
  'audio': (t, c) => _tapIcon(t, Icons.music_note),
  'subtitle': (t, c) async {
    c.openSubtitleMenu();
    await _settle(t);
  },
};

const _frames = ['black', 'white', 'grey', 'busy', 'colour'];

final List<double> _linTable = List<double>.generate(256, (c8) {
  final c = c8 / 255.0;
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
});

double _lin(int c8) => _linTable[c8];

double _lum(int r, int g, int b) =>
    0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b);

double _contrast(double a, double b) {
  final hi = math.max(a, b), lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

bool _isIcon(InlineSpan span) {
  String? family = span.style?.fontFamily;
  span.visitChildren((child) {
    family ??= child.style?.fontFamily;
    return family == null;
  });
  return family != null &&
      (family!.contains('MaterialIcons') || family!.contains('Icons'));
}

bool _hasPlaceholder(InlineSpan span) {
  var found = false;
  span.visitChildren((child) {
    if (child is PlaceholderSpan) found = true;
    return !found;
  });
  return found;
}

/// The same words, opaque and without shadows: where the glyphs are.
InlineSpan _bare(InlineSpan span) {
  if (span is! TextSpan) return span;
  final st = span.style ?? const TextStyle();
  final bare = st.foreground != null
      ? st.copyWith(
          foreground: Paint()..color = const Color(0xFFFFFFFF),
          shadows: const <Shadow>[])
      : st.copyWith(color: const Color(0xFFFFFFFF), shadows: const <Shadow>[]);
  return TextSpan(text: span.text, children: span.children, style: bare);
}

bool _near(bool Function(int, int) on, int x, int y) {
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      if (on(x + dx, y + dy)) return true;
    }
  }
  return false;
}

/// Inside a panel's scroll fade (player_ui.dart _FadingScroll: the top 7 %
/// and the bottom 12 % of the list fade out when there is more): faint on
/// purpose, so measured but not judged.
bool _underFade(RenderParagraph para, RenderObject boundary) {
  RenderObject? p = para.parent;
  while (p != null && p is! RenderShaderMask) {
    p = p.parent;
  }
  if (p is! RenderShaderMask || !p.hasSize) return false;
  final top = p.localToGlobal(Offset.zero, ancestor: boundary).dy;
  final c =
      para.localToGlobal(para.size.center(Offset.zero), ancestor: boundary).dy;
  return c < top + p.size.height * 0.07 || c > top + p.size.height * 0.88;
}

class _Element {
  _Element(
      this.kind, this.label, this.rect, this.p10, this.min, this.n, this.fade);
  final String kind;
  final String label;
  final Rect rect;
  final double p10;
  final double min;
  final int n;
  final bool fade;
}

/// For each word and icon: its glyphs' pixels as drawn, against the pixels
/// one to three pixels off their edges (where a shadow or a backing shows,
/// if there is one), on the screen as rendered.
Future<List<_Element>> _measure(
    WidgetTester tester, double dpr, String? shot) async {
  await tester.pump();
  final boundary = playerBoundary.currentContext!.findRenderObject()!
      as RenderRepaintBoundary;
  late Uint8List px;
  late int w, h;
  final paras = <RenderParagraph>{
    for (final o in tester.allRenderObjects)
      if (o is RenderParagraph && o.attached && o.hasSize && !o.size.isEmpty) o,
  }.toList();
  final masks = <RenderParagraph, (Uint8List, int, int, int, int)>{};
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage(pixelRatio: dpr);
    w = image.width;
    h = image.height;
    px = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    if (shot != null) {
      final small = await boundary.toImage(pixelRatio: 1.0);
      final png = await small.toByteData(format: ui.ImageByteFormat.png);
      File(shot)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    }
    for (final para in paras) {
      if (_hasPlaceholder(para.text)) continue;
      final o = para.localToGlobal(Offset.zero, ancestor: boundary) * dpr;
      final ox = o.dx.floor(), oy = o.dy.floor();
      // A word set smaller by a FittedBox (the decoder's label, Thai's
      // "ค่าเริ่มต้น") is drawn scaled: lay the copy out at that scale, or
      // it misses the glyphs (it read 1.0:1 over black).
      final t = para.getTransformTo(boundary);
      // The x axis's scale (getMaxScaleOnAxis counts z, always 1).
      final k = dpr *
          math.sqrt(t.entry(0, 0) * t.entry(0, 0) + t.entry(1, 0) * t.entry(1, 0));
      final mw = (para.size.width * k).ceil() + 2,
          mh = (para.size.height * k).ceil() + 2;
      if (mw <= 2 || mh <= 2 || mw * mh > 4000000) continue;
      final tp = TextPainter(
        text: _bare(para.text),
        textAlign: para.textAlign,
        textDirection: para.textDirection,
        textScaler: para.textScaler,
        maxLines: para.maxLines,
        ellipsis: para.overflow == TextOverflow.ellipsis ? '…' : null,
        locale: para.locale,
        strutStyle: para.strutStyle,
        textWidthBasis: para.textWidthBasis,
        textHeightBehavior: para.textHeightBehavior,
      )..layout(minWidth: para.size.width, maxWidth: para.size.width);
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec)
        ..translate(o.dx - ox, o.dy - oy)
        ..scale(k);
      tp.paint(canvas, Offset.zero);
      tp.dispose();
      final img = await rec.endRecording().toImage(mw, mh);
      final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      masks[para] = (bytes, mw, mh, ox, oy);
    }
  });
  double lumAt(int x, int y) {
    final i = (y * w + x) * 4;
    return _lum(px[i], px[i + 1], px[i + 2]);
  }

  final out = <_Element>[];
  for (final para in paras) {
    final m = masks[para];
    if (m == null) continue;
    final (bytes, mw, mh, ox, oy) = m;
    bool on(int x, int y) =>
        x >= 0 && y >= 0 && x < mw && y < mh && bytes[(y * mw + x) * 4 + 3] > 0;
    bool core(int x, int y) =>
        x >= 0 &&
        y >= 0 &&
        x < mw &&
        y < mh &&
        bytes[(y * mw + x) * 4 + 3] >= 200;
    bool onScreen(int x, int y) =>
        x + ox >= 0 && y + oy >= 0 && x + ox < w && y + oy < h;
    final cores = <int>[];
    for (var y = 0; y < mh; y++) {
      for (var x = 0; x < mw; x++) {
        if (core(x, y) && onScreen(x, y)) cores.add(y * mw + x);
      }
    }
    if (cores.isEmpty) continue;
    // The ring: off the glyph, 1-3 px from a core pixel.
    final ring = <int>{};
    for (final c in cores) {
      final cx = c % mw, cy = c ~/ mw;
      for (var dy = -3; dy <= 3; dy++) {
        for (var dx = -3; dx <= 3; dx++) {
          final x = cx + dx, y = cy + dy;
          // Two pixels off the glyph at least: the next one may be its own
          // antialiased edge, a sub-pixel off from this copy of it.
          if (onScreen(x, y) && x >= -3 && y >= -3 && !_near(on, x, y)) {
            ring.add((y + 4) * (mw + 8) + (x + 4));
          }
        }
      }
    }
    if (ring.isEmpty) continue;
    final coreSet = cores.toSet();
    final contrasts = <double>[];
    for (final r in ring) {
      final x = r % (mw + 8) - 4, y = r ~/ (mw + 8) - 4;
      // The ink beside it: the core pixels within 3 px, as drawn.
      var sum = 0.0, n = 0;
      for (var dy = -3; dy <= 3; dy++) {
        for (var dx = -3; dx <= 3; dx++) {
          final cx = x + dx, cy = y + dy;
          if (cx >= 0 &&
              cy >= 0 &&
              cx < mw &&
              cy < mh &&
              coreSet.contains(cy * mw + cx)) {
            sum += lumAt(cx + ox, cy + oy);
            n++;
          }
        }
      }
      if (n == 0) continue;
      contrasts.add(_contrast(sum / n, lumAt(x + ox, y + oy)));
    }
    if (contrasts.isEmpty) continue;
    contrasts.sort();
    final icon = _isIcon(para.text);
    final text = para.text.toPlainText();
    final label = icon
        ? 'icon U+${text.runes.isEmpty ? 0 : text.runes.first.toRadixString(16)}'
        : text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (label.isEmpty) continue;
    final rect =
        (para.localToGlobal(Offset.zero, ancestor: boundary)) & para.size;
    out.add(_Element(
        icon ? 'icon' : 'text',
        label,
        rect,
        contrasts[contrasts.length ~/ 10],
        contrasts.first,
        contrasts.length,
        _underFade(para, boundary)));
  }
  return out;
}

void main() {
  final outDir = Platform.environment['LEGIBILITY_OUT'];
  final onlyScenes = Platform.environment['SCENES']?.split(',').toSet();
  final onlyFrames = Platform.environment['FRAMES']?.split(',').toSet();
  final langs = (Platform.environment['LANGS'] ?? 'my').split(',');
  final rows = <String>[
    'scene\torient\tlang\tframe\tkind\tlabel\tx\ty\tw\th\tp10\tmin\tring\tneed\tpass'
  ];
  var realFonts = false;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    realFonts = await loadPlayerFonts();
  });

  tearDownAll(() {
    if (outDir == null) return;
    File('$outDir/legibility.tsv')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${rows.join('\n')}\n');
  });

  for (final scene in _scenes.entries) {
    if (onlyScenes != null && !onlyScenes.contains(scene.key)) continue;
    // port: a wide film upright (the controls sit on its black bars);
    // tall: an upright 9:16 film upright, the controls on the picture;
    // land: a wide film sideways, the controls on the picture.
    for (final o in ['port', 'tall', 'land']) {
      final landscape = o == 'land';
      for (final lang in langs) {
        for (final frame in _frames) {
          if (onlyFrames != null && !onlyFrames.contains(frame)) continue;
          testWidgets('${scene.key} $o $lang over $frame', (tester) async {
            // A measuring tool, not a gate: it runs when asked.
            if (outDir == null) {
              markTestSkipped('set LEGIBILITY_OUT=<dir> to measure');
              return;
            }
            if (!realFonts) {
              markTestSkipped('fonts not found (test/fonts, the SDK)');
              return;
            }
            final svc = FakePlayerService(
              frame: _Frame(frame),
              videoSize:
                  o == 'tall' ? const Size(1080, 1920) : const Size(1920, 1080),
              audioTracks: const [
                AudioTrackInfo(id: '1', title: 'Stereo', language: 'eng'),
                AudioTrackInfo(id: '2', title: 'Commentary', language: 'eng'),
              ],
              subtitleTracks: const [
                SubtitleTrackInfo(id: '1', language: 'mya', title: 'မြန်မာ'),
                SubtitleTrackInfo(id: '2', language: 'eng', title: 'English'),
              ],
            );
            await pumpPlayer(tester,
                phone: _owner, landscape: landscape, lang: lang, engine: svc);
            final c = playerContainer!.read(playerControllerProvider.notifier);
            await scene.value(tester, c);
            final shot = '$outDir/${scene.key}_${o}_${lang}_$frame.png';
            final els = await _measure(tester, _owner.dpr, shot);
            expect(els, isNotEmpty,
                reason: 'nothing written was found on the screen');
            for (final e in els) {
              final need = e.kind == 'icon' ? 3.0 : 4.5;
              rows.add([
                scene.key,
                o,
                lang,
                frame,
                e.kind,
                e.label.length > 40 ? e.label.substring(0, 40) : e.label,
                e.rect.left.round(),
                e.rect.top.round(),
                e.rect.width.round(),
                e.rect.height.round(),
                e.p10.toStringAsFixed(2),
                e.min.toStringAsFixed(2),
                e.n,
                need,
                e.fade ? 'fade' : (e.p10 >= need ? 'yes' : 'NO'),
              ].join('\t'));
            }
            await leavePlayer(tester);
          });
        }
      }
    }
  }
}
