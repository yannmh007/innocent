import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import 'library_provider.dart';

/// Search bar overlay AppBar — replaces normal AppBar when active
class SearchAppBar extends ConsumerStatefulWidget
    implements PreferredSizeWidget {
  final VoidCallback onClose;

  const SearchAppBar({super.key, required this.onClose});

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  ConsumerState<SearchAppBar> createState() => _SearchAppBarState();
}

class _SearchAppBarState extends ConsumerState<SearchAppBar> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  ProviderSubscription<String>? _querySub;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(searchQueryProvider));
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Dismissing search before the first frame disposes the FocusNode;
      // requesting focus on a disposed node throws.
      if (!mounted) return;
      _focusNode.requestFocus();
    });
    // Phase 30: Sync controller text when provider changes externally
    // (e.g. recent-search chip tapped).
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
        tooltip: 'Close',
        icon: const Icon(Icons.close),
        onPressed: () {
          ref.read(searchQueryProvider.notifier).state = '';
          widget.onClose();
        },
      ),
      title: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: const InputDecoration(
          hintText: 'Search media files',
          hintStyle: TextStyle(color: Colors.white38),
          border: InputBorder.none,
          icon: Icon(Icons.search, color: Colors.white54, size: 20),
        ),
        onChanged: (value) {
          ref.read(searchQueryProvider.notifier).state = value;
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
            tooltip: 'Clear',
            icon: const Icon(Icons.clear),
            onPressed: () {
              _controller.clear();
              ref.read(searchQueryProvider.notifier).state = '';
              setState(() {});
            },
          ),
      ],
    );
  }
}
