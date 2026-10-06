import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/file_transfer/file_receiver_service.dart';
import '../../../core/services/file_transfer/file_transfer_service.dart';
import '../../../core/services/file_transfer/received_history.dart';
import '../../../core/theme/app_colors.dart';

/// The Transfer tab's front door, the way MX Player draws its own: two big
/// buttons — SEND and RECEIVE — and under them a few plain rows. Everything
/// else (the file list, the QR, the radar, the switches) is one tap further
/// in, where it is needed.
///
/// What Innocent keeps that MX does not have, and puts here rather than
/// burying: the Turbo direct link as a visible, one-switch setting (on by
/// default); "Send Innocent app" for a friend with no data; and a card for a
/// share or a download already running, so leaving this page never loses it.
class TransferHome extends ConsumerWidget {
  const TransferHome({
    super.key,
    required this.onSend,
    required this.onReceive,
    required this.onComputer,
    required this.onHistory,
    required this.onSendApp,
    required this.onRename,
    required this.onOpenSend,
    required this.onOpenReceive,
  });

  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback onComputer;
  final VoidCallback onHistory;
  final VoidCallback onSendApp;
  final VoidCallback onRename;

  /// Back to a share that is running, or a download that is.
  final VoidCallback onOpenSend;
  final VoidCallback onOpenReceive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final tx = ref.watch(transferProvider);
    final rx = ref.watch(receiverProvider);
    final history = ref.watch(receivedHistoryProvider);
    final latin = Localizations.localeOf(context).languageCode == 'en';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: <Widget>[
        // What is running right now comes first: the one thing on this page
        // that cannot wait.
        if (tx.isRunning)
          _LiveCard(
            icon: Icons.upload_rounded,
            color: TransferColors.send,
            title: tx.forComputer
                ? s.trSharingComputer
                : s.trSharingNow(tx.files.length),
            subtitle: tx.turboActive ? s.turboTitle : s.trViaWifi,
            onTap: onOpenSend,
          ),
        if (rx.connected || rx.batchRunning || rx.turboJoined)
          _LiveCard(
            icon: Icons.download_rounded,
            color: TransferColors.receive,
            title: rx.batchRunning ? s.trReceivingNow : s.trConnectedTo,
            subtitle: rx.senderName ?? '',
            onTap: onOpenReceive,
          )
        else if (rx.resumeAvailable)
          _LiveCard(
            icon: Icons.restart_alt_rounded,
            color: TransferColors.receive,
            title: s.trResumeReceiving,
            subtitle: '',
            onTap: onOpenReceive,
          ),
        Row(
          children: <Widget>[
            Expanded(
              child: _BigAction(
                key: const ValueKey('transfer-send'),
                label: latin ? s.send.toUpperCase() : s.send,
                icon: Icons.arrow_upward_rounded,
                colors: TransferColors.sendGradient,
                onTap: onSend,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _BigAction(
                key: const ValueKey('transfer-receive'),
                label: latin ? s.receive.toUpperCase() : s.receive,
                icon: Icons.arrow_downward_rounded,
                colors: TransferColors.receiveGradient,
                onTap: onReceive,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _TurboRow(
          on: tx.turboRequested,
          enabled: !tx.isRunning && !tx.starting,
          onChanged: ref.read(transferProvider.notifier).setTurboRequested,
        ),
        const SizedBox(height: 10),
        _RowCard(
          key: const ValueKey('transfer-computer'),
          icon: Icons.devices_rounded,
          title: s.trShareWith,
          below: Wrap(
            spacing: 14,
            runSpacing: 4,
            children: <Widget>[
              _Chip(icon: Icons.computer_rounded, text: s.trPc),
              const _Chip(icon: Icons.phone_iphone_rounded, text: 'iPhone'),
              _Chip(icon: Icons.tablet_android_rounded, text: s.trTablet),
            ],
          ),
          onTap: onComputer,
        ),
        const SizedBox(height: 10),
        _RowCard(
          key: const ValueKey('transfer-history'),
          icon: Icons.history_rounded,
          title: s.transferHistory,
          trailing: history.isEmpty ? null : '${history.length}',
          onTap: onHistory,
        ),
        const SizedBox(height: 10),
        _RowCard(
          icon: Icons.android_rounded,
          title: s.sendInnocentApp,
          subtitle: s.trSendAppShort,
          onTap: onSendApp,
        ),
        const SizedBox(height: 18),
        // The name the other phone sees and taps.
        Row(
          children: <Widget>[
            const Icon(Icons.smartphone_rounded,
                size: 16, color: AppColors.white55),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${s.thisPhoneName}: ${tx.deviceName ?? '…'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.white70, fontSize: 12.5, height: 1.4),
              ),
            ),
            TextButton(
              onPressed: onRename,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32)),
              child: Text(s.rename, style: const TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ],
    );
  }
}

/// The colours of the two directions, everywhere on the tab: green sends,
/// blue receives — MX's own, and the convention people already read.
abstract final class TransferColors {
  static const Color send = Color(0xFF2FCB74);
  static const Color receive = Color(0xFF4C6EF5);
  static const List<Color> sendGradient = <Color>[
    Color(0xFF5BE89A),
    Color(0xFF22B864),
  ];
  static const List<Color> receiveGradient = <Color>[
    Color(0xFF6A86FF),
    Color(0xFF3D5AE8),
  ];
  static const Color card = Color(0xFF2A2D33);
}

class _BigAction extends StatelessWidget {
  const _BigAction({
    super.key,
    required this.label,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: colors.last.withAlpha(0x55),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: SizedBox(
              height: 118,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  // Scaled down rather than cut: "လက်ခံမယ်" at 22 sp is wider
                  // than half a 360 dp phone.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(icon, color: Colors.white, size: 30),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          maxLines: 1,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Turbo, on one line with its switch: what it is, and that it is on.
class _TurboRow extends StatelessWidget {
  const _TurboRow(
      {required this.on, required this.enabled, required this.onChanged});

  final bool on;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: on ? const Color(0xFF16261D) : TransferColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color:
                on ? TransferColors.send.withAlpha(0x66) : Colors.transparent),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.bolt_rounded,
              color: on ? TransferColors.send : AppColors.white55, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(s.turboTitle,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        height: 1.45)),
                Text(on ? s.trTurboOnShort : s.trTurboOffShort,
                    style: const TextStyle(
                        color: AppColors.white70, fontSize: 12, height: 1.45)),
              ],
            ),
          ),
          Switch(
            value: on,
            onChanged: enabled ? onChanged : null,
            activeColor: Colors.white,
            activeTrackColor: TransferColors.send,
          ),
        ],
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.below,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? below;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: TransferColors.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
            child: Row(
              children: <Widget>[
                Icon(icon, color: Colors.white, size: 28),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              height: 1.45)),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: const TextStyle(
                                color: AppColors.white55,
                                fontSize: 12,
                                height: 1.45)),
                      if (below != null) ...<Widget>[
                        const SizedBox(height: 4),
                        below!,
                      ],
                    ],
                  ),
                ),
                if (trailing != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(trailing!,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                const Icon(Icons.chevron_right_rounded,
                    color: AppColors.white55, size: 26),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 15, color: const Color(0xFF8EA2FF)),
        const SizedBox(width: 4),
        Text(text,
            style: const TextStyle(
                color: Color(0xFF8EA2FF),
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.45)),
      ],
    );
  }
}

/// A share or a download in progress, as a card at the top of the page.
class _LiveCard extends StatelessWidget {
  const _LiveCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: color.withAlpha(0x26),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withAlpha(0x80)),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              height: 1.45)),
                      if (subtitle.isNotEmpty)
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.white70,
                                fontSize: 12,
                                height: 1.45)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Colors.white70, size: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Transfer settings ───────────────────────────────────────────────────────

/// The switches that used to sit under the file list, where they made a
/// small phone's Send screen overflow: Turbo, ask before sending, PIN.
class TransferOptionsSheet extends ConsumerWidget {
  const TransferOptionsSheet({super.key, required this.onHelp});

  final VoidCallback onHelp;

  static Future<void> show(BuildContext context,
      {required VoidCallback onHelp}) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => TransferOptionsSheet(onHelp: onHelp),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final st = ref.watch(transferProvider);
    final n = ref.read(transferProvider.notifier);
    final locked = st.isRunning || st.starting;
    TextStyle title() => const TextStyle(
        color: Colors.white,
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
        height: 1.45);
    TextStyle sub() =>
        const TextStyle(color: AppColors.white55, fontSize: 12, height: 1.45);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(s.trSettings,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      height: 1.45)),
            ),
            SwitchListTile(
              value: st.turboRequested,
              onChanged: locked ? null : n.setTurboRequested,
              secondary: Icon(Icons.bolt_rounded,
                  color: st.turboRequested
                      ? TransferColors.send
                      : AppColors.white55),
              title: Text(s.turboTitle, style: title()),
              subtitle: Text(s.turboSubtitle, style: sub()),
              activeTrackColor: TransferColors.send,
            ),
            if (st.turboRequested)
              Padding(
                padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
                child: Text(s.turboSccTip,
                    style: sub().copyWith(color: AppColors.white70)),
              ),
            SwitchListTile(
              value: st.requireApproval,
              onChanged: n.setRequireApproval,
              secondary: const Icon(Icons.verified_user_outlined,
                  color: AppColors.white55),
              title: Text(s.askBeforeSending, style: title()),
              subtitle: Text(s.askBeforeSendingHint, style: sub()),
            ),
            SwitchListTile(
              value: st.pin.isNotEmpty,
              onChanged: n.setPinEnabled,
              secondary:
                  const Icon(Icons.pin_outlined, color: AppColors.white55),
              title: Text(s.protectWithPin, style: title()),
              subtitle: Text(s.protectWithPinHint, style: sub()),
            ),
            ListTile(
              leading: const Icon(Icons.help_outline_rounded,
                  color: AppColors.white55),
              title: Text(s.howTransferWorksTitle, style: title()),
              onTap: () {
                Navigator.of(context).pop();
                onHelp();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── History ─────────────────────────────────────────────────────────────────

/// Everything this phone has received, newest first, a page of its own.
class TransferHistoryScreen extends ConsumerWidget {
  const TransferHistoryScreen({super.key, required this.onOpen});

  /// Opens a received file (checked to still exist by the caller).
  final void Function(ReceivedItem item) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final items = ref.watch(receivedHistoryProvider);
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(s.transferHistory,
            style: const TextStyle(color: Colors.white)),
        actions: <Widget>[
          if (items.isNotEmpty)
            TextButton(
              onPressed: () =>
                  ref.read(receivedHistoryProvider.notifier).clear(),
              child: Text(s.clearHistory),
            ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.history_rounded,
                        size: 56, color: AppColors.white30),
                    const SizedBox(height: 14),
                    Text(s.trHistoryEmpty,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppColors.white70,
                            fontSize: 13.5,
                            height: 1.55)),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, i) {
                final it = items[i];
                final d = it.receivedAt;
                final when = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
                    '${d.day.toString().padLeft(2, '0')} '
                    '${d.hour.toString().padLeft(2, '0')}:'
                    '${d.minute.toString().padLeft(2, '0')}';
                return Material(
                  color: TransferColors.card,
                  borderRadius: BorderRadius.circular(12),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    leading:
                        Icon(transferIconFor(it.name), color: Colors.white70),
                    title: Text(it.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14, height: 1.45)),
                    subtitle: Text(
                      [
                        transferFmtBytes(it.sizeBytes),
                        if (it.senderName != null) it.senderName!,
                        when,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.white55, fontSize: 12, height: 1.45),
                    ),
                    onTap: () => onOpen(it),
                  ),
                );
              },
            ),
    );
  }
}

IconData transferIconFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot).toLowerCase();
  const video = <String>['.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v'];
  const audio = <String>['.mp3', '.m4a', '.flac', '.ogg', '.wav', '.aac'];
  const image = <String>['.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic'];
  if (video.contains(ext)) return Icons.movie_outlined;
  if (audio.contains(ext)) return Icons.audiotrack_rounded;
  if (image.contains(ext)) return Icons.image_outlined;
  if (ext == '.apk') return Icons.android_rounded;
  if (const <String>['.pdf', '.doc', '.docx', '.txt'].contains(ext)) {
    return Icons.description_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

String transferFmtBytes(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
  return '$b B';
}

// ── Share with a computer, an iPhone, a tablet ──────────────────────────────

/// A browser share. The phone serves a page; the computer (or iPhone, or
/// tablet) opens it, downloads from the phone, or drops files onto it to send
/// them to the phone. Nothing to install on the other side.
///
/// With Turbo the phone makes its own Wi-Fi and the computer joins it —
/// fastest, and works with no router at all. The Wi-Fi QR here is the
/// standard one: an iPhone's or Android's camera, or Windows' Camera app,
/// joins from it without typing the password. Without Turbo, both just need
/// to be on the same Wi-Fi.
class ComputerSharePane extends ConsumerWidget {
  const ComputerSharePane({super.key, required this.onAddFiles});

  final VoidCallback onAddFiles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final st = ref.watch(transferProvider);
    final n = ref.read(transferProvider.notifier);
    final live = st.isRunning && st.forComputer;
    final url = live ? n.shareUrl : '';
    final wifiQr = live ? n.wifiQrPayload : '';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: <Widget>[
        Text(s.trPcTitle,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                height: 1.45)),
        const SizedBox(height: 4),
        Text(s.trPcLead,
            style: const TextStyle(
                color: AppColors.white70, fontSize: 13, height: 1.55)),
        const SizedBox(height: 16),
        _PcStep(
          n: 1,
          // Before starting, what WILL happen (the switch); once live, what
          // did (a phone that could not make a direct link fell back).
          title: (live ? st.turboActive : st.turboRequested)
              ? s.trPcStep1Turbo
              : s.trPcStep1Wifi,
          child: live && st.turboActive && wifiQr.isNotEmpty
              ? _WifiJoinCard(
                  ssid: st.turboSsid ?? '',
                  pass: st.turboPass ?? '',
                  qr: wifiQr,
                )
              : null,
        ),
        _PcStep(
          n: 2,
          title: s.trPcStep2,
          child: live && url.isNotEmpty ? _UrlCard(url: url) : null,
        ),
        _PcStep(n: 3, title: s.trPcStep3, last: true),
        const SizedBox(height: 8),
        if (st.error != null && !live)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(st.error!,
                style:
                    const TextStyle(color: Color(0xFFFFCDD2), fontSize: 12.5)),
          ),
        if (live) ...<Widget>[
          if (st.peers.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '${s.trPcConnected(st.peers.length)} · '
                '${transferFmtBytes(st.bytesServed)}',
                style: const TextStyle(
                    color: TransferColors.send,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onAddFiles,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(s.addFiles),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: n.stop,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: Text(s.stopSharing),
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF3A3D44),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                ),
              ),
            ],
          ),
          if (st.files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(s.trPcSharingFiles(st.files.length),
                  style: const TextStyle(
                      color: AppColors.white55, fontSize: 12, height: 1.45)),
            ),
        ] else
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const ValueKey('transfer-computer-start'),
              onPressed: st.starting ? null : () => n.start(forComputer: true),
              icon: st.starting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.play_arrow_rounded),
              label: Text(st.starting
                  ? (st.turboRequested ? s.turboStarting : s.connectingToDevice)
                  : s.trPcStart),
              style: FilledButton.styleFrom(
                backgroundColor: TransferColors.receive,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
      ],
    );
  }
}

class _PcStep extends StatelessWidget {
  const _PcStep(
      {required this.n, required this.title, this.child, this.last = false});

  final int n;
  final String title;
  final Widget? child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 12 : 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
                color: TransferColors.receive, shape: BoxShape.circle),
            child: Text('$n',
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 13)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.5)),
                ),
                if (child != null) ...<Widget>[
                  const SizedBox(height: 10),
                  child!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WifiJoinCard extends StatelessWidget {
  const _WifiJoinCard(
      {required this.ssid, required this.pass, required this.qr});

  final String ssid;
  final String pass;
  final String qr;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TransferColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(8)),
            child: StableQr(data: qr, size: 108),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _CopyLine(label: s.turboWifiName, value: ssid),
                const SizedBox(height: 8),
                if (pass.isNotEmpty)
                  _CopyLine(label: s.turboWifiPassword, value: pass),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UrlCard extends StatelessWidget {
  const _UrlCard({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TransferColors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(8)),
            child: StableQr(data: url, size: 108),
          ),
          const SizedBox(width: 12),
          Expanded(child: _CopyLine(label: 'URL', value: url, big: true)),
        ],
      ),
    );
  }
}

class _CopyLine extends StatelessWidget {
  const _CopyLine({required this.label, required this.value, this.big = false});

  final String label;
  final String value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(AppStrings.of(context).urlCopied),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ));
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label,
              style: const TextStyle(color: AppColors.white55, fontSize: 11)),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Flexible(
                child: Text(value,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: big ? 13.5 : 14,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace')),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.copy_rounded,
                  size: 14, color: AppColors.white55),
            ],
          ),
        ],
      ),
    );
  }
}

/// A QR that is drawn once. The share's screen rebuilds every second with the
/// byte count, and QrImageView recomputes its whole matrix on each build — a
/// CPU burn on the phone that is trying to push 25 MB/s.
class StableQr extends StatefulWidget {
  const StableQr({super.key, required this.data, required this.size});

  final String data;
  final double size;

  @override
  State<StableQr> createState() => _StableQrState();
}

class _StableQrState extends State<StableQr> {
  Widget? _qr;
  String? _for;

  @override
  Widget build(BuildContext context) {
    if (_qr == null || _for != widget.data) {
      _for = widget.data;
      _qr = QrImageView(
          data: widget.data, size: widget.size, padding: EdgeInsets.zero);
    }
    return _qr!;
  }
}
