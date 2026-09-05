import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/poster_cache.dart';
import '../../domain/video_content.dart';
import '../video_hub_provider.dart';

/// Renders artwork for a [MediaRef], whatever provider it points at.
///
/// The single place in the feature that knows how a picture becomes pixels.
/// Swapping in a caching image package later (or a signed-URL scheme, or a
/// resize proxy) is a change to THIS file and nothing else.
///
/// When there is no artwork, it draws a quiet tile rather than an empty box.
/// The first version stamped a large letter in the middle of every one, which
/// made a screen of placeholders look like a toy - the eye read a grid of
/// alphabet blocks instead of a grid of posters. The replacement is a muted
/// tonal gradient with a small, low-contrast glyph: it recedes, the titles
/// underneath do the identifying, and the moment real artwork arrives nothing
/// about the layout changes.
class PosterImage extends ConsumerStatefulWidget {
  final MediaRef mediaRef;

  /// Used to pick the placeholder tone, and as the semantic label.
  final String title;

  final BoxFit fit;

  /// Drawn faintly in the middle of a generated tile.
  final IconData glyph;

  const PosterImage({
    super.key,
    required this.mediaRef,
    required this.title,
    this.fit = BoxFit.cover,
    this.glyph = Icons.movie_outlined,
  });

  @override
  ConsumerState<PosterImage> createState() => _PosterImageState();
}

class _PosterImageState extends ConsumerState<PosterImage> {
  /// The cached file, once one is known. Null means "not cached (yet)".
  String? _cachedPath;

  /// Set when caching was tried and did not work - a dead cache directory, a
  /// full disk, a 404. The widget then draws straight from the network, which
  /// is exactly the behaviour that existed before the cache did.
  bool _cacheFailed = false;

  /// The URL the two flags above describe. A grid recycles its tiles, so this
  /// widget is handed a DIFFERENT poster without being rebuilt from scratch;
  /// without this the second title would draw the first title's artwork.
  String? _forUrl;

  @override
  void didUpdateWidget(covariant PosterImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaRef.locator != widget.mediaRef.locator) {
      _cachedPath = null;
      _cacheFailed = false;
      _forUrl = null;
    }
  }

  /// Points [_cachedPath] at the file for [url], fetching it if needed.
  ///
  /// Called from `build`, which is normally where futures should not start -
  /// but this one is guarded on [_forUrl], so it runs ONCE per URL rather than
  /// once per rebuild. That is the whole reason this is a State: the previous
  /// `FutureBuilder` created a new future on every rebuild and every poster on
  /// screen blinked back to its placeholder during a scroll.
  void _ensureCached(String url) {
    if (_forUrl == url) return;
    _forUrl = url;

    final ready = PosterCache.pathIfReady(url);
    if (ready != null) {
      _cachedPath = ready;
      return;
    }

    PosterCache.resolve(url).then((path) {
      if (!mounted || _forUrl != url) return;
      setState(() {
        _cachedPath = path;
        _cacheFailed = path == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final mediaRef = widget.mediaRef;
    // Fast path: nothing to resolve. No future, no rebuild, no network.
    if (mediaRef.isEmpty) return _placeholder();

    final repo = ref.watch(contentRepositoryProvider);

    // SYNCHRONOUS FIRST, ASYNC ONLY IF IT HAS TO BE.
    //
    // This used to be a bare `FutureBuilder` built inside `build`, which means
    // a NEW future on every rebuild — and a fresh future always begins in the
    // waiting state, so the placeholder was drawn for one frame every single
    // time. Scrolling a grid, changing a filter or flipping a category made
    // every poster on screen blink, which reads as a broken image loader
    // rather than a rebuild.
    //
    // The catalogue's artwork is a plain URL sitting in a row that has already
    // been fetched: resolving it is a string test, not a request. So ask
    // synchronously first and skip the future entirely when the answer is
    // already here. The async path stays for a repository that genuinely has
    // to look something up.
    final direct = repo.resolveImageUrlSync(mediaRef);
    if (direct != null) {
      return direct.isEmpty ? _placeholder() : _image(direct);
    }

    return FutureBuilder<String?>(
      future: repo.resolveImageUrl(mediaRef),
      builder: (context, snapshot) {
        final url = snapshot.data;
        if (url == null || url.isEmpty) return _placeholder();
        return _image(url);
      },
    );
  }

  Widget _image(String url) {
    _ensureCached(url);

    final path = _cachedPath;
    if (path != null) {
      // FileImage keys on the path, so Flutter's own image cache still holds
      // the DECODED bitmap - the disk is read once, not once per scroll.
      return Image.file(
        File(path),
        fit: widget.fit,
        semanticLabel: widget.title,
        frameBuilder: _frame,
        // A cached file that will not decode is a corrupt one. Drop it so the
        // next build re-fetches instead of failing forever.
        errorBuilder: (context, error, stack) {
          PosterCache.forget(url);
          return _placeholder();
        },
      );
    }

    // Not cached yet. Draw from the network only once caching has been TRIED
    // and failed - otherwise the same bytes would be downloaded twice, which
    // is the opposite of the point.
    if (!_cacheFailed) return _placeholder();

    return Image.network(
      url,
      fit: widget.fit,
      semanticLabel: widget.title,
      frameBuilder: _frame,
      errorBuilder: (context, error, stack) => _placeholder(),
    );
  }

  /// A half-drawn poster is worse than a placeholder that becomes one.
  Widget _frame(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSync,
  ) {
    if (wasSync || frame != null) return child;
    return _placeholder();
  }

  Widget _placeholder() {
    final base = _toneFor(_seedFor(widget.title));
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[base, _deepen(base)],
        ),
      ),
      child: Center(
        child: Icon(
          widget.glyph,
          size: 26,
          color: Colors.white.withOpacity(0.13),
        ),
      ),
    );
  }

  /// Stable per-title hash so the same entry always draws the same tile - a
  /// poster that changes colour between builds looks like a glitch.
  static int _seedFor(String s) {
    var h = 0;
    for (int i = 0; i < s.length; i++) {
      h = (h * 31 + s.codeUnitAt(i)) & 0x7fffffff;
    }
    return h;
  }

  /// Desaturated, dark tones. The earlier palette was mid-brightness and
  /// fairly saturated, so a grid of placeholders read as a colour swatch chart
  /// competing with the UI. These sit close to the page tone and let the text
  /// stay the brightest thing on screen.
  static Color _toneFor(int seed) {
    const palette = <Color>[
      Color(0xFF23303D),
      Color(0xFF2C2839),
      Color(0xFF1F3230),
      Color(0xFF382A2E),
      Color(0xFF26301F),
      Color(0xFF332C22),
      Color(0xFF212C3A),
      Color(0xFF2E2434),
    ];
    return palette[seed % palette.length];
  }

  static Color _deepen(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness * 0.55).clamp(0.0, 1.0)).toColor();
  }
}
