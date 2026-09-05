import 'dart:io';

import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/private_folder/private_folder_service.dart';
import '../../../core/services/secure_screen/secure_screen_service.dart';
import 'vault_pin_flow.dart';
import '../../../core/theme/app_colors.dart';

/// The provider is defined in private_folder_screen.dart; re-declared as an
/// extern reference would be circular, so callers pass the service in.
///
/// Anti-theft settings: decoy PIN + intruder selfie + the break-in log.
/// Reached from the vault overflow menu (hidden in decoy mode).
class AntiTheftScreen extends ConsumerStatefulWidget {
  final PrivateFolderService service;
  const AntiTheftScreen({super.key, required this.service});

  @override
  ConsumerState<AntiTheftScreen> createState() => _AntiTheftScreenState();
}

class _AntiTheftScreenState extends ConsumerState<AntiTheftScreen> {
  PrivateFolderService get _svc => widget.service;

  bool _loading = true;
  bool _intruderOn = false;
  bool _hasDecoy = false;
  int _autoLockSeconds = 0;
  List<IntruderEvent> _log = const [];

  /// Offered grace periods, in seconds. Deliberately short: this is a vault,
  /// and every option here is a window in which an unlocked vault is sitting
  /// behind a Home press. Anything longer than five minutes would be
  /// offering the user a way to turn the protection off without saying so.
  static const List<int> _autoLockChoices = <int>[0, 30, 60, 300];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final on = await _svc.intruderCaptureEnabled();
    final decoy = await _svc.hasDecoyPin();
    final log = await _svc.loadIntruderLog();
    final grace = await _svc.autoLockSeconds();
    if (mounted) {
      setState(() {
        _intruderOn = on;
        _hasDecoy = decoy;
        _autoLockSeconds = grace;
        _log = log;
        _loading = false;
      });
    }
  }

  String _autoLockLabel(AppStrings s, int seconds) {
    if (seconds <= 0) return s.autoLockImmediately;
    if (seconds < 60) return s.autoLockAfterSeconds(seconds);
    return s.autoLockAfterMinutes(seconds ~/ 60);
  }

  Future<void> _pickAutoLock() async {
    final s = AppStrings.of(context);
    final chosen = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Text(s.autoLock,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(s.autoLockDesc,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.white55, fontSize: 12, height: 1.35)),
            ),
            const SizedBox(height: 10),
            for (final v in _autoLockChoices)
              ListTile(
                leading: Icon(
                  v == _autoLockSeconds
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: v == _autoLockSeconds
                      ? AppColors.accentBlue
                      : AppColors.white40,
                  size: 20,
                ),
                title: Text(_autoLockLabel(s, v),
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                onTap: () => Navigator.pop(sheetCtx, v),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await _svc.setAutoLockSeconds(chosen);
    HapticFeedback.selectionClick();
    if (mounted) setState(() => _autoLockSeconds = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return SecureScreenGuard(
      child: Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(s.antiTheft,
            style: const TextStyle(
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Text(s.antiTheftDesc,
                    style: const TextStyle(
                        color: AppColors.white70, fontSize: 13.5, height: 1.4)),
                const SizedBox(height: 22),

                // ── Auto-lock grace ──
                _sectionCard(
                  icon: Icons.timer_outlined,
                  title: s.autoLock,
                  subtitle: s.autoLockDesc,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_autoLockLabel(s, _autoLockSeconds),
                          style: const TextStyle(
                              color: AppColors.accentBlue, fontSize: 12.5)),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right,
                          color: AppColors.white40),
                    ],
                  ),
                  onTap: _pickAutoLock,
                ),
                const SizedBox(height: 14),

                // ── Screen-capture protection (always on, stated so the
                //    user knows the guarantee exists rather than
                //    discovering it when a screenshot comes out black) ──
                _sectionCard(
                  icon: Icons.screenshot_monitor_outlined,
                  title: s.screenCaptureBlocked,
                  subtitle: s.screenCaptureBlockedDesc,
                  trailing: _statusPill(s.recoveryConfigured),
                ),
                const SizedBox(height: 14),

                // ── Decoy PIN ──
                _sectionCard(
                  icon: Icons.theater_comedy_outlined,
                  title: s.decoyPin,
                  subtitle: s.decoyPinDesc,
                  trailing: _hasDecoy
                      ? _statusPill(s.decoyPinSet)
                      : const Icon(Icons.chevron_right,
                          color: AppColors.white40),
                  onTap: _hasDecoy ? null : _setDecoyPin,
                  footer: _hasDecoy
                      ? TextButton(
                          onPressed: _removeDecoy,
                          style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 32),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap),
                          child: Text(s.removeDecoyPin,
                              style: const TextStyle(
                                  color: AppColors.error, fontSize: 12.5)),
                        )
                      : null,
                ),
                const SizedBox(height: 14),

                // ── Intruder selfie toggle ──
                _sectionCard(
                  icon: Icons.photo_camera_front_outlined,
                  title: s.intruderSelfie,
                  subtitle: s.intruderSelfieDesc,
                  trailing: Switch(
                    value: _intruderOn,
                    activeColor: AppColors.accentBlue,
                    onChanged: (v) => _toggleIntruder(v),
                  ),
                ),
                const SizedBox(height: 26),

                // ── Break-in log ──
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(s.breakInAttempts,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    if (_log.isNotEmpty)
                      TextButton(
                        onPressed: _clearLog,
                        style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        child: Text(s.clearLog,
                            style: const TextStyle(
                                color: AppColors.error, fontSize: 12.5)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_log.isEmpty)
                  _emptyLog(s)
                else
                  ..._log.map(_logRow),
              ],
            ),
      ),
    );
  }

  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget trailing,
    VoidCallback? onTap,
    Widget? footer,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.darkDivider),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, color: AppColors.accentBlue, size: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(subtitle,
                            style: const TextStyle(
                                color: AppColors.white55,
                                fontSize: 12,
                                height: 1.35)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  trailing,
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
              child: Align(alignment: Alignment.centerLeft, child: footer),
            ),
        ],
      ),
    );
  }

  Widget _statusPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle,
              color: AppColors.accentBlue, size: 13),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  color: AppColors.accentBlue,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _emptyLog(AppStrings s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 34),
      decoration: BoxDecoration(
        color: AppColors.darkSurface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          const Icon(Icons.shield_outlined,
              color: AppColors.white40, size: 34),
          const SizedBox(height: 10),
          Text(s.noBreakIns,
              style: const TextStyle(
                  color: AppColors.white55, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _logRow(IntruderEvent e) {
    final s = AppStrings.of(context);
    final hasPhoto = e.photoPath != null && File(e.photoPath!).existsSync();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.darkDivider),
      ),
      child: Row(
        children: [
          // Thumbnail (or placeholder).
          GestureDetector(
            onTap: hasPhoto ? () => _viewPhoto(e.photoPath!) : null,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 54,
                height: 54,
                child: hasPhoto
                    ? Image.file(File(e.photoPath!),
                        fit: BoxFit.cover,
                        cacheWidth: 108,
                        errorBuilder: (_, __, ___) => _photoPlaceholder(s))
                    : _photoPlaceholder(s),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_formatDate(e.at),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(_formatTime(e.at),
                    style: const TextStyle(
                        color: AppColors.white55, fontSize: 12)),
                // What was actually typed, and at which door. This is the
                // line that turns a log entry into information the owner can
                // act on — a run of 1234/0000 is a stranger, a near-miss of
                // their own PIN is someone who has watched them unlock it.
                if (e.attempted != null && e.attempted!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(_methodIcon(e.method),
                          size: 12, color: AppColors.white40),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          '${_methodLabel(s, e.method)}  ·  ${e.attempted}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.warning,
                              fontSize: 11.5,
                              letterSpacing: 0.6,
                              fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (hasPhoto)
            const Icon(Icons.zoom_out_map,
                color: AppColors.white40, size: 18),
        ],
      ),
    );
  }

  IconData _methodIcon(String? method) {
    switch (method) {
      case 'answer':
        return Icons.help_outline;
      case 'key':
        return Icons.vpn_key_outlined;
      default:
        return Icons.dialpad;
    }
  }

  String _methodLabel(AppStrings s, String? method) {
    switch (method) {
      case 'answer':
        return s.securityQuestion;
      case 'key':
        return s.recoveryKey;
      default:
        return s.pinLabel;
    }
  }

  Widget _photoPlaceholder(AppStrings s) {
    return Container(
      color: AppColors.darkBackground,
      alignment: Alignment.center,
      child: const Icon(Icons.no_photography_outlined,
          color: AppColors.white40, size: 22),
    );
  }

  void _viewPhoto(String path) {
    showDialog<void>(
      context: context,
      builder: (dCtx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            Center(child: Image.file(File(path))),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(dCtx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Actions ──

  /// The decoy PIN is set on the same keypad as every other PIN in the app.
  ///
  /// It matters more here than anywhere else that the two surfaces look
  /// identical: if setting or entering the decoy behaved even slightly
  /// differently from the real PIN, someone standing over the user's shoulder
  /// could tell which one they were being shown.
  Future<void> _setDecoyPin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SetDecoyPinScreen(service: _svc)),
    );
    if (ok == true) await _refresh();
  }

  Future<void> _removeDecoy() async {
    await _svc.clearDecoyPin();
    await _refresh();
  }

  Future<void> _toggleIntruder(bool value) async {
    final s = AppStrings.of(context);
    if (value) {
      // Ensure camera permission before enabling.
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(s.cameraPermissionNeeded),
              duration: const Duration(seconds: 3)));
        }
        return;
      }
    }
    await _svc.setIntruderCaptureEnabled(value);
    HapticFeedback.selectionClick();
    if (mounted) setState(() => _intruderOn = value);
  }

  Future<void> _clearLog() async {
    final s = AppStrings.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        content: Text(s.clearLogConfirm,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text(s.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text(s.clearLog,
                  style: const TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok == true) {
      await _svc.clearIntruderLog();
      await _refresh();
    }
  }

  // ── Date formatting (no intl dependency) ──
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _formatDate(DateTime d) =>
      '${_months[d.month - 1]} ${d.day}, ${d.year}';

  String _formatTime(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ap = d.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ap';
  }
}
