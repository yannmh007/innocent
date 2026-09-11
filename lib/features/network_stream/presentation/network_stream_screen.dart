import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Network stream screen — paste URL to play any media_kit-supported stream.
/// Supported: HTTP/HTTPS, RTSP, RTMP, HLS (.m3u8), DASH (.mpd), direct video files.
class NetworkStreamScreen extends ConsumerStatefulWidget {
  const NetworkStreamScreen({super.key});

  @override
  ConsumerState<NetworkStreamScreen> createState() =>
      _NetworkStreamScreenState();
}

class _NetworkStreamScreenState extends ConsumerState<NetworkStreamScreen> {
  static const String _kRecentKey = 'network_stream_recent_v1';
  static const int _maxRecent = 8;

  final TextEditingController _urlController = TextEditingController();
  List<String> _recent = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_kRecentKey) ?? [];
    if (mounted) {
      setState(() {
        _recent = list;
        _loading = false;
      });
    }
  }

  Future<void> _saveRecent(String url) async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_kRecentKey) ?? [];
    list.remove(url);
    list.insert(0, url);
    while (list.length > _maxRecent) {
      list.removeLast();
    }
    await sp.setStringList(_kRecentKey, list);
    if (mounted) setState(() => _recent = list);
  }

  Future<void> _clearRecent() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kRecentKey);
    if (mounted) setState(() => _recent = []);
  }

  bool _isValidUrl(String s) {
    final uri = Uri.tryParse(s);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return ['http', 'https', 'rtsp', 'rtmp', 'rtmps', 'mms', 'file']
        .contains(scheme);
  }

  void _play(String url) {
    if (!_isValidUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).invalidUrl)),
      );
      return;
    }
    _saveRecent(url);
    // Derive title from URL
    final title = url.split('/').lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => url,
        );
    context.push(
      Routes.player,
      extra: {'uri': url, 'title': title},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).networkStream)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(AppStrings.of(context).streamUrl,
                style: const TextStyle(
                  color: AppColors.darkOnSurface,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.url,
                autocorrect: false,
                onSubmitted: _play,
                decoration: InputDecoration(
                  hintText: 'https://example.com/stream.m3u8',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: AppColors.darkSurfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.link, color: Colors.white54),
                  suffixIcon: _urlController.text.isNotEmpty
                      ? IconButton(
                          tooltip: 'Clear',
                          icon:
                              const Icon(Icons.clear, color: Colors.white54),
                          onPressed: () {
                            _urlController.clear();
                            setState(() {});
                          },
                        )
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _urlController.text.trim().isEmpty
                    ? null
                    : () => _play(_urlController.text.trim()),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentBlue,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.darkSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.play_arrow),
                label: Text(AppStrings.of(context).play,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Supports: HTTP / HTTPS / RTSP / RTMP / HLS (.m3u8) / DASH (.mpd) / direct video files',
                style: TextStyle(
                  color: AppColors.darkOnSurfaceMuted,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 24),
              if (_recent.isNotEmpty) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(AppStrings.of(context).recent,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _clearRecent,
                      child: Text(AppStrings.of(context).clear,
                        style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                const Divider(height: 8, color: Colors.white12),
              ],
              if (_loading)
                const Expanded(
                    child: Center(child: CircularProgressIndicator()))
              else
                Expanded(
                  child: ListView.separated(
                    itemCount: _recent.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.history,
                        color: AppColors.darkOnSurfaceMuted,
                        size: 18,
                      ),
                      title: Text(
                        _recent[i],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        _urlController.text = _recent[i];
                        _play(_recent[i]);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
