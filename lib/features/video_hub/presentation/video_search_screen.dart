import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../domain/video_content.dart';
import 'content_detail_screen.dart';
import 'video_hub_provider.dart';
import 'widgets/hub_states.dart';
import 'widgets/poster_card.dart';
import 'widgets/vh_insets.dart';
import 'video_hub_theme.dart';
import 'account_provider.dart';

/// Search across the WHOLE catalogue — every category the user is allowed to
/// see, not just the one that happened to be selected.
///
/// That scope is the point. A search box that silently only looks inside the
/// current tab is the most common way a catalogue "loses" content: the user
/// types a title that exists, gets nothing, and concludes it is not there.
class VideoSearchScreen extends ConsumerStatefulWidget {
  const VideoSearchScreen({super.key});

  @override
  ConsumerState<VideoSearchScreen> createState() => _VideoSearchScreenState();
}

class _VideoSearchScreenState extends ConsumerState<VideoSearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  /// Long enough that a fast typist issues one query instead of eight, short
  /// enough that results feel live.
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    // Raise the keyboard on arrival: the user tapped a search field to get
    // here, so making them tap a second one is a wasted step.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      ref.read(videoSearchQueryProvider.notifier).state = value;
    });
    // Rebuild for the clear button only — the query itself is debounced.
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    ref.read(videoSearchQueryProvider.notifier).state = '';
    setState(() {});
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final query = ref.watch(videoSearchQueryProvider);
    final resultsAsync = ref.watch(videoSearchResultsProvider);

    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          style: VH.label.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: s.vhSearchHint,
            hintStyle: VH.label.copyWith(
              color: VH.textTertiary,
              fontSize: 15,
              fontWeight: FontWeight.w400,
            ),
            border: InputBorder.none,
            isDense: true,
          ),
        ),
        actions: <Widget>[
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close_rounded,
                  color: VH.textSecondary),
              onPressed: _clear,
            ),
        ],
      ),
      body: _buildBody(context, s, query, resultsAsync),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppStrings s,
    String query,
    AsyncValue<List<VideoContent>> resultsAsync,
  ) {
    if (query.trim().isEmpty) {
      return HubEmptyState(
        message: s.vhSearchPrompt,
        icon: Icons.search,
      );
    }

    return resultsAsync.when(
      loading: () => const PosterSkeletonGrid(count: 9),
      error: (error, _) => HubErrorState(
        detail: error.toString(),
        onRetry: () => ref.invalidate(videoSearchResultsProvider),
      ),
      data: (results) {
        if (results.isEmpty) {
          return HubEmptyState(
            message: s.vhSearchNoResults,
            icon: Icons.search_off,
          );
        }
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
              14, 12, 14, VhInsets.scrollBottom(context)),
          keyboardDismissBehavior:
              ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: results.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 10,
            mainAxisSpacing: 14,
            childAspectRatio: 0.56,
          ),
          itemBuilder: (context, index) {
            final item = results[index];
            return PosterCard(
              content: item,
              premium: ref
                  .read(accessPolicyProvider)
                  .showsPremiumBadge(item, ref.read(viewerProvider).tier),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ContentDetailScreen(content: item),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
