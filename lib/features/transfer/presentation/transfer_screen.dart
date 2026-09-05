import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/router/routes.dart';
import '../../../core/services/file_transfer/file_transfer_service.dart';
import '../../../core/services/file_transfer/file_receiver_service.dart';
import '../../../core/services/file_transfer/received_history.dart';
import '../../../core/services/file_transfer/transfer_discovery.dart';
import '../../../core/services/file_transfer/turbo_link_service.dart';
import '../../../core/services/adb/adb_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../private_folder/presentation/add_files_picker.dart';
import 'folder_send_picker.dart';
import 'qr_scan_screen.dart';

import '../../../core/localization/app_strings.dart';
/// Transfer tab — same-Wi-Fi file sharing.
///
/// Audit fix (real user report "Transfer UI သက်သက်ပဲ"): rewritten
/// to be a working implementation. Sender picks files, taps Start,
/// gets a URL + QR code. Receiver scans (or types) the URL into any
/// browser on the same Wi-Fi network and downloads.
///
/// v1.46: the receiver no longer has to scan or type anything in the normal
/// case — the sending phone announces itself over UDP and appears by name in
/// a "Nearby devices" list, which is the interaction people already know from
/// Zapya/SHAREit. QR and manual address stay as fallbacks for a phone that
/// can't see the broadcast (some corporate APs isolate clients).
class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  bool _picking = false;
  // 0 = Send (this device serves files), 1 = Receive (pull from another
  // Innocent device on the same Wi-Fi, in-app).
  int _mode = 0;
  bool _pairDialogOpen = false;
  // Captured in initState so dispose() never has to touch `ref`, which is on
  // its way out by then. The notifier itself outlives this screen
  // (receiverProvider is not autoDispose), so holding it is safe.
  ReceiverNotifier? _receiver;

  @override
  void initState() {
    super.initState();
    // The radar only runs while the Receive tab is actually on screen: it
    // holds a Wi-Fi MulticastLock, which wakes the radio for traffic we would
    // otherwise never see, so leaving it on would cost battery for nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _receiver = ref.read(receiverProvider.notifier);
      _syncDiscovery();
    });
  }

  @override
  void dispose() {
    // Deliberately NOT via ref — a ConsumerState's ref is on its way out here.
    TransferDiscovery.instance.stopListening();
    // If the user walked away from a finished Turbo receive, give the phone
    // its internet back. An in-flight transfer is left alone on purpose.
    _receiver?.releaseTurboIfIdle();
    super.dispose();
  }

  void _syncDiscovery() {
    if (!mounted) return;
    final n = ref.read(receiverProvider.notifier);
    if (_mode == 1) {
      n.startDiscovery();
    } else {
      n.stopDiscovery();
    }
  }

  void _setMode(int m) {
    if (_mode == m) return;
    setState(() => _mode = m);
    _syncDiscovery();
  }

  Future<void> _pickFiles() async {
    if (_picking) return;
    setState(() => _picking = true);
    // Resolve the localized title NOW, from the current (still-mounted)
    // context. The MaterialPageRoute builder below runs later, when the route
    // is actually pushed — reading `AppStrings.of(context)` inside it would
    // touch this State's `context` after a rapid navigation may have disposed
    // it, and `State.context` throws "Null check operator used on a null
    // value" once the element is gone. That was the Transfer-tab crash.
    final pickerTitle = AppStrings.of(context).selectFilesToSend;
    try {
      // In-app picker: browse storage by folder and multi-select videos,
      // mirroring the Private Folder "Add Files" flow, instead of leaving the
      // app for the system file manager.
      // ROOT navigator, not the shell's.
      //
      // A shell tab pushes into the nested navigator that sits ABOVE the
      // bottom tab bar, so a full-screen task opened this way keeps
      // Video / Music / Transfer / Me visible underneath it. During a
      // file picker those tabs are not just noise — tapping one walks
      // out of a half-made selection with no warning.
      //
      // Browsing WITHIN a tab (an artist, an album, a folder) is the
      // opposite case and correctly stays in the shell.
      await Navigator.of(context, rootNavigator: true).push<bool>(
        MaterialPageRoute(
          builder: (_) => AddFilesPicker(
            title: pickerTitle,
            // v0.50: the picker now hands back generic PickedFiles
            // (videos, images, audio, any file, APKs) — map them 1:1
            // onto SharedFile entries for the LAN server.
            onCommit: (List<PickedFile> picked) async {
              // Android/data files (adb:// paths) can't be read by the LAN
              // server directly — dart:io can't open another app's private
              // storage. Pull each one out to a local temp first, then share
              // THAT path. On-device files pass straight through. Any file that
              // can't be pulled (connection dropped) is skipped with a note so
              // the rest of the batch still sends.
              final shared = <SharedFile>[];
              var pullFailed = 0;
              for (final f in picked) {
                var path = f.path;
                var size = f.sizeBytes;
                if (path.startsWith('adb://')) {
                  final src = path.substring('adb://'.length);
                  String pulled;
                  try {
                    pulled = await AdbService.instance.pullForPlayback(src);
                  } catch (e) {
                    pulled = 'ERROR: $e';
                  }
                  if (pulled.startsWith('ERROR')) {
                    pullFailed++;
                    continue;
                  }
                  path = pulled;
                  try {
                    size = await File(pulled).length();
                  } catch (_) {}
                }
                shared.add(SharedFile(
                  id: '${path.hashCode}',
                  path: path,
                  displayName: f.name,
                  sizeBytes: size,
                ));
              }
              if (shared.isNotEmpty) {
                final wasLive = ref.read(transferProvider).isRunning;
                ref.read(transferProvider.notifier).addFiles(shared);
                if (wasLive && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(AppStrings.of(context).filesAddedLive),
                    behavior: SnackBarBehavior.floating,
                  ));
                }
              }
              if (pullFailed > 0 && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '$pullFailed Android/data file(s) skipped — connect '
                      'iADB and try again.',
                    ),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).failedPickFiles + ': $e')),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Add Innocent's own APK to the share.
  ///
  /// The Apps tab of the picker can already find it, but nobody scrolls a list
  /// of 80 installed apps looking for the one they are holding — and this is
  /// the request people actually have ("send me the app").
  Future<void> _addOwnApk() async {
    final apk = await TurboLink.instance.selfApk();
    if (!mounted) return;
    if (apk == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).turboReasonGeneric)),
      );
      return;
    }
    ref.read(transferProvider.notifier).addFiles([
      SharedFile(
        id: 'self-apk',
        path: apk.path,
        displayName: apk.name,
        sizeBytes: apk.sizeBytes,
      ),
    ]);
  }

  Future<void> _pickFolder() async {
    final messenger = ScaffoldMessenger.of(context);
    final s = AppStrings.of(context);
    // Only report what actually happened. Confirming "folder added" after the
    // user backed out of the browser is worse than saying nothing.
    var picked = false;
    var wasTruncated = false;
    // Root navigator — same reason as the file picker above.
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (_) => FolderSendPicker(
          onPicked: (files, folderName, truncated) {
            picked = true;
            wasTruncated = truncated;
            ref.read(transferProvider.notifier).addFiles(files);
          },
        ),
      ),
    );
    if (!mounted || !picked) return;
    messenger.showSnackBar(SnackBar(
      content: Text(wasTruncated ? s.folderTooManyFiles : s.folderAdded),
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// Approval mode: another phone is asking to download. Held open by the
  /// receiver's HTTP request, so answering here unblocks it immediately.
  Future<void> _showPairDialog(PairRequest req) async {
    if (_pairDialogOpen || !mounted) return;
    _pairDialogOpen = true;
    final s = AppStrings.of(context);
    final notifier = ref.read(transferProvider.notifier);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Row(
          children: [
            Icon(Icons.phone_android, color: AppColors.accentBlue, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(req.deviceName,
                  style: const TextStyle(color: Colors.white, fontSize: 17)),
            ),
          ],
        ),
        content: Text(
          '${req.deviceName} ${s.wantsToReceive}\n(${req.ip})',
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              notifier.respondToPair(false);
              Navigator.of(dctx).pop();
            },
            child: Text(s.decline,
                style: const TextStyle(color: Color(0xFFE57373))),
          ),
          FilledButton(
            onPressed: () {
              notifier.respondToPair(true);
              Navigator.of(dctx).pop();
            },
            child: Text(s.accept),
          ),
        ],
      ),
    );
    _pairDialogOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(transferProvider);
    final notifier = ref.read(transferProvider.notifier);
    // If a receive was interrupted (app killed / swiped mid-download), surface
    // it: watch the receiver for a resume record and flip to the Receive tab
    // once, so the user immediately sees the "Resume" banner instead of having
    // to remember to switch tabs. Only auto-switches while still on Send and
    // no send is in progress.
    ref.listen(receiverProvider.select((s) => s.resumeAvailable),
        (prev, hasResume) {
      if (hasResume == true && _mode == 0 && !state.isRunning && mounted) {
        setState(() => _mode = 1);
        _syncDiscovery();
      }
    });
    ref.listen(transferProvider.select((s) => s.pending), (prev, req) {
      if (req != null) _showPairDialog(req);
    });
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).fileTransfer),
        backgroundColor: AppColors.darkBackground,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'How it works',
            icon: const Icon(Icons.info_outline, size: 22),
            onPressed: _showHelp,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(
                    value: 0,
                    label: Text(AppStrings.of(context).send),
                    icon: const Icon(Icons.upload_outlined, size: 18)),
                ButtonSegment(
                    value: 1,
                    label: Text(AppStrings.of(context).receive),
                    icon: const Icon(Icons.download_outlined, size: 18)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => _setMode(s.first),
            ),
          ),
          Expanded(
            child: _mode == 1
                ? const _ReceivePane()
                : (state.isRunning
                    ? _RunningPane(
                        state: state,
                        shareUrl: notifier.shareUrl,
                        qrPayload: notifier.qrPayload,
                        onStop: notifier.stop,
                        onTogglePause: notifier.setPaused,
                        onAddMore: _pickFiles,
                      )
                    : _PreparePane(
                        state: state,
                        picking: _picking,
                        onPickFiles: _pickFiles,
                        onRemove: notifier.removeFile,
                        onStart: notifier.start,
                        onToggleApproval: notifier.setRequireApproval,
                        onToggleTurbo: notifier.setTurboRequested,
                        onTogglePin: notifier.setPinEnabled,
                        onRename: () => _promptRename(state.deviceName),
                        onSendApp: _addOwnApk,
                        onSendFolder: _pickFolder,
                      )),
          ),
        ],
      ),
    );
  }

  Future<void> _promptRename(String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final s = AppStrings.of(context);
    final value = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.renameThisPhone,
            style: const TextStyle(color: Colors.white, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 28,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            counterStyle: TextStyle(color: AppColors.white30),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.white20)),
            focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: AppColors.accentBlue)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(s.cancel,
                style: const TextStyle(color: AppColors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(controller.text),
            child: Text(s.ok),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.trim().isNotEmpty && mounted) {
      await ref.read(transferProvider.notifier).renameDevice(value);
    }
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).howTransferWorksTitle,
            style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Text(AppStrings.of(context).howTransferWorksBody,
            style: const TextStyle(color: Colors.white70, height: 1.55),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(context).ok,
                style: TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
  }
}

/// Turn a Turbo failure code into something the user can act on. A bare
/// "Turbo failed" is worse than never offering Turbo, because the one thing
/// the user could have fixed (Wi-Fi off, Location off) stays invisible.
String _turboReason(AppStrings s, String reason) {
  switch (reason) {
    case 'wifi_off':
      return s.turboReasonWifiOff;
    case 'location_off':
      return s.turboReasonLocationOff;
    case 'permission_denied':
      return s.turboReasonPermission;
    case 'turbo_unsupported':
    case 'unsupported':
      return s.turboReasonUnsupported;
    case 'declined_or_not_found':
    case 'legacy_timeout':
      return s.turboReasonDeclined;
    case 'no_direct_ip':
    case 'no_address':
      return s.turboReasonNoAddress;
    default:
      return s.turboReasonGeneric;
  }
}

/// Which settings screen (if any) would fix this reason. 'app' means the
/// permission was refused for good and only the app's own settings page can
/// undo it — pointing at Wi-Fi settings there would just waste the user's
/// time.
String? _turboFixTarget(String reason) {
  if (reason == 'wifi_off') return 'wifi';
  if (reason == 'location_off') return 'location';
  if (reason == 'permission_denied') return 'app';
  return null;
}

String _turboFixLabel(AppStrings s, String target) {
  switch (target) {
    case 'wifi':
      return s.turboOpenWifiSettings;
    case 'location':
      return s.turboOpenLocationSettings;
    default:
      return s.turboOpenAppSettings;
  }
}

Future<void> _turboOpenFix(String target) async {
  if (target == 'app') {
    await openAppSettings();
    return;
  }
  await TurboLink.instance.openSettings(target);
}

/// Most rows we will draw in a live-updating list. Past this the list stops
/// being readable anyway, and every row costs a rebuild every second.
const int _kMaxRows = 60;

/// A QR that is only re-encoded when its payload changes.
///
/// The sender's pane rebuilds once a second to show live byte counts, and
/// QrImageView recomputes the whole Reed-Solomon matrix on every build — a
/// steady CPU burn for a picture that never changes, on the exact device that
/// is trying to push 25 MB/s. Returning the identical widget instance makes
/// Flutter skip the subtree entirely.
class _CachedQr extends StatefulWidget {
  final String data;
  const _CachedQr({required this.data});

  @override
  State<_CachedQr> createState() => _CachedQrState();
}

class _CachedQrState extends State<_CachedQr> {
  Widget? _cached;
  String? _lastData;

  @override
  Widget build(BuildContext context) {
    if (_cached == null || _lastData != widget.data) {
      _lastData = widget.data;
      _cached = QrImageView(
        data: widget.data,
        version: QrVersions.auto,
        size: 200,
        backgroundColor: Colors.white,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      );
    }
    return _cached!;
  }
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _fmtRate(double bps) {
  if (bps >= 1024 * 1024) {
    return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  if (bps >= 1024) return '${(bps / 1024).toStringAsFixed(0)} KB/s';
  return '${bps.toStringAsFixed(0)} B/s';
}

String _fmtEta(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  final s = seconds % 60;
  if (m < 60) return '${m}m ${s}s';
  return '${m ~/ 60}h ${m % 60}m';
}

class _PreparePane extends StatelessWidget {
  final TransferState state;
  final bool picking;
  final VoidCallback onPickFiles;
  final void Function(String id) onRemove;
  final VoidCallback onStart;
  final void Function(bool) onToggleApproval;
  final void Function(bool) onToggleTurbo;
  final void Function(bool) onTogglePin;
  final VoidCallback onRename;
  final VoidCallback onSendApp;
  final VoidCallback onSendFolder;

  const _PreparePane({
    required this.state,
    required this.picking,
    required this.onPickFiles,
    required this.onRemove,
    required this.onStart,
    required this.onToggleApproval,
    required this.onToggleTurbo,
    required this.onTogglePin,
    required this.onRename,
    required this.onSendApp,
    required this.onSendFolder,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Identity row: this is the name the other phone will tap on, so it
          // needs to be visible and changeable before the share starts.
          Row(
            children: [
              Icon(Icons.smartphone, size: 16, color: AppColors.white55),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${s.thisPhoneName}: ${state.deviceName ?? '…'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.white70, fontSize: 12.5),
                ),
              ),
              TextButton(
                onPressed: onRename,
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32)),
                child: Text(s.rename, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(s.filesToShare,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              FilledButton.tonalIcon(
                onPressed: picking ? null : onPickFiles,
                icon: picking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add, size: 18),
                label: Text(s.addFiles),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (state.error != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0x33C62828),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(state.error!,
                  style: const TextStyle(
                      color: Color(0xFFFFCDD2), fontSize: 13)),
            ),
          // Handing the app itself to a friend who has no data is the single
          // most common reason these apps get installed in the first place.
          Row(
            children: [
              TextButton.icon(
                onPressed: onSendFolder,
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 34)),
                icon: const Icon(Icons.drive_folder_upload, size: 17),
                label:
                    Text(s.sendFolder, style: const TextStyle(fontSize: 12.5)),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Tooltip(
                  message: s.sendInnocentAppHint,
                  child: TextButton.icon(
                    onPressed: onSendApp,
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 34)),
                    icon: const Icon(Icons.android, size: 17),
                    label: Text(s.sendInnocentApp,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: state.files.isEmpty
                ? _emptyHint(context)
                : ListView.separated(
                    itemCount: state.files.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (_, i) {
                      final f = state.files[i];
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.darkSurface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(_iconFor(f.displayName),
                                color: AppColors.white70, size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    f.displayName,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 14),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _fmtBytes(f.sizeBytes),
                                    style: TextStyle(
                                        color: AppColors.white50,
                                        fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              color: AppColors.white50,
                              onPressed: () => onRemove(f.id),
                              tooltip: 'Remove',
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          // The speed switch. Off by default on purpose: it takes the phone
          // off the internet for the duration, which is a real cost, and the
          // user should be the one deciding to pay it.
          SwitchListTile(
            value: state.turboRequested,
            onChanged: onToggleTurbo,
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.bolt,
                color: state.turboRequested
                    ? AppColors.success
                    : AppColors.white50,
                size: 20),
            title: Text(s.turboTitle,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600)),
            subtitle: Text(s.turboSubtitle,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 11.5, height: 1.35)),
            activeColor: AppColors.success,
          ),
          // Shown only once Turbo is armed, because it is advice about the
          // thing they just switched on. It is the single most useful sentence
          // on this screen: acting on it is the difference between a 2.4 GHz
          // link and a 5 GHz one.
          if (state.turboRequested)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline,
                      size: 14, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(s.turboSccTip,
                        style: const TextStyle(
                            color: AppColors.white70,
                            fontSize: 11.5,
                            height: 1.4)),
                  ),
                ],
              ),
            ),
          // Safety switch for shared/public Wi-Fi. Off by default because the
          // one-tap path is the point; on, nobody downloads without a tap here.
          SwitchListTile(
            value: state.requireApproval,
            onChanged: onToggleApproval,
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.verified_user_outlined,
                color: AppColors.white50, size: 20),
            title: Text(s.askBeforeSending,
                style: const TextStyle(color: Colors.white, fontSize: 13.5)),
            subtitle: Text(s.askBeforeSendingHint,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 11.5, height: 1.35)),
            activeColor: AppColors.accentBlue,
          ),
          SwitchListTile(
            value: state.pin.isNotEmpty,
            onChanged: onTogglePin,
            dense: true,
            contentPadding: EdgeInsets.zero,
            secondary: Icon(Icons.pin_outlined,
                color: AppColors.white50, size: 20),
            title: Text(s.protectWithPin,
                style: const TextStyle(color: Colors.white, fontSize: 13.5)),
            subtitle: Text(s.protectWithPinHint,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 11.5, height: 1.35)),
            activeColor: AppColors.accentBlue,
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed:
                  (state.files.isEmpty || state.starting) ? null : onStart,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: state.starting
                  // Turbo's radio handshake can take most of half a minute.
                  // Without this the screen looked frozen and people tapped
                  // Start again.
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            state.turboRequested
                                ? s.turboStarting
                                : s.connectingToDevice,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      state.files.isEmpty
                          ? s.noFilesHint
                          : '${s.send} (${state.files.length} • ${_fmtBytes(state.totalBytes)})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined,
                size: 48, color: AppColors.white50),
            const SizedBox(height: 16),
            Text(AppStrings.of(context).noFilesHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.white70, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(String name) {
    final ext = p.extension(name).toLowerCase();
    if (['.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v'].contains(ext)) {
      return Icons.movie_outlined;
    }
    if (['.mp3', '.m4a', '.flac', '.ogg', '.wav', '.aac'].contains(ext)) {
      return Icons.audiotrack;
    }
    if (['.jpg', '.jpeg', '.png', '.gif', '.webp'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (['.pdf', '.doc', '.docx', '.txt'].contains(ext)) {
      return Icons.description_outlined;
    }
    if (ext == '.apk') return Icons.android;
    return Icons.insert_drive_file_outlined;
  }
}

class _RunningPane extends StatelessWidget {
  final TransferState state;
  final String shareUrl;
  /// What the QR encodes. Under Turbo this is a `innocent://turbo?…` invite
  /// carrying the Wi-Fi credentials, because no URL is reachable until the
  /// other phone has joined the link.
  final String qrPayload;
  final Future<void> Function() onStop;
  final void Function(bool) onTogglePause;
  final VoidCallback onAddMore;

  const _RunningPane({
    required this.state,
    required this.shareUrl,
    required this.qrPayload,
    required this.onStop,
    required this.onTogglePause,
    required this.onAddMore,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final direct = FileTransferService.isHotspotAddress(state.ipAddress);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(s.shareIsLive,
            style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '${state.deviceName ?? s.thisPhoneName} • ${s.tapDeviceToConnect}',
            style: TextStyle(
                color: AppColors.white70, fontSize: 13, height: 1.4),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          // Who's actually pulling. Before this the sender was blind: it could
          // only show a running byte total with no idea whether anyone had
          // even connected.
          _peersCard(context, s),
          const SizedBox(height: 16),
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              // Only build the QR once there is an address to encode. The QR
              // widget builds its matrix during layout, so handing it empty or
              // unencodable data throws mid-build and takes the whole tab down.
              child: qrPayload.trim().isEmpty
                  ? const SizedBox(
                      width: 200,
                      height: 200,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _CachedQr(data: qrPayload),
            ),
          ),
          const SizedBox(height: 8),
          Text(s.shareScanHint,
            style: TextStyle(
                color: AppColors.white55, fontSize: 11.5, height: 1.4),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    shareUrl,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  color: AppColors.white70,
                  tooltip: 'Copy URL',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: shareUrl));
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(
                        content: Text(AppStrings.of(context).urlCopied),
                        duration: Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Per-file outbound progress, derived from bytes actually pushed on
          // the wire — no extra protocol needed on the receiver's side.
          // Capped: the progress ticker rebuilds this list once a second, and
          // 400 animated bars a second would steal exactly the CPU the
          // transfer needs.
          ...List.generate(
              state.files.length > _kMaxRows ? _kMaxRows : state.files.length,
              (i) {
            final f = state.files[i];
            final served = state.servedPerFile[i] ?? 0;
            final frac = f.sizeBytes > 0
                ? (served / f.sizeBytes).clamp(0.0, 1.0)
                : 0.0;
            final complete = f.sizeBytes > 0 && served >= f.sizeBytes;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(f.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13)),
                      ),
                      const SizedBox(width: 8),
                      if (complete)
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 16)
                      else
                        Text('${(frac * 100).round()}%',
                            style: const TextStyle(
                                color: AppColors.white55, fontSize: 11)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 3,
                      backgroundColor: AppColors.white10,
                    ),
                  ),
                ],
              ),
            );
          }),
          if (state.files.length > _kMaxRows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('+${state.files.length - _kMaxRows} more',
                  style: const TextStyle(
                      color: AppColors.white55, fontSize: 11.5)),
            ),
          const SizedBox(height: 6),
          Text(
            '${_fmtBytes(state.bytesServed)} sent • '
            '${state.files.length} file${state.files.length == 1 ? '' : 's'} '
            '(${_fmtBytes(state.totalBytes)})',
            style: TextStyle(color: AppColors.white55, fontSize: 12),
          ),
          const SizedBox(height: 14),
          _linkModeCard(context, s, direct),
          if (state.turboActive && (state.turboSsid ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            _credentialsCard(context, s),
          ],
          if (state.pin.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.accentBlue.withOpacity(0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.pin_outlined,
                      color: AppColors.accentBlue, size: 18),
                  const SizedBox(width: 10),
                  Text('${s.pinLabel}: ',
                      style: const TextStyle(
                          color: AppColors.white70, fontSize: 12.5)),
                  SelectableText(
                    state.pin,
                    style: TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 22,
                        letterSpacing: 6,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAddMore,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 34)),
              icon: const Icon(Icons.add, size: 17),
              label: Text(s.addMoreFiles,
                  style: const TextStyle(fontSize: 12.5)),
            ),
          ),
          const SizedBox(height: 4),
          // Pause sits next to Stop because they are the two things a sender
          // reaches for mid-transfer, and because putting them side by side
          // makes the difference obvious: one keeps everyone's progress, the
          // other throws the share away.
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => onTogglePause(!state.paused),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: Icon(state.paused ? Icons.play_arrow : Icons.pause,
                      size: 18),
                  label: Text(state.paused ? s.resumeShare : s.pauseShare,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onStop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: const BorderSide(color: Color(0xFFE57373)),
                  ),
                  child: Text(s.stopSharing,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFE57373),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ),
            ],
          ),
          if (state.paused) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.pause_circle_outline,
                    color: AppColors.warning, size: 15),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.sharePaused,
                      style: TextStyle(
                          color: AppColors.warning,
                          fontSize: 11.5,
                          height: 1.4)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          // Tell the sender their address is not download-only. This is the
          // cross-platform half: a phone or laptop with just a browser can
          // push files back, which is what Zapya needs a native iOS/Windows
          // client to do.
          Text(s.webUploadHint,
              style: const TextStyle(
                  color: AppColors.white55, fontSize: 10.5, height: 1.45)),
          const SizedBox(height: 8),
          Text(s.encryptionNote,
              style: const TextStyle(
                  color: AppColors.white55, fontSize: 10.5, height: 1.45)),
        ],
      ),
    );
  }

  /// Says which physical path the bytes are actually taking. This is the
  /// single most useful thing to show here: the difference between the three
  /// states below is roughly an order of magnitude in throughput, and until
  /// now the user had no way to tell which one they were in.
  Widget _linkModeCard(BuildContext context, AppStrings s, bool direct) {
    final Color accent;
    final IconData icon;
    final String title;
    String? body;
    if (state.turboActive) {
      accent = AppColors.success;
      icon = Icons.bolt;
      // Label from the MEASURED band, never the requested one.
      switch (state.turboBand) {
        case '5':
          title = s.turboBadge5;
          break;
        case '2.4':
          title = s.turboBadge24;
          // A 2.4 GHz result usually isn't a defect — it's single channel
          // concurrency dragging the group onto the router's channel. Say so,
          // and say what to do about it, instead of letting it look broken.
          if (state.turboStaWasConnected) body = s.turboSccExplain;
          break;
        default:
          title = s.turboBandUnknown;
      }
    } else if (direct) {
      accent = AppColors.success;
      icon = Icons.bolt;
      title = s.directLinkActive;
    } else {
      accent = AppColors.accentBlue;
      icon = Icons.speed;
      title = s.viaRouterSlower;
      body = s.hotspotTipBody;
    }
    final notice = state.turboNotice;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: accent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                    if (body != null) ...[
                      const SizedBox(height: 4),
                      Text(body,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 11.5,
                              height: 1.45)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          // Turbo was asked for and didn't happen. The share still works, so
          // this is a note, not an error — but silently downgrading the user's
          // explicit choice would be the wrong kind of quiet.
          if (notice != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    color: AppColors.warning, size: 15),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${s.turboUnavailable}\n${_turboReason(s, notice)}',
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 11.5, height: 1.45),
                  ),
                ),
              ],
            ),
            if (_turboFixTarget(notice) != null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => _turboOpenFix(_turboFixTarget(notice)!),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 30)),
                  child: Text(_turboFixLabel(s, _turboFixTarget(notice)!),
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// The Wi-Fi name and password of the Turbo group, in plain text.
  ///
  /// Not redundant with the QR: a phone that doesn't have Innocent can't scan
  /// an `innocent://` code, but it CAN join this network by hand and then open
  /// the http address in a browser — which is how someone gets the app in the
  /// first place.
  Widget _credentialsCard(BuildContext context, AppStrings s) {
    Widget field(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 78,
                child: Text(label,
                    style: const TextStyle(
                        color: AppColors.white55, fontSize: 11.5)),
              ),
              Expanded(
                child: SelectableText(
                  value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy_outlined, size: 16),
                color: AppColors.white55,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                      content: Text(AppStrings.of(context).urlCopied),
                      duration: const Duration(seconds: 1),
                      behavior: SnackBarBehavior.floating,
                    ));
                },
              ),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.turboJoinManually,
              style: const TextStyle(
                  color: AppColors.white70, fontSize: 11.5, height: 1.45)),
          const SizedBox(height: 8),
          field(s.turboWifiName, state.turboSsid ?? ''),
          if ((state.turboPass ?? '').isNotEmpty)
            field(s.turboWifiPassword, state.turboPass!),
        ],
      ),
    );
  }

  Widget _peersCard(BuildContext context, AppStrings s) {
    if (state.peers.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(s.waitingForReceiver,
                  style: const TextStyle(
                      color: AppColors.white70, fontSize: 12.5)),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.success.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Per-receiver bytes, not one lumped total. The server has always
          // served several phones at once; showing their progress separately
          // is what makes sending to a room of people readable.
          for (final peer in state.peers)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(Icons.phone_android,
                      size: 15, color: AppColors.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(peer.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12.5)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _fmtBytes(state.servedPerPeer[peer.ip] ?? 0),
                    style: const TextStyle(
                        color: AppColors.white70, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          if (state.peers.length > 1) ...[
            const SizedBox(height: 4),
            Text('${s.receiversLabel}: ${state.peers.length}',
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}

/// In-app receive pane (Audit P2a): pulls files from another Innocent
/// device's transfer server over the same Wi-Fi — no browser, no native.
/// v1.46 adds the nearby-device radar so the address usually never has to be
/// typed or scanned at all.
class _ReceivePane extends ConsumerStatefulWidget {
  const _ReceivePane();
  @override
  ConsumerState<_ReceivePane> createState() => _ReceivePaneState();
}

class _ReceivePaneState extends ConsumerState<_ReceivePane> {
  final _urlC = TextEditingController();
  final _pinC = TextEditingController();
  int _pinTries = 0;
  bool _manualOpen = false;

  @override
  void dispose() {
    _urlC.dispose();
    _pinC.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    // Ask for camera permission first, then open the scanner.
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).cameraPermissionNeeded),
        ),
      );
      return;
    }
    if (!mounted) return;
    // Root navigator: a camera viewfinder filling the screen with a tab bar
    // stuck across the bottom looks broken, and a stray tap abandons the scan.
    final url = await Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    final notifier = ref.read(receiverProvider.notifier);
    // A Turbo invite carries Wi-Fi credentials, so it means "join this link
    // first, then pull". A plain http:// code means "we're already on the same
    // network" — which is also what every older build of Innocent emits, so
    // both keep working.
    final invite = TurboInvite.tryParse(url);
    if (invite != null) {
      await notifier.connectFromInvite(invite);
      return;
    }
    _urlC.text = url.trim();
    notifier.connect(url.trim());
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final st = ref.watch(receiverProvider);
    final notifier = ref.read(receiverProvider.notifier);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Resume banner: an interrupted download from a previous run was
          // found. One tap reconnects to the sender and continues from where
          // it stopped (partial files are kept on disk, resumed byte-by-byte).
          if (st.resumeAvailable && !st.connecting) _resumeBanner(st, notifier),
          if (st.pinNeededFor != null) _pinPrompt(s, st, notifier),
          if (st.turboJoined) _turboBanner(s, notifier),
          if (st.turboJoining) _turboJoiningCard(s),
          if (!st.connected && !st.turboJoining) ...[
            _nearbyCard(s, st, notifier),
            const SizedBox(height: 14),
            _fallbackConnectors(s, st, notifier),
          ],
          if (st.error != null) ...[
            const SizedBox(height: 12),
            _errorCard(s, st.error!),
          ],
          if (st.connected) ...[
            const SizedBox(height: 4),
            _batchHeader(s, st, notifier),
            const SizedBox(height: 12),
            ...st.files.map((f) => _fileRow(f, st, notifier)),
            if (st.saveDir != null) ...[
              const SizedBox(height: 16),
              Text(AppStrings.of(context).savedToPath(st.saveDir!),
                  style: const TextStyle(
                      color: AppColors.white55, fontSize: 11)),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: st.batchRunning
                  ? null
                  : () {
                      notifier.reset();
                      setState(() => _manualOpen = false);
                      notifier.startDiscovery();
                    },
              icon: const Icon(Icons.arrow_back, size: 16),
              label: Text(s.nearbyDevices),
            ),
          ],
          const SizedBox(height: 18),
          _historySection(s),
        ],
      ),
    );
  }

  /// An error card that can also offer the fix. Turbo failures arrive prefixed
  /// with "turbo:" precisely so this can tell "your Wi-Fi is off" apart from a
  /// generic network message and put the right settings button under it.
  Widget _errorCard(AppStrings s, String error) {
    final isTurbo = error.startsWith('turbo:');
    final reason = isTurbo ? error.substring(6) : '';
    final text = isTurbo ? _turboReason(s, reason) : error;
    final fix = isTurbo ? _turboFixTarget(reason) : null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x33C62828),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style: const TextStyle(
                  color: Color(0xFFFFCDD2), fontSize: 12.5, height: 1.4)),
          if (fix != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => _turboOpenFix(fix),
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 30)),
                child: Text(_turboFixLabel(s, fix),
                    style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The sender put a PIN on this share. Not an error path — a question, so
  /// it gets a normal card rather than the red banner every other failure uses.
  Widget _pinPrompt(AppStrings s, ReceiverState st, ReceiverNotifier notifier) {
    final device = st.pinNeededFor!;
    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentBlue.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pin_outlined, color: AppColors.accentBlue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: AppColors.white55,
                onPressed: () {
                  setState(() => _pinTries = 0);
                  notifier.dismissPinPrompt();
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_pinTries > 0 ? s.wrongPin : s.enterSharePin,
              style: TextStyle(
                  color: _pinTries > 0
                      ? const Color(0xFFFFCDD2)
                      : Colors.white70,
                  fontSize: 12,
                  height: 1.4)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pinC,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  autofocus: true,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 20, letterSpacing: 8),
                  decoration: const InputDecoration(
                    counterText: '',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: AppColors.white20)),
                    focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: AppColors.accentBlue)),
                  ),
                  onSubmitted: (_) => _submitPin(device, notifier),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: st.connecting
                    ? null
                    : () => _submitPin(device, notifier),
                child: Text(s.connectAction),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _submitPin(DiscoveredDevice device, ReceiverNotifier notifier) {
    final code = _pinC.text.trim();
    if (code.length < 4) return;
    FocusScope.of(context).unfocus();
    // Count the attempt now: if the sender rejects it, the prompt comes back
    // and this is what turns a silently-identical box into "that PIN did not
    // match".
    setState(() => _pinTries++);
    notifier.connectToDevice(device, pin: code);
    _pinC.clear();
  }

  Widget _turboJoiningCard(AppStrings s) {
    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.success.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(s.turboJoining,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, height: 1.4)),
          ),
        ],
      ),
    );
  }

  /// While joined, this phone has no internet at all — every other feature in
  /// the app will fail until it disconnects. That has to be visible and it has
  /// to have an exit, or the user is stuck with a phone that "broke".
  Widget _turboBanner(AppStrings s, ReceiverNotifier notifier) {
    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.success.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bolt, color: AppColors.success, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.turboConnected,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(s.turboNoInternet,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 11.5, height: 1.45)),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () async {
                await notifier.leaveTurbo();
                notifier.reset();
                if (mounted) notifier.startDiscovery();
              },
              icon: const Icon(Icons.link_off, size: 16),
              label: Text(s.turboLeave,
                  style: const TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  /// Received-files list. A transfer used to disappear the moment the pane
  /// closed: the bytes were on disk under Innocent/Videos or Innocent/Others
  /// and the user had to go hunting in a file manager for what they had just
  /// been handed. Collapsed by default so it never gets in the way of the
  /// thing people came here to do.
  Widget _historySection(AppStrings s) {
    final items = ref.watch(receivedHistoryProvider);
    if (items.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        iconColor: AppColors.white70,
        collapsedIconColor: AppColors.white70,
        title: Text('${s.transferHistory} (${items.length})',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600)),
        children: [
          for (final item in items.take(30))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(_PreparePane._iconFor(item.name),
                  color: AppColors.white70, size: 20),
              title: Text(item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: Text(
                item.senderName == null
                    ? _fmtBytes(item.sizeBytes)
                    : '${_fmtBytes(item.sizeBytes)} • ${s.receivedFromDevice} ${item.senderName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 11.5),
              ),
              onTap: () => _openReceived(s, item),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () =>
                  ref.read(receivedHistoryProvider.notifier).clear(),
              child: Text(s.clearHistory,
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openReceived(AppStrings s, ReceivedItem item) async {
    // Check first: a file the user deleted from a file manager would otherwise
    // open a black player screen with no explanation.
    final exists = await ReceivedHistoryNotifier.stillExists(item.path);
    if (!mounted) return;
    if (!exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.fileMissing)),
      );
      ref.read(receivedHistoryProvider.notifier).remove(item.path);
      return;
    }
    final category = FileReceiverService.categoryFor(item.name);
    if (category == 'Videos' || category == 'Music') {
      context.push(
        Routes.player,
        extra: <String, String>{'uri': item.path, 'title': item.name},
      );
      return;
    }
    // An APK is the reason most people in this market install a share app at
    // all: a friend hands you the app over Wi-Fi. Android 8+ gates that behind
    // a per-app switch, so check before dropping the user on a system screen
    // with no idea why.
    if (item.name.toLowerCase().endsWith('.apk')) {
      if (!await ReceivedHistoryNotifier.canInstallApks()) {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (dctx) => AlertDialog(
            backgroundColor: AppColors.darkSurface,
            title: Text(s.allowInstallTitle,
                style: const TextStyle(color: Colors.white, fontSize: 17)),
            content: Text(s.allowInstallBody,
                style: const TextStyle(color: Colors.white70, height: 1.5)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(false),
                child: Text(s.cancel,
                    style: const TextStyle(color: AppColors.white70)),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dctx).pop(true),
                child: Text(s.allowInstallAction),
              ),
            ],
          ),
        );
        if (go == true) await ReceivedHistoryNotifier.openInstallPermission();
        return;
      }
    }
    // Everything else belongs to whichever app owns that type; Innocent has no
    // business rendering a PDF.
    final opened = await ReceivedHistoryNotifier.openExternally(item.path);
    if (!mounted || opened) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${s.cannotOpenFile}\n${item.path}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---- nearby-device radar -------------------------------------------

  Widget _nearbyCard(
      AppStrings s, ReceiverState st, ReceiverNotifier notifier) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_tethering,
                  color: AppColors.accentBlue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s.nearbyDevices,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
              ),
              IconButton(
                tooltip: s.refresh,
                icon: const Icon(Icons.refresh, size: 18),
                color: AppColors.white70,
                onPressed: notifier.refreshDiscovery,
              ),
            ],
          ),
          if (st.nearby.isEmpty) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(s.lookingForPhones,
                      style: const TextStyle(
                          color: AppColors.white70, fontSize: 12.5)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(s.noPhonesFound,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 11.5, height: 1.45)),
          ] else ...[
            const SizedBox(height: 4),
            Text(s.tapDeviceToConnect,
                style: const TextStyle(
                    color: AppColors.white55, fontSize: 11.5)),
            const SizedBox(height: 8),
            for (final d in st.nearby)
              InkWell(
                onTap: st.connecting
                    ? null
                    : () => notifier.connectToDevice(d),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.darkSurfaceVariant,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.accentBlue.withOpacity(0.35)),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            AppColors.accentBlue.withOpacity(0.20),
                        child: Icon(Icons.phone_android,
                            size: 17, color: AppColors.accentBlue),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(d.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(
                              '${d.fileCount} file${d.fileCount == 1 ? '' : 's'} • ${_fmtBytes(d.totalBytes)} • ${d.ip}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: AppColors.white55, fontSize: 11.5),
                            ),
                          ],
                        ),
                      ),
                      if (st.connecting)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(Icons.chevron_right,
                            color: AppColors.white50, size: 20),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// QR + manual address, collapsed by default. They are the fallback now, not
  /// the main road: some access points isolate clients so broadcasts never
  /// arrive, and those users still need a way in.
  Widget _fallbackConnectors(
      AppStrings s, ReceiverState st, ReceiverNotifier notifier) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: st.connecting ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: Text(s.scanQrCode,
                    style: const TextStyle(fontSize: 13)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _manualOpen = !_manualOpen),
                icon: Icon(
                    _manualOpen ? Icons.expand_less : Icons.keyboard, size: 18),
                label: Text(s.orEnterAddress,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
            ),
          ],
        ),
        if (_manualOpen) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _urlC,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: 'http://192.168.0.12:8765/abc123\u2026',
              hintStyle: TextStyle(color: AppColors.white30),
              prefixIcon: Icon(Icons.link, color: AppColors.white55),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.white20)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accentBlue)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: st.connecting
                  ? null
                  : () {
                      FocusScope.of(context).unfocus();
                      notifier.connect(_urlC.text);
                    },
              icon: st.connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_download_outlined),
              label: Text(
                  st.connecting ? s.connectingToDevice : s.connectAction),
            ),
          ),
        ],
      ],
    );
  }

  Widget _resumeBanner(ReceiverState st, ReceiverNotifier notifier) {
    final s = AppStrings.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentBlue.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history, color: AppColors.accentBlue, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Resume unfinished transfer',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${st.files.where((f) => !(st.progress[f.index]?.done ?? false)).length} '
            'file(s) still to download from your last session. Make '
            'sure the sender is still sharing, then continue.',
            style: const TextStyle(
                color: Colors.white70, fontSize: 12.5, height: 1.45),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => notifier.resumeSaved(),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(s.resumeReceive),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => notifier.dismissResume(),
                child: Text(s.dismiss),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Header for a connected session: who we're pulling from, the whole-batch
  /// progress bar with speed + ETA, and Download-all / Cancel.
  ///
  /// The old pane showed per-file bars only, so on a 60-file batch there was
  /// no way to tell how long the whole thing would take — and no way at all to
  /// stop it, which was the biggest hole in the receive flow.
  Widget _batchHeader(
      AppStrings s, ReceiverState st, ReceiverNotifier notifier) {
    final total = st.totalBytes;
    final received = st.receivedBytes;
    final frac = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
    final speed = st.currentSpeed;
    final eta = st.etaSeconds;
    final allDone = st.files.isNotEmpty && st.doneCount == st.files.length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(allDone ? Icons.check_circle : Icons.download,
                  size: 18,
                  color: allDone ? AppColors.success : AppColors.accentBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  st.senderName ?? '${st.files.length} file(s) available',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: frac,
              minHeight: 6,
              backgroundColor: AppColors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(
                  allDone ? AppColors.success : AppColors.accentBlue),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  allDone
                      ? s.allFilesReceived
                      : '${s.overallProgress}: ${st.doneCount}/${st.files.length} • '
                          '${_fmtBytes(received)} / ${_fmtBytes(total)}',
                  style: const TextStyle(
                      color: AppColors.white70, fontSize: 11.5),
                ),
              ),
              if (!allDone && speed > 0)
                Text(
                  '${_fmtRate(speed)}${eta != null ? ' • ${_fmtEta(eta)}' : ''}',
                  style: TextStyle(
                      color: AppColors.accentBlue,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600),
                ),
            ],
          ),
          if (st.senderPaused && st.batchRunning) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.pause_circle_outline,
                    color: AppColors.warning, size: 15),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.pausedBySender,
                      style: TextStyle(
                          color: AppColors.warning, fontSize: 11.5)),
                ),
              ],
            ),
          ],
          if (st.userPaused) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.pause_circle_outline,
                    color: AppColors.warning, size: 15),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.receivePaused,
                      style: TextStyle(
                          color: AppColors.warning,
                          fontSize: 11.5,
                          height: 1.4)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: allDone
                      ? null
                      : (st.userPaused
                          ? notifier.resumeBatch
                          : (st.batchRunning ? null : notifier.downloadAll)),
                  icon: Icon(
                      st.userPaused ? Icons.play_arrow : Icons.download,
                      size: 18),
                  label: Text(
                      st.userPaused ? s.resumeReceive : s.downloadAll,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ),
              if (st.batchRunning) ...[
                const SizedBox(width: 8),
                // Pause and Cancel side by side: the whole point is that one
                // of them keeps every downloaded byte and the other does not,
                // and that has to be visible at the moment of choosing.
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => notifier.pauseBatch(),
                    icon: const Icon(Icons.pause, size: 18),
                    label: Text(s.pauseReceive,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => notifier.cancelAll(),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFFE57373)),
                    ),
                    icon: const Icon(Icons.stop,
                        size: 18, color: Color(0xFFE57373)),
                    label: Text(s.cancelTransfer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFFE57373))),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _fileRow(RemoteFile f, ReceiverState st, ReceiverNotifier notifier) {
    final s = AppStrings.of(context);
    final pr = st.progress[f.index];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 2),
                    Text(
                      pr?.skipped == true
                          ? '${_fmtBytes(f.size)} • ${s.alreadyOnThisPhone}'
                          : (f.relPath.isEmpty
                              ? _fmtBytes(f.size)
                              // Show where it will land, so a folder send
                              // doesn't look like a flat pile of files.
                              : '${_fmtBytes(f.size)} • ${p.dirname(f.relPath)}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.white55, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _trailing(f, pr, notifier, st.batchRunning),
            ],
          ),
          if (pr != null && pr.error == null && !pr.done && pr.total > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: pr.fraction,
                minHeight: 4,
                backgroundColor: AppColors.white10,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_fmtBytes(pr.received)} / ${_fmtBytes(pr.total)}',
                  style: const TextStyle(
                      color: AppColors.white55, fontSize: 10.5),
                ),
                if (pr.bytesPerSec > 0)
                  Text(
                    _fmtRate(pr.bytesPerSec),
                    style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ],
          if (pr != null && pr.error != null) ...[
            const SizedBox(height: 6),
            Text(pr.error!,
                style:
                    const TextStyle(color: Colors.redAccent, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _trailing(RemoteFile f, ReceiveProgress? pr,
      ReceiverNotifier notifier, bool batchRunning) {
    if (pr != null && pr.done) {
      return Icon(
          pr.skipped ? Icons.check_circle_outline : Icons.check_circle,
          color: pr.skipped ? AppColors.white50 : Colors.green,
          size: 22);
    }
    if (pr != null && pr.error == null && pr.total > 0 && !pr.done) {
      if (pr.pausedBySender) {
        return Icon(Icons.pause_circle_outline,
            color: AppColors.warning, size: 20);
      }
      return Text('${(pr.fraction * 100).round()}%',
          style: const TextStyle(color: AppColors.white70, fontSize: 12));
    }
    return IconButton(
      icon: Icon(Icons.download,
          color: batchRunning ? AppColors.white30 : AppColors.accentBlue),
      onPressed: batchRunning ? null : () => notifier.downloadOne(f),
    );
  }
}
