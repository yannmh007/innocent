import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import 'library_provider.dart';
import '../../../core/localization/app_strings.dart';

/// Search bar overlay AppBar — replaces normal AppBar when active
///
/// The Video tab's search writes [searchQueryProvider], which its folder
/// list (and a folder it found) follow. A screen's OWN search — a folder's
/// videos — passes [onQuery] and keeps its text to itself: through the
/// shared query it filtered the folder list behind it too, and Back out of
/// the folder left that list filtered with no search bar in sight (12 Nov).
class SearchAppBar extends ConsumerStatefulWidget
    implements PreferredSizeWidget {
  final VoidCallback onClose;

  /// The screen's own search: the text goes here, not to the Video tab's
  /// [searchQueryProvider].
  final ValueChanged<String>? onQuery;

  const SearchAppBar({super.key, required this.onClose, this.onQuery});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  ConsumerState<SearchAppBar> createState() => _SearchAppBarState();
}

class _SearchAppBarState extends ConsumerState<SearchAppBar> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  ProviderSubscription<String>? _querySub;

  bool get _own => widget.onQuery != null;

  void _set(String value) {
    final own = widget.onQuery;
    if (own != null) {
      own(value);
    } else {
      ref.read(searchQueryProvider.notifier).state = value;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: _own ? '' : ref.read(searchQueryProvider));
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Dismissing search before the first frame disposes the FocusNode;
      // requesting focus on a disposed node throws.
      if (!mounted) return;
      _focusNode.requestFocus();
    });
    // Phase 30: Sync controller text when provider changes externally
    // (e.g. recent-search chip tapped).
    if (_own) return;
    _querySub = ref.listenManual<String>(
      searchQueryProvider,
      (_, next) {
        if (_controller.text != next) {
          _controller.value = TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: next.length),
          );
        }
      },
    );
  }

  @override
  void dispose() {
    _querySub?.close();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.darkBackground,
      leading: IconButton(
        tooltip: AppStrings.of(context).close,
        icon: const Icon(Icons.close),
        onPressed: () {
          _set('');
          widget.onClose();
        },
      ),
      title: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          hintText: AppStrings.of(context).sabHint,
          hintStyle: TextStyle(color: Colors.white54),
          border: InputBorder.none,
          icon: Icon(Icons.search, color: Colors.white54, size: 20),
        ),
        onChanged: (value) {
          _set(value);
          // The ✕ that clears the text comes and goes with it.
          if (_own) setState(() {});
        },
        onSubmitted: (value) {
          // Phase 12: save to search history when user submits
          if (value.trim().isNotEmpty) {
            ref.read(searchHistoryProvider.notifier).add(value);
          }
        },
      ),
      actions: [
        if (_controller.text.isNotEmpty)
          IconButton(
            tooltip: AppStrings.of(context).sabClear,
            icon: const Icon(Icons.clear),
            onPressed: () {
              _controller.clear();
              _set('');
              setState(() {});
            },
          ),
      ],
    );
  }
}
