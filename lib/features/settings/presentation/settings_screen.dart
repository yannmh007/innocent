import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/list_detail.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import 'settings_audio_screen.dart';
import 'settings_decoder_screen.dart';
import 'settings_development_screen.dart';
import 'settings_diagnostics_screen.dart';
import 'settings_general_screen.dart';
import 'settings_language_screen.dart';
import 'settings_list_screen.dart';
import 'settings_player_screen.dart';
import 'settings_subtitle_screen.dart';
import '../../updater/presentation/app_update_screen.dart';
import '../../me/presentation/app_theme_screen.dart';
import '../../me/presentation/custom_popup_play_screen.dart';

/// Settings screen matching MX Player (UI PDF page 14)
/// 8 items with specific icons matching the real app exactly
///
/// On a window 840 dp wide or more, the list and the open page side by side
/// (core/ui/list_detail.dart): the list keeps its row marked, the page opens
/// in the right pane, and a page opened from it opens there too. A phone is
/// never that wide, and keeps the list and a page pushed over it.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _selectedIndex = -1;

  /// Two panes: the open page is one the person chose, not the first page
  /// shown by default — the page to keep when the window narrows to one pane.
  bool _picked = false;

  /// One pane or two at the last build, to see the window cross the line.
  bool? _wasTwoPanes;

  /// The right pane; a new key is a new pane (a fresh navigator).
  GlobalKey<DetailNavigatorState> _detailKey = GlobalKey();

  /// Two panes: focus is on the page (by D-pad or keyboard), and the open
  /// row to send it back to — Back steps out of the page before Settings.
  bool _pageFocused = false;
  final FocusNode _openRow = FocusNode(debugLabel: 'settings open row');

  void _keysOrTouch(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_keysOrTouch);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_keysOrTouch);
    _openRow.dispose();
    super.dispose();
  }

  void _open(int index, Widget screen) {
    setState(() => _selectedIndex = index);
    // Code-quality audit: was .then() without onError or mounted
    // check. The push future completes when the user returns to this
    // screen; if they navigated away in the meantime calling setState
    // on a disposed State would throw. Guard both paths.
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)).then(
        (_) {
      if (!mounted) return;
      // Back from a page opened over the list. If the window has widened
      // meanwhile, that page stays marked and opens beside the list.
      if (ListDetail.twoPanes(context)) {
        setState(() {
          _picked = true;
          _detailKey = GlobalKey();
        });
      } else {
        setState(() => _selectedIndex = -1);
      }
    }, onError: (e) {
      if (kDebugMode) debugPrint('Settings nav push failed: $e');
    });
  }

  /// Two panes: a row tapped opens its page in the right pane; the open
  /// page's row tapped again takes the pane back to that page's top (out of
  /// Player → Controls, say).
  void _select(int index) {
    if (index == _selectedIndex) {
      _detailKey.currentState?.popToRoot();
      return;
    }
    setState(() {
      _selectedIndex = index;
      _picked = true;
      _detailKey = GlobalKey();
    });
  }

  /// A window narrowed from two panes to one (a foldable folded, a window
  /// made smaller) keeps the page the person had open: it opens over the
  /// list as it would on a phone. A page opened inside it does not come
  /// along; the dialog or page over Settings, if any, is left alone.
  void _followWindow(bool two, List<Widget> screens) {
    final was = _wasTwoPanes;
    _wasTwoPanes = two;
    if (was != true || two || !_picked || _selectedIndex < 0) return;
    _picked = false;
    final index = _selectedIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ListDetail.twoPanes(context)) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
      _open(index, screens[index]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final items = <_SettingsEntry>[
      // App theme and Pop-up play were rows of their own on Me; they are
      // settings, so they live with the rest of them now.
      _SettingsEntry(Icons.palette_outlined, s.appTheme),
      _SettingsEntry(Icons.list_alt, s.settingsList),
      _SettingsEntry(Icons.hexagon_outlined, s.settingsPlayer),
      _SettingsEntry(Icons.picture_in_picture_alt_outlined, s.popupPlay),
      // Phase 30: Decoder uses chip/memory icon (verified against MX recording)
      _SettingsEntry(Icons.memory, s.settingsDecoder),
      // Phase 30: Audio uses music-note-in-square icon
      _SettingsEntry(Icons.audiotrack, s.settingsAudio),
      _SettingsEntry(Icons.subtitles_outlined, s.settingsSubtitle),
      _SettingsEntry(Icons.error_outline, s.settingsGeneral),
      _SettingsEntry(Icons.data_object, s.settingsDevelopment),
      // v1.61. Not localised on purpose: every line it shows is a raw Android
      // record in English, so three translations of the label around it would
      // be decoration. See SettingsDiagnosticsScreen.
      const _SettingsEntry(Icons.bug_report_outlined, 'Diagnostics'),
      // Phase 30: App Language uses translate icon (the "A" with arrow)
      _SettingsEntry(Icons.translate, s.settingsAppLanguage),
      // updater_plan.md step 2. NEVER HIDDEN, even when up to date - this is
      // where someone goes after dismissing a prompt, and the only place they
      // can confirm the app is not stale.
      _SettingsEntry(Icons.system_update, s.settingsAppUpdate),
    ];

    final screens = <Widget>[
      const AppThemeScreen(),
      const SettingsListScreen(),
      const SettingsPlayerScreen(),
      const CustomPopupPlayScreen(),
      const SettingsDecoderScreen(),
      const SettingsAudioScreen(),
      const SettingsSubtitleScreen(),
      const SettingsGeneralScreen(),
      const SettingsDevelopmentScreen(),
      const SettingsDiagnosticsScreen(),
      const SettingsLanguageScreen(),
      const AppUpdateScreen(),
    ];

    final two = ListDetail.twoPanes(context);
    _followWindow(two, screens);
    if (two) return _twoPanes(s, items, screens);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(s.settings)),
      // Phase 45 (audit): cap content width on tablets/foldables so
      // the list doesn't sprawl edge-to-edge. No-op on phones.
      body: TabletConstrainedWidth(
        child: ListView.builder(
          itemCount: items.length,
          itemBuilder: (_, i) {
            final item = items[i];
            final isSelected = _selectedIndex == i;
            return InkWell(
              key: ValueKey(item.title),
              onTap: () => _open(i, screens[i]),
              child: Container(
                color: isSelected
                    ? AppColors.primaryBlue.withValues(alpha: 0.12)
                    : Colors.transparent,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                child: Row(
                  children: [
                    Icon(
                      item.icon,
                      color: AppColors.primaryBlue,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          color: isSelected
                              ? AppColors.primaryBlue
                              : Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The list and the open page side by side. The list's rows are the
  /// phone's, with the open page's row marked as ui-design marks a selected
  /// row; the page is the one a phone opens, in the right pane's own
  /// navigator, with no back arrow (Back leaves Settings, from either pane).
  Widget _twoPanes(
      AppStrings s, List<_SettingsEntry> items, List<Widget> screens) {
    final selected = _selectedIndex < 0 ? 0 : _selectedIndex;
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: ListDetailPanes(
        onDetailFocus: (focused) => setState(() => _pageFocused = focused),
        list: Scaffold(
          backgroundColor: AppColors.darkBackground,
          appBar: AppBar(title: Text(s.settings)),
          body: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: items.length,
            itemBuilder: (_, i) => _PaneRow(
              key: ValueKey(items[i].title),
              entry: items[i],
              selected: i == selected,
              focusNode: i == selected ? _openRow : null,
              onTap: () => _select(i),
            ),
          ),
        ),
        detail: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeOut,
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [...previous, if (current != null) current],
          ),
          child: DetailNavigator(
            key: _detailKey,
            page: screens[selected],
            backToList: _pageFocused && ListDetail.usingKeys
                ? _openRow.requestFocus
                : null,
          ),
        ),
      ),
    );
  }
}

/// A row of the list pane: the phone row's icon and title, the selected one
/// on the accent's tint, inset and rounded, its icon and title in the accent.
class _PaneRow extends StatelessWidget {
  const _PaneRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    this.focusNode,
  });

  final _SettingsEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Semantics(
        selected: selected,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            focusNode: focusNode,
            borderRadius: BorderRadius.circular(14),
            child: Ink(
              decoration:
                  selected ? listDetailSelection(AppColors.primaryBlue) : null,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
              child: Row(
                children: [
                  Icon(entry.icon, color: AppColors.primaryBlue, size: 22),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      entry.title,
                      style: TextStyle(
                        color: selected ? AppColors.primaryBlue : Colors.white,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsEntry {
  final IconData icon;
  final String title;
  const _SettingsEntry(this.icon, this.title);
}
