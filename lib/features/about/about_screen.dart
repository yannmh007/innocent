import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_version.dart';
import '../../core/localization/app_strings.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/innocent_logo.dart';
import '../../core/ui/tablet_constrained_width.dart';
import '../me/presentation/help_screen.dart';
import '../updater/data/update_check_service.dart';
import '../updater/domain/app_release.dart';
import '../updater/presentation/app_update_screen.dart';
import '../../core/theme/tab_title.dart';

/// Me → About.
///
/// WHAT THE GOOD ONES DO (Telegram, WhatsApp "App info", Spotify, YouTube,
/// Netflix, iOS Settings › About, studied 2026-10-06): the mark, the name,
/// the version — copyable, because it is what support asks for first — then
/// a few grouped rows, every one of which DOES something: is there an update,
/// what changed, where to get help, the legal text. Nothing else. None of
/// them lists its features (the app is the feature list) or its technology.
///
/// So the old page's FEATURES and TECHNOLOGY sections are gone. They aged
/// (it named "Flutter 3.22+"), read like a school project, and told anyone
/// curious which engine and player library to go looking for exploits in.
///
/// And it names no person or place: Innocent's owner is not on this page.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.checkService = const UpdateCheckService()});

  /// Injectable so tests and the screen harness never reach the network.
  final UpdateCheckService checkService;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

enum _UpdateState { checking, upToDate, available, unknown }

class _AboutScreenState extends State<AboutScreen> {
  _UpdateState _update = _UpdateState.checking;
  AppRelease? _latest;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  /// One quiet look at the release row, so the update line can say "Up to
  /// date" or name the new version instead of only "check". A failure says
  /// nothing alarming — the row still opens the full update screen.
  Future<void> _check() async {
    try {
      final r = await widget.checkService.fetchLatest();
      if (!mounted) return;
      setState(() {
        _latest = r;
        _update = r != null && r.versionCode > AppVersion.build
            ? _UpdateState.available
            : _UpdateState.upToDate;
      });
    } catch (_) {
      if (mounted) setState(() => _update = _UpdateState.unknown);
    }
  }

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  Future<void> _copyVersion() async {
    final s = AppStrings.of(context);
    await Clipboard.setData(ClipboardData(
        text: '${AppVersion.displayName} ${AppVersion.full}'));
    if (!mounted) return;
    unawaited(HapticFeedback.selectionClick());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(s.aboutCopied),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  /// The notes of the release this phone is running, when the server has
  /// them — App Store's "What's New", for a version already installed.
  String? _notesForThisVersion(BuildContext context) {
    final r = _latest;
    if (r == null || r.versionCode != AppVersion.build) return null;
    final burmese = Localizations.localeOf(context).languageCode == 'my';
    final notes = (burmese ? r.notesMm : r.notesEn) ?? r.notesEn ?? r.notesMm;
    return (notes == null || notes.trim().isEmpty) ? null : notes.trim();
  }

  void _showWhatsNew(String notes) {
    final s = AppStrings.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _About.sheet,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.aboutWhatsNewIn(AppVersion.name),
                    style: _About.sheetTitle),
                const SizedBox(height: 14),
                Text(notes, style: _About.body(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final notes = _notesForThisVersion(context);
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        title: Text(s.about,
            style: kAppBarTitleStyle.copyWith(color: Colors.white)),
      ),
      body: TabletConstrainedWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: <Widget>[
            _Hero(onCopy: _copyVersion),
            const SizedBox(height: 28),
            _Group(
              label: s.aboutSectionApp,
              children: <Widget>[
                _Row(
                  icon: Icons.system_update_alt_rounded,
                  tint: AppColors.accentBlue,
                  title: s.aboutSoftwareUpdate,
                  subtitle: _UpdateStatus(state: _update),
                  trailing: _update == _UpdateState.available
                      ? _UpdateBadge(version: _latest?.versionName ?? '')
                      : null,
                  onTap: () => _open(const AppUpdateScreen()),
                ),
                if (notes != null)
                  _Row(
                    icon: Icons.auto_awesome_rounded,
                    tint: const Color(0xFFFFB020),
                    title: s.aboutWhatsNew,
                    onTap: () => _showWhatsNew(notes),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            _Group(
              label: s.aboutSectionSupport,
              children: <Widget>[
                _Row(
                  icon: Icons.help_outline_rounded,
                  tint: const Color(0xFF34C759),
                  title: s.aboutHelpFaq,
                  onTap: () => _open(const HelpScreen()),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _Group(
              label: s.legal,
              children: <Widget>[
                _Row(
                  icon: Icons.article_outlined,
                  tint: const Color(0xFF8E8E93),
                  title: s.openSourceLicenses,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: AppVersion.displayName,
                    applicationVersion: AppVersion.full,
                    applicationIcon: const Padding(
                      padding: EdgeInsets.all(12),
                      child: InnocentLogo(size: 56),
                    ),
                    applicationLegalese: s.aboutRights,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 36),
            _Footer(text: s.aboutRights),
          ],
        ),
      ),
    );
  }
}

// ─── the look ───────────────────────────────────────────────────────────────

/// Every size and colour on the page, in one place.
///
/// Burmese gets more line height and no letter spacing: its stacked vowels
/// and medials clip at Latin line heights, and tracking pulls a syllable's
/// parts apart.
abstract final class _About {
  static const Color card = Color(0xFF161616);
  static const Color hairline = Color(0x14FFFFFF);
  static const Color sheet = Color(0xFF1A1A1A);
  static const Color muted = Color(0xFF9A9A9F);
  static const Color faint = Color(0xFF6C6C70);

  static bool burmese(BuildContext c) =>
      Localizations.localeOf(c).languageCode == 'my';

  static const TextStyle name = TextStyle(
    color: Colors.white,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    height: 1.15,
  );

  static TextStyle tagline(BuildContext c) => TextStyle(
        color: muted,
        fontSize: 14.5,
        height: burmese(c) ? 1.65 : 1.4,
      );

  static TextStyle groupLabel(BuildContext c) => TextStyle(
        color: muted,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        letterSpacing: burmese(c) ? 0 : 0.6,
        height: burmese(c) ? 1.6 : 1.2,
      );

  static TextStyle rowTitle(BuildContext c) => TextStyle(
        color: Colors.white,
        fontSize: 15.5,
        fontWeight: FontWeight.w500,
        height: burmese(c) ? 1.6 : 1.25,
      );

  static TextStyle rowValue(BuildContext c) => TextStyle(
        color: muted,
        fontSize: 13.5,
        height: burmese(c) ? 1.6 : 1.25,
      );

  static const TextStyle sheetTitle = TextStyle(
    color: Colors.white,
    fontSize: 19,
    fontWeight: FontWeight.w700,
    height: 1.4,
  );

  static TextStyle body(BuildContext c) => TextStyle(
        color: const Color(0xFFD6D6DA),
        fontSize: 14.5,
        height: burmese(c) ? 1.75 : 1.5,
      );
}

// ─── pieces ─────────────────────────────────────────────────────────────────

/// The mark on a faint wash of its own red, the name, one line of what it is
/// for, and the version as a pill that copies itself — Telegram and WhatsApp
/// both let the version be copied, because "which version?" is the first
/// question every bug report gets.
class _Hero extends StatelessWidget {
  const _Hero({required this.onCopy});

  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 26),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _About.hairline),
        gradient: const RadialGradient(
          center: Alignment(0, -1.1),
          radius: 1.25,
          colors: <Color>[Color(0x24F00000), Color(0x00F00000)],
        ),
        color: _About.card,
      ),
      child: Column(
        children: <Widget>[
          Container(
            width: 104,
            height: 104,
            decoration: BoxDecoration(
              color: const Color(0xFF0B0B0B),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: const Color(0x1FFFFFFF)),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 24,
                    offset: Offset(0, 10)),
              ],
            ),
            alignment: Alignment.center,
            child: const InnocentLogo(size: 76),
          ),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: const Text(AppVersion.displayName, style: _About.name),
          ),
          const SizedBox(height: 8),
          Text(
            s.aboutTagline,
            textAlign: TextAlign.center,
            style: _About.tagline(context),
          ),
          const SizedBox(height: 18),
          Semantics(
            button: true,
            label: '${s.aboutVersionFull(AppVersion.name, '${AppVersion.build}')}. '
                '${s.aboutCopyHint}',
            excludeSemantics: true,
            child: Material(
              color: const Color(0x14FFFFFF),
              shape: const StadiumBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onCopy,
                onLongPress: onCopy,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        s.aboutVersionFull(
                            AppVersion.name, '${AppVersion.build}'),
                        style: const TextStyle(
                          color: Color(0xFFE5E5EA),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          fontFeatures: <FontFeature>[
                            FontFeature.tabularFigures()
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.copy_rounded,
                          size: 14, color: _About.muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled card of rows, iOS-Settings style: the label outside the card,
/// hairline rules between rows that start after the icon.
class _Group extends StatelessWidget {
  const _Group({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Padding(
          padding: EdgeInsets.only(left: 64),
          child: Divider(height: 1, thickness: 1, color: _About.hairline),
        ));
      }
      rows.add(children[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
          child: Semantics(
            header: true,
            child: Text(label, style: _About.groupLabel(context)),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: _About.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _About.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: rows),
        ),
      ],
    );
  }
}

/// One row: a tinted icon tile, the title, an optional value, a chevron.
class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.tint,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final Color tint;
  final String title;

  /// A status line under the title. Under, not beside: a Burmese status
  /// beside a Burmese title has no room on a 360 dp phone and was cut off.
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 58),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tint.withAlpha(0x2E),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 19, color: tint),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(title, style: _About.rowTitle(context)),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: 2),
                      subtitle!,
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: 8),
                Flexible(child: trailing!),
              ],
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded,
                  size: 22, color: _About.faint),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line under "Software update": a small spinner while it asks, "Up to
/// date" with a tick, "Version 9.9.9 is ready" — or nothing when it could not
/// ask (the row still opens the update screen, which says why).
class _UpdateStatus extends StatelessWidget {
  const _UpdateStatus({required this.state});

  final _UpdateState state;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    switch (state) {
      case _UpdateState.checking:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                  strokeWidth: 1.6, color: _About.muted),
            ),
            const SizedBox(width: 8),
            Flexible(
                child: Text(s.updateChecking, style: _About.rowValue(context))),
          ],
        );
      case _UpdateState.upToDate:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.check_circle_rounded,
                size: 14, color: Color(0xFF34C759)),
            const SizedBox(width: 6),
            Flexible(
                child: Text(s.aboutUpToDate, style: _About.rowValue(context))),
          ],
        );
      case _UpdateState.available:
        return Text(s.aboutUpdateReady,
            style: _About.rowValue(context)
                .copyWith(color: AppColors.accentBlueLight));
      case _UpdateState.unknown:
        return const SizedBox.shrink();
    }
  }
}

/// The new version's number, as the badge iOS puts on Software Update.
class _UpdateBadge extends StatelessWidget {
  const _UpdateBadge({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accentBlue,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        version,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
            color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const Opacity(opacity: 0.55, child: InnocentLogo(size: 22)),
        const SizedBox(height: 10),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _About.faint,
            fontSize: 12,
            height: _About.burmese(context) ? 1.7 : 1.4,
          ),
        ),
      ],
    );
  }
}
