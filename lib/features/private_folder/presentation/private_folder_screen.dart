import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as pth;
import 'package:share_plus/share_plus.dart';
import 'dart:io';

import '../../../core/router/routes.dart';
import '../../../core/services/biometric/biometric_service.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../../../core/services/private_folder/private_folder_service.dart';
import '../../../core/services/secure_screen/secure_screen_service.dart';
import '../../local_browser/presentation/library_provider.dart';
import '../../../core/theme/app_colors.dart';
import 'add_files_picker.dart';
import 'vault_progress.dart';
import 'vault_pin_pad.dart';
import 'vault_pin_flow.dart';
import 'private_folder_recovery.dart';
import 'private_folder_antitheft.dart';
import '../data/private_folder_providers.dart';
import '../../../core/di/core_providers.dart' show resumeStorageProvider;
// Reuse Local's EXACT sort/view system for 1:1 parity — same dialog,
// same 10 sort fields, same Fields + Advanced sections, same persistence.
import '../../local_browser/presentation/sort_view_dialog.dart';
import '../../local_browser/domain/sort_options.dart';

import '../../../core/localization/app_strings.dart';

part 'private_folder_pin_widgets.dart';

/// Category filter for the vault file-manager (v0.51). `all` shows
/// everything; the rest filter by the entry's resolved media kind.
enum _VaultCat { all, video, image, audio, file }

class PrivateFolderScreen extends ConsumerStatefulWidget {
  const PrivateFolderScreen({super.key});

  @override
  ConsumerState<PrivateFolderScreen> createState() =>
      _PrivateFolderScreenState();
}

class _PrivateFolderScreenState extends ConsumerState<PrivateFolderScreen>
    with WidgetsBindingObserver {
  bool _checking = true;
  bool _hasPin = false;
  bool _unlocked = false;
  List<PrivateEntry> _entries = [];

  // Memoised file sizes (vaultPath → bytes). Reading a file's length is a
  // synchronous disk stat; without this the storage indicator and the
  // size-sort would stat every file on every rebuild, janking large vaults.
  // Cleared whenever the entry list is reloaded so it can't go stale.
  final Map<String, int> _sizeCache = {};
  List<PrivateFolderMeta> _folders = [];

  // File-manager UI state (v0.51).
  String? _openFolderId; // null = root
  _VaultCat _cat = _VaultCat.all; // category filter
  bool _searching = false;
  String _query = '';
  // Sort/view state uses the Private Folder's OWN isolated preferences
  // (privateFolderPreferencesProvider), so the same SortViewDialog UI
  // drives this screen — all 10 sort fields, direction, view mode, layout,
  // Fields and Advanced — without ever affecting the public Local tab.

  // Decoy mode: the user entered the decoy PIN, so we show a convincing
  // but EMPTY vault. The real entries are never loaded, and mutating
  // actions (add / create folder) are quietly disabled so a coercer can't
  // discover the deception or tamper with the hidden data.
  bool _decoyMode = false;

  // Multi-select (batch move / unlock / delete). Keyed by videoUri.
  bool _selectionMode = false;
  final Set<String> _selected = <String>{};

  // Guards against overlapping long-running operations (batch move/unlock/
  // delete, single unlock/delete). Tapping two actions quickly could
  // otherwise interleave file moves and reload a half-updated list.
  bool _busy = false;

  // ── Auto-lock (v1.49) ───────────────────────────────────────────────
  // Grace period, in seconds, between the app leaving the foreground and the
  // vault re-locking. 0 (the default) = immediately.
  int _autoLockSeconds = 0;
  Timer? _autoLockTimer;

  /// Set while THIS screen is deliberately causing a foreground loss — a
  /// runtime-permission dialog from the file picker, a share sheet, the
  /// camera prompt. Without it those flows re-lock the vault behind the
  /// user's back, so returning from the picker they just used lands them on
  /// the PIN pad again. The suppression covers only the ambiguous `inactive`
  /// state; a real `paused` still locks, picker open or not.
  bool _suppressAutoLock = false;

  void _enterSelection(PrivateEntry e) {
    setState(() {
      _selectionMode = true;
      _selected
        ..clear()
        ..add(e.videoUri);
    });
  }

  void _toggleSelected(PrivateEntry e) {
    setState(() {
      if (_selected.contains(e.videoUri)) {
        _selected.remove(e.videoUri);
        if (_selected.isEmpty) _selectionMode = false;
      } else {
        _selected.add(e.videoUri);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }
  final _searchCtrl = TextEditingController();

  PrivateFolderService get _svc => ref.read(privateFolderServiceProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    _autoLockTimer?.cancel();
    _searchCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // A private folder that survives the app being backgrounded is not
    // private: hand someone an unlocked phone and they just reopen the app.
    // So it re-locks — but WHEN it re-locks needs more care than the first
    // version gave it.
    //
    // The old rule locked on `inactive` as well as `paused`, and `inactive`
    // is ambiguous. It covers a screen turning off, but equally a pulled
    // notification shade or a runtime-permission dialog. The result was a
    // vault that threw the user out constantly — including every single time
    // they added files, because the picker asks for a media permission and
    // that dialog is an `inactive`. A security control people have to fight
    // is a security control people switch off.
    //
    // This project has met the same ambiguity before, in the player's
    // background-audio detach (v1.45), and the answer is the same: treat
    // `paused` as real and make `inactive` prove itself by lasting.
    //
    //   resumed          → cancel everything, we are back
    //   paused / hidden  → genuinely backgrounded: lock after the grace
    //   inactive         → arm a timer; a shade-pull or dialog is cancelled
    //                      by the resume that follows, a screen-off is not
    //
    // The `inactive` floor exists because some OEM builds report screen-off
    // as `inactive` and never go on to `paused` — the same device behaviour
    // that broke background audio here once already.
    if (s == AppLifecycleState.resumed) {
      _autoLockTimer?.cancel();
      _autoLockTimer = null;
      return;
    }
    if (!_unlocked) return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _armAutoLock(Duration(seconds: _autoLockSeconds));
    } else if (s == AppLifecycleState.inactive) {
      if (_suppressAutoLock) return;
      const floor = Duration(seconds: 3);
      final grace = Duration(seconds: _autoLockSeconds);
      _armAutoLock(grace > floor ? grace : floor);
    }
  }

  void _armAutoLock(Duration d) {
    _autoLockTimer?.cancel();
    if (d <= Duration.zero) {
      _lockNow();
      return;
    }
    _autoLockTimer = Timer(d, _lockNow);
  }

  void _lockNow() {
    _autoLockTimer = null;
    if (!mounted || !_unlocked) return;
    setState(() {
      _unlocked = false;
      // Drop the decrypted list from memory as well as from the screen.
      // Leaving it in a field would keep every vault path and title in the
      // heap behind a lock screen that claims they are gone.
      _entries = [];
      _folders = [];
      _decoyMode = false;
      _selectionMode = false;
      _selected.clear();
      _openFolderId = null;
      _sizeCache.clear();
    });
  }

  /// Run [body] without letting the ambiguous `inactive` state re-lock the
  /// vault. Use for anything that pops a SYSTEM surface over the app.
  Future<T> _withoutAutoLock<T>(Future<T> Function() body) async {
    _suppressAutoLock = true;
    _autoLockTimer?.cancel();
    try {
      return await body();
    } finally {
      _suppressAutoLock = false;
    }
  }

  Future<void> _check() async {
    final hasPin = await _svc.hasPin();
    if (mounted) {
      setState(() {
        _hasPin = hasPin;
        _checking = false;
      });
    }
  }

  Future<void> _onUnlocked([PinKind kind = PinKind.real]) async {
    final decoy = kind == PinKind.decoy;
    // In decoy mode we deliberately load NOTHING real — the vault appears
    // empty. In real mode we load the actual entries + folders.
    final entries = decoy ? <PrivateEntry>[] : await _svc.loadEntries();
    final folders =
        decoy ? <PrivateFolderMeta>[] : await _svc.loadFolders();
    final grace = await _svc.autoLockSeconds();
    if (!decoy) await _measureSizes(entries);
    if (mounted) {
      setState(() {
        _unlocked = true;
        _decoyMode = decoy;
        _entries = entries;
        _folders = folders;
        _autoLockSeconds = grace;
      });
    }
  }

  /// Fill [_sizeCache] with real byte counts, off the build thread.
  ///
  /// These used to be read lazily from inside `build()` with `existsSync()` +
  /// `lengthSync()`. Both are blocking syscalls, and the storage indicator in
  /// the title bar asks for EVERY entry — so the first frame after any reload
  /// performed two blocking calls per file on the UI thread. A few dozen
  /// files was invisible; a few hundred is dropped frames, and on slow eMMC
  /// storage it is long enough to be an ANR. Nothing about the number needs
  /// to be computed during layout, so it is computed before it.
  Future<void> _measureSizes(List<PrivateEntry> entries) async {
    for (final e in entries) {
      final path = e.playablePath;
      if (_sizeCache.containsKey(path)) continue;
      try {
        final f = File(path);
        _sizeCache[path] = await f.exists() ? await f.length() : 0;
      } catch (_) {
        _sizeCache[path] = 0;
      }
    }
  }

  /// The ONE path that pulls real vault contents into the UI.
  ///
  /// THE BUG THIS CLOSES, and it defeated the decoy feature completely:
  /// entering the decoy PIN showed an empty vault, but a dozen ordinary
  /// actions ended by re-reading the store and assigning the result straight
  /// to `_entries`. Tapping Refresh in the overflow menu was enough — the
  /// real, hidden file list appeared in full, in front of the person the
  /// decoy exists to deceive. Unlock, delete, rename, move and every batch
  /// operation had the same ending.
  ///
  /// The fix is structural rather than a dozen scattered checks: every
  /// refresh in this screen now funnels through here, and here refuses to
  /// touch the store during a decoy session. A future action that forgets to
  /// think about the decoy inherits the correct behaviour instead of
  /// reopening the hole.
  Future<void> _reload() async {
    if (_decoyMode) return;
    // Also refuse while locked. _lockNow() deliberately drops the entry list
    // from memory, but a picker or share opened before the lock can return
    // afterwards and call this — which would pull every vault path and title
    // straight back into the heap behind a screen that says they are gone.
    // Not a visible leak (the body renders the PIN pad either way), but it
    // undoes the one thing _lockNow was for.
    if (!_unlocked) return;
    _sizeCache.clear(); // vault may have changed — drop cached sizes
    final entries = await _svc.loadEntries();
    final folders = await _svc.loadFolders();
    await _measureSizes(entries);
    if (mounted) {
      setState(() {
        _entries = entries;
        _folders = folders;
      });
    }
  }

  /// Apply a decoy-session change to the in-memory list only.
  ///
  /// Returns true when it handled the action, so callers read as:
  /// `if (_decoyEdit(...)) return;`. The point is that a coercer watching
  /// over the user's shoulder sees delete, rename and move behave exactly as
  /// they would in the real vault, while nothing is written and nothing real
  /// is ever read back.
  bool _decoyEdit(void Function() apply) {
    if (!_decoyMode) return false;
    setState(apply);
    return true;
  }

  /// Open the full-screen "Select Files To Add" picker. On return with a
  /// committed selection, reload the vault list and refresh the library so
  /// the newly-hidden videos drop out of the main lists (mirrors _remove).
  Future<void> _openAddFiles() async {
    // Resolve the localized title up front, from the still-mounted context.
    // Reading AppStrings.of(context) inside the deferred MaterialPageRoute
    // builder would touch this State's context after a fast navigation may
    // have disposed it, throwing "Null check operator used on a null value".
    final pickerTitle = AppStrings.of(context).selectFilesToAdd;
    // Decoy mode: never write to the real vault. Route the picker through
    // an onCommit that only appends to the in-memory decoy list, so the
    // action looks normal to a coercer but persists nothing and can't
    // touch the hidden data. These fake entries vanish on next unlock.
    if (_decoyMode) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
            builder: (_) => AddFilesPicker(
                  title: pickerTitle,
                  onCommit: (picked) async {
                    if (!mounted) return;
                    setState(() {
                      for (final f in picked) {
                        _entries.insert(
                          0,
                          PrivateEntry(
                            videoUri: f.path,
                            videoTitle: f.name,
                            addedAt: DateTime.now(),
                            folderId: _openFolderId,
                          ),
                        );
                      }
                    });
                  },
                )),
      );
      return;
    }
    // The picker asks the OS for a media permission the first time each
    // category is opened, and that dialog reads as `inactive` — which used
    // to re-lock the vault underneath, so the user came back from adding
    // files to a PIN pad every single time.
    final added = await _withoutAutoLock(() => Navigator.of(context).push<bool>(
          MaterialPageRoute(
              builder: (_) => AddFilesPicker(
                    service: _svc,
                    title: pickerTitle,
                    // Files added while inside a folder land in that folder.
                    targetFolderId: _openFolderId,
                  )),
        ));
    if (added == true) {
      ref.invalidate(privateFolderUrisProvider);
      await _reload();
    }
  }

  /// Audit fix (was a "coming soon" stub): change the Private Folder PIN.
  /// Requires the current PIN, then a new PIN entered twice. Delegates
  /// to PrivateFolderService.setPin which re-checks the old PIN and
  /// re-hashes with the per-install salt.
  /// After the PIN is first created, offer (once) to set up recovery.
  /// Non-blocking — the user can skip and configure it later from the
  /// overflow menu. Only shown if no recovery method exists yet.
  Future<void> _maybePromptRecoverySetup() async {
    final has = await _svc.hasRecovery();
    if (has || !mounted) return;
    final s = AppStrings.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.setUpRecovery,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(s.recoverySetupPrompt,
            style: const TextStyle(color: AppColors.white70, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text(s.skipForNow)),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text(s.setUpRecovery)),
        ],
      ),
    );
    if (go == true && mounted) {
      await _withoutAutoLock(() => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const RecoverySetupScreen())));
    }
  }

  /// Change the vault PIN.
  ///
  /// Was a three-field AlertDialog driven by the system keyboard. It is now
  /// the same keypad flow as setup and unlock — one PIN surface for the whole
  /// feature, so behaviour, validation and haptics cannot drift apart between
  /// them, and the digits never reach a third-party keyboard.
  Future<void> _changePin() async {
    final changed = await _withoutAutoLock(() =>
        Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => ChangePinScreen(service: _svc)),
        ));
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppStrings.of(context).pinChanged),
          duration: const Duration(seconds: 2)));
      await _maybePromptRecoverySetup();
    }
  }

  Future<void> _remove(PrivateEntry e) async {
    if (_decoyEdit(() => _entries.removeWhere((x) => x.videoUri == e.videoUri))) {
      return;
    }
    try {
      if (e.isVaulted) {
        // The file was physically moved into the vault — un-tracking it
        // without moving it back would orphan the user's only copy, so
        // "unlock" here means restore it to shared storage.
        final restored = await _svc.restoreFromVault(e);
        if (restored != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppStrings.of(context).restoredToLibrary)),
          );
        }
      } else {
        await _svc.removeEntry(e.videoUri);
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.of(context).restoreFailed + ': $err')),
        );
      }
      return;
    }
    if (mounted) {
      // Refresh library so video reappears in main lists
      ref.invalidate(privateFolderUrisProvider);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    // Back-button priority: (1) leave selection mode, (2) pop an open
    // folder back to root, (3) actually leave the screen.
    // Screen-capture protection covers the ENTIRE screen, PIN pad included —
    // not just the file list. Two reasons: a recording of the keypad gives
    // away the PIN as surely as a recording of the contents gives away the
    // files, and the recents thumbnail Android takes is of whatever is on
    // screen when the user leaves, which is frequently the unlocked list.
    return SecureScreenGuard(
      child: PopScope(
      canPop: !_selectionMode && _openFolderId == null,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelection();
        } else if (_openFolderId != null) {
          setState(() => _openFolderId = null);
        }
      },
      child: Scaffold(
      backgroundColor: AppColors.darkBackground,
      // App bar mirrors Local's toolbar 1:1 (screenshot parity):
      // title + [ view-mode · search · sort&view (grid) · overflow ].
      appBar: _selectionMode
          ? AppBar(
              backgroundColor: AppColors.darkSurface,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              ),
              title: Text(
                AppStrings.of(context).selectedCount(_selected.length),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: AppStrings.of(context).selectAll,
                  onPressed: _selectAllVisible,
                ),
                IconButton(
                  icon: const Icon(Icons.drive_file_move_outline),
                  tooltip: AppStrings.of(context).moveSelected,
                  onPressed: _selected.isEmpty ? null : _batchMove,
                ),
                IconButton(
                  icon: const Icon(Icons.lock_open),
                  tooltip: AppStrings.of(context).unlockSelected,
                  onPressed: _selected.isEmpty ? null : _batchUnlock,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: AppColors.error),
                  tooltip: AppStrings.of(context).deleteSelected,
                  onPressed: _selected.isEmpty ? null : _batchDelete,
                ),
              ],
            )
          : _searching
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() {
                  _searching = false;
                  _query = '';
                  _searchCtrl.clear();
                }),
              ),
              title: TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: AppStrings.of(context).searchFilesHint,
                  hintStyle: const TextStyle(color: AppColors.white40),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              actions: [
                if (_query.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _query = '';
                      _searchCtrl.clear();
                    }),
                  ),
              ],
            )
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              // In a subfolder the ← pops back to root; otherwise the
              // default back button leaves the Private Folder screen.
              leading: (_unlocked && _openFolderId != null)
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() => _openFolderId = null),
                    )
                  : null,
              title: (_unlocked &&
                      _openFolderId == null &&
                      _entries.isNotEmpty)
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          AppStrings.of(context).foldersTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          AppStrings.of(context).vaultStorageUsed(
                              _humanSize(_totalVaultBytes)),
                          style: const TextStyle(
                            color: AppColors.white55,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      _openFolderId != null
                          ? _folderName(_openFolderId!)
                          : (_unlocked
                              ? AppStrings.of(context).foldersTitle
                              : AppStrings.of(context).privateFolder),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
              actions: [
                if (_unlocked && !_checking) ...[
                  // 1) View-mode cycle — the SAME action as Local's button
                  //    (allFolders → files → folders), using Local's
                  //    _viewModeIcon glyphs and the shared preferences.
                  Consumer(builder: (ctx, r, _) {
                    final vm = r.watch(privateFolderPreferencesProvider).viewMode;
                    return IconButton(
                      icon: Icon(_viewModeIcon(vm)),
                      tooltip:
                          '${AppStrings.of(context).viewModeLabel}: ${vm.label}',
                      onPressed: () => r
                          .read(privateFolderPreferencesProvider.notifier)
                          .cycleViewMode(),
                    );
                  }),
                  // 2) Search.
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: AppStrings.of(context).searchFilesHint,
                    onPressed: () => setState(() => _searching = true),
                  ),
                  // 3) Sort & view — same dialog UI as Local, but driven by
                  //    the Private Folder's OWN isolated preferences so it
                  //    never changes the public Local tab's layout.
                  IconButton(
                    icon: const Icon(Icons.dashboard_outlined),
                    tooltip: AppStrings.of(context).sortAndView,
                    onPressed: () => SortViewDialog.show(context,
                        preferencesProvider:
                            privateFolderPreferencesProvider),
                  ),
                  // 4) Overflow — New folder · Refresh · Lock · Change PIN.
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: AppStrings.of(context).moreOptions,
                    color: AppColors.darkSurface,
                    onSelected: (v) async {
                      switch (v) {
                        case 'lock':
                          setState(() => _unlocked = false);
                          break;
                        case 'change_pin':
                          _changePin();
                          break;
                        case 'recovery':
                          _withoutAutoLock(() =>
                              Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) =>
                                      const RecoverySetupScreen())));
                          break;
                        case 'antitheft':
                          // Anti-theft requests the CAMERA permission when
                          // break-in capture is switched on. That dialog is
                          // an `inactive`, and without this the vault locked
                          // itself while the user was granting it.
                          _withoutAutoLock(() =>
                              Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) =>
                                      AntiTheftScreen(service: _svc))));
                          break;
                        case 'new_folder':
                          _createFolder();
                          break;
                        case 'refresh':
                          await _reload();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                    AppStrings.of(context).refreshingVault),
                                duration: const Duration(seconds: 1)));
                          }
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'new_folder',
                        child: Row(children: [
                          const Icon(Icons.create_new_folder_outlined,
                              size: 20, color: Colors.white70),
                          const SizedBox(width: 12),
                          Text(AppStrings.of(context).newFolder,
                              style: const TextStyle(color: Colors.white)),
                        ]),
                      ),
                      PopupMenuItem(
                        value: 'refresh',
                        child: Row(children: [
                          const Icon(Icons.refresh,
                              size: 20, color: Colors.white70),
                          const SizedBox(width: 12),
                          Text(AppStrings.of(context).refresh,
                              style: const TextStyle(color: Colors.white)),
                        ]),
                      ),
                      if (_hasPin)
                        PopupMenuItem(
                          value: 'lock',
                          child: Row(children: [
                            const Icon(Icons.lock_outline,
                                size: 20, color: Colors.white70),
                            const SizedBox(width: 12),
                            Text(AppStrings.of(context).lock,
                                style: const TextStyle(color: Colors.white)),
                          ]),
                        ),
                      if (!_decoyMode)
                        PopupMenuItem(
                          value: 'change_pin',
                          child: Row(children: [
                            const Icon(Icons.password_outlined,
                                size: 20, color: Colors.white70),
                            const SizedBox(width: 12),
                            Text(AppStrings.of(context).changePin,
                                style: const TextStyle(color: Colors.white)),
                          ]),
                        ),
                      if (!_decoyMode)
                        PopupMenuItem(
                          value: 'recovery',
                          child: Row(children: [
                            const Icon(Icons.restore,
                                size: 20, color: Colors.white70),
                            const SizedBox(width: 12),
                            Text(AppStrings.of(context).recoveryOptions,
                                style: const TextStyle(color: Colors.white)),
                          ]),
                        ),
                      if (!_decoyMode)
                        PopupMenuItem(
                          value: 'antitheft',
                          child: Row(children: [
                            const Icon(Icons.security,
                                size: 20, color: Colors.white70),
                            const SizedBox(width: 12),
                            Text(AppStrings.of(context).antiTheft,
                                style: const TextStyle(color: Colors.white)),
                          ]),
                        ),
                    ],
                  ),
                ],
              ],
            ),
      // FAB rule (v0.51.5): the Video category shows a Resume FAB — like
      // Local's — that resumes the last-watched VAULT video (privacy-safe:
      // it never touches public history). Every other category (All /
      // Image / Audio / File) keeps the Private-Folder-only "+" FAB that
      // opens the picker.
      floatingActionButton: (_unlocked && _hasPin && !_checking)
          ? (_cat == _VaultCat.video
              ? FloatingActionButton(
                  backgroundColor: AppColors.specPrimary,
                  tooltip: AppStrings.of(context).resumeVault,
                  onPressed: _resumeLastVaultVideo,
                  child: const Icon(Icons.play_arrow, color: Colors.white),
                )
              : FloatingActionButton(
                  backgroundColor: AppColors.specPrimary,
                  tooltip: AppStrings.of(context).addFiles,
                  onPressed: _openAddFiles,
                  child: const Icon(Icons.add, color: Colors.white),
                ))
          : null,
      // Category filter as a nav-style bottom bar (req #3).
      bottomNavigationBar: _selectionMode ? null : _categoryNavBar(),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : !_hasPin
              ? _SetPinPanel(
                  onPinSet: () async {
                    setState(() => _hasPin = true);
                    await _onUnlocked();
                    // First-run: gently prompt the user to set up a
                    // recovery method so a forgotten PIN isn't fatal.
                    if (mounted) await _maybePromptRecoverySetup();
                  },
                )
              : !_unlocked
                  ? _PinEntryPanel(onUnlocked: _onUnlocked)
                  : _buildContents(),
      ),
      ),
    );
  }

  // ── v0.51 file-manager contents ───────────────────────────────────
  // The category filter now lives in a bottom nav-style bar (see
  // _categoryNavBar, wired as the Scaffold's bottomNavigationBar), so the
  // body is just the manager list/grid — mirroring how Local fills the
  // space between its top toolbar and the shell's bottom tabs.
  Widget _buildContents() {
    return _managerBody();
  }

  String _folderName(String id) {
    final f = _folders.where((f) => f.id == id);
    return f.isEmpty ? AppStrings.of(context).mainFolder : f.first.name;
  }

  /// Bottom category bar, styled to echo the shell nav bar (All · Video ·
  /// Image · Audio · File). Only shown while unlocked & browsing.
  Widget? _categoryNavBar() {
    if (!_unlocked || _checking || !_hasPin) return null;
    final s = AppStrings.of(context);
    final items = <(_VaultCat, IconData, String)>[
      (_VaultCat.all, Icons.apps, s.catAll),
      (_VaultCat.video, Icons.movie_outlined, s.catVideos),
      (_VaultCat.image, Icons.image_outlined, s.catImages),
      (_VaultCat.audio, Icons.music_note_outlined, s.catAudio),
      (_VaultCat.file, Icons.insert_drive_file_outlined, s.catFiles),
    ];
    final idx = items.indexWhere((e) => e.$1 == _cat);
    return BottomNavigationBar(
      currentIndex: idx < 0 ? 0 : idx,
      backgroundColor: AppColors.specNavBar,
      elevation: 0,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: AppColors.specPrimary,
      unselectedItemColor: AppColors.specNavInactive,
      iconSize: 28,
      selectedFontSize: 13,
      unselectedFontSize: 12,
      showUnselectedLabels: true,
      onTap: (i) => setState(() => _cat = items[i].$1),
      items: [
        for (final (_, icon, label) in items)
          BottomNavigationBarItem(icon: Icon(icon), label: label),
      ],
    );
  }

  // (legacy top category strip — retained but unused; the nav-style bar
  //  above replaced it.)
  Widget _categoryBar() {
    final s = AppStrings.of(context);
    final items = <(_VaultCat, IconData, String)>[
      (_VaultCat.all, Icons.apps, s.catAll),
      (_VaultCat.video, Icons.movie_outlined, s.catVideos),
      (_VaultCat.image, Icons.image_outlined, s.catImages),
      (_VaultCat.audio, Icons.music_note_outlined, s.catAudio),
      (_VaultCat.file, Icons.insert_drive_file_outlined, s.catFiles),
    ];
    return Container(
      height: 46,
      color: AppColors.darkBackground,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final (cat, icon, label) = items[i];
          final active = _cat == cat;
          return GestureDetector(
            onTap: () => setState(() => _cat = cat),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active
                    ? AppColors.accentBlue.withOpacity(0.16)
                    : Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: active ? AppColors.accentBlue : Colors.white12),
              ),
              child: Row(
                children: [
                  Icon(icon,
                      size: 16,
                      color:
                          active ? AppColors.accentBlue : AppColors.white55),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                        color: active ? Colors.white : AppColors.white70,
                        fontSize: 13.5,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w400,
                      )),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The entries visible right now: filtered by open folder, category and
  /// search query, then sorted per the shared LibraryPreferences.
  List<PrivateEntry> _visibleEntries() {
    Iterable<PrivateEntry> list = _entries;
    // Folder scope:
    //  • Inside a folder → only that folder's entries.
    //  • At the root with the All category → only unfiled entries
    //    (organiser folders render as their own tiles above the list).
    //  • At the root with a specific category (Video/Image/Audio/File) →
    //    EVERY matching entry regardless of folder, so a video tucked into
    //    a folder still shows up under the Video tab (mirrors how Local's
    //    category filter reaches across folders). This is the fix for
    //    "files inside a folder don't appear in their category tab".
    if (_openFolderId != null) {
      list = list.where((e) => e.folderId == _openFolderId);
    } else if (_cat == _VaultCat.all) {
      list = list.where((e) => e.folderId == null);
    }
    // else: root + specific category → no folder filter (span everything).
    if (_cat != _VaultCat.all) {
      list = list.where((e) => _catOf(e) == _cat);
    }
    if (_query.trim().isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((e) => e.videoTitle.toLowerCase().contains(q));
    }
    final out = list.toList();
    final prefs = ref.read(privateFolderPreferencesProvider);
    out.sort((a, b) {
      int c;
      // Vault entries only carry title / date-added / size, so the
      // video-only fields (resolution, frame rate, length, played time,
      // status) gracefully fall back to title order — the sort UI still
      // offers every Local field for parity, they just have no data to
      // act on for a mixed-content vault.
      switch (prefs.sortBy) {
        case SortBy.title:
        case SortBy.type:
        case SortBy.path:
        case SortBy.status:
        case SortBy.resolution:
        case SortBy.frameRate:
        case SortBy.length:
        case SortBy.playedTime:
          c = a.videoTitle
              .toLowerCase()
              .compareTo(b.videoTitle.toLowerCase());
          break;
        case SortBy.size:
          c = _entrySize(a).compareTo(_entrySize(b));
          break;
        case SortBy.date:
          c = a.addedAt.compareTo(b.addedAt);
          break;
      }
      return c;
    });
    // newestFirst = descending for the fields where that reads naturally.
    if (prefs.direction == SortDirection.newestFirst) {
      return out.reversed.toList();
    }
    return out;
  }

  // Verbatim from Local's LocalScreen._viewModeIcon — identical glyphs so
  // the toolbar button matches Local exactly across all three view modes.
  IconData _viewModeIcon(ViewMode mode) {
    switch (mode) {
      case ViewMode.allFolders:
        return Icons.folder_copy_outlined;
      case ViewMode.files:
        return Icons.description_outlined;
      case ViewMode.folders:
        return Icons.folder_outlined;
    }
  }

  /// Cached size for an entry. Returns 0 for anything not yet measured
  /// rather than reaching for the disk: [_measureSizes] fills this map
  /// asynchronously after every load, so a miss here means "not measured
  /// yet", and a blocking stat during layout is never the right way to
  /// resolve it. A newly-added file shows 0 bytes for a fraction of a second
  /// and then corrects itself — far cheaper than a janked frame per file.
  int _entrySize(PrivateEntry e) => _sizeCache[e.playablePath] ?? 0;

  /// Sum of all vaulted file sizes — shown as a small storage indicator so
  /// the user can see how much space the vault occupies.
  int get _totalVaultBytes {
    var sum = 0;
    for (final e in _entries) {
      sum += _entrySize(e);
    }
    return sum;
  }

  static String _humanSize(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  _VaultCat _catOf(PrivateEntry e) {
    switch (_kindOf(e.playablePath)) {
      case 'video':
        return _VaultCat.video;
      case 'image':
        return _VaultCat.image;
      case 'audio':
        return _VaultCat.audio;
      default:
        return _VaultCat.file;
    }
  }

  Widget _managerBody() {
    final entries = _visibleEntries();
    final prefs = ref.watch(privateFolderPreferencesProvider);
    // Organiser folders show only in a "folders" view mode, at the root,
    // in the All category, with no active search — mirroring how Local's
    // folders view behaves. In "files" / "allFolders" the vault shows a
    // flat entry list.
    final showFolders = prefs.viewMode == ViewMode.folders &&
        _openFolderId == null &&
        _cat == _VaultCat.all &&
        _query.isEmpty;

    if (entries.isEmpty && (!showFolders || _folders.isEmpty)) {
      return _emptyState();
    }

    if (prefs.layout == LayoutMode.grid) {
      return _gridBody(entries, showFolders);
    }
    return _listBody(entries, showFolders);
  }

  Widget _listBody(List<PrivateEntry> entries, bool showFolders) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 90),
      children: [
        if (showFolders && _folders.isNotEmpty) ...[
          for (final f in _folders) _folderTile(f),
          const Divider(height: 0, color: AppColors.darkDivider),
        ],
        for (final e in entries) _entryTile(e),
      ],
    );
  }

  Widget _gridBody(List<PrivateEntry> entries, bool showFolders) {
    return GridView.count(
      crossAxisCount: 3,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 90),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        if (showFolders)
          for (final f in _folders) _folderCell(f),
        for (final e in entries) _entryCell(e),
      ],
    );
  }

  Widget _folderTile(PrivateFolderMeta f) {
    return ListTile(
      leading: const Icon(Icons.folder, color: AppColors.accentBlue),
      title: Text(f.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 14)),
      subtitle: Text(
        AppStrings.of(context)
            .itemsCount(_entries.where((e) => e.folderId == f.id).length),
        style: const TextStyle(color: AppColors.white55, fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert,
            color: AppColors.darkOnSurfaceMuted, size: 20),
        onPressed: () => _folderMenu(f),
      ),
      onTap: () => setState(() => _openFolderId = f.id),
    );
  }

  Widget _folderCell(PrivateFolderMeta f) {
    return GestureDetector(
      onTap: () => setState(() => _openFolderId = f.id),
      onLongPress: () => _folderMenu(f),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder, color: AppColors.accentBlue, size: 42),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(PrivateEntry e) {
    final kind = _kindOf(e.playablePath);
    final selected = _selected.contains(e.videoUri);
    return ListTile(
      selected: selected,
      selectedTileColor: AppColors.accentBlue.withOpacity(0.12),
      leading: _selectionMode
          ? Icon(
              selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              color: selected ? AppColors.accentBlue : AppColors.white40,
            )
          : ((kind == 'image' || kind == 'video')
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: kind == 'image'
                        ? Image.file(File(e.playablePath),
                            fit: BoxFit.cover,
                            cacheWidth: 120,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.image_outlined,
                                color: AppColors.accentBlue))
                        : Container(
                            color: AppColors.specSurface,
                            child: const Icon(Icons.movie_outlined,
                                color: AppColors.accentBlue)),
                  ),
                )
              : Icon(_iconFor(kind), color: AppColors.accentBlue)),
      title: Text(e.videoTitle,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: _selectionMode
          ? null
          : IconButton(
              icon: const Icon(Icons.more_vert,
                  color: AppColors.darkOnSurfaceMuted, size: 20),
              onPressed: () => _entryMenu(e),
            ),
      onTap: () => _selectionMode
          ? _toggleSelected(e)
          : _openEntry(e, kind),
      onLongPress: () => _selectionMode ? null : _enterSelection(e),
    );
  }

  Widget _entryCell(PrivateEntry e) {
    final kind = _kindOf(e.playablePath);
    final selected = _selected.contains(e.videoUri);
    return GestureDetector(
      onTap: () =>
          _selectionMode ? _toggleSelected(e) : _openEntry(e, kind),
      onLongPress: () =>
          _selectionMode ? null : _enterSelection(e),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: AppColors.specSurface),
            // Only images decode to a thumbnail. Videos/others show their
            // type icon directly — trying to decode a video file as an
            // image just fails into the errorBuilder, wasting a decode
            // attempt per cell on every rebuild.
            if (kind == 'image')
              Image.file(File(e.playablePath),
                  fit: BoxFit.cover,
                  cacheWidth: 240,
                  errorBuilder: (_, __, ___) =>
                      Icon(_iconFor(kind), color: AppColors.accentBlue))
            else
              Center(
                  child: Icon(_iconFor(kind),
                      color: AppColors.accentBlue, size: 34)),
            if (kind == 'video')
              const Positioned(
                left: 4,
                bottom: 4,
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 20),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black.withOpacity(0.45),
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(e.videoTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10)),
              ),
            ),
            if (_selectionMode) ...[
              Container(
                color: selected
                    ? AppColors.accentBlue.withOpacity(0.28)
                    : Colors.black.withOpacity(0.25),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: selected ? AppColors.accentBlue : Colors.white,
                  size: 22,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    final inFolder = _openFolderId != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(inFolder ? Icons.folder_open : Icons.lock_outline,
                color: AppColors.white40, size: 56),
            const SizedBox(height: 16),
            Text(
              inFolder
                  ? AppStrings.of(context).emptyFolder
                  : AppStrings.of(context).emptyFolder,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.white55, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  // ── sort / folder / entry actions ─────────────────────────────────


  Future<void> _createFolder() async {
    final name = await _promptName(
        AppStrings.of(context).createFolderTitle, '');
    if (name == null || name.trim().isEmpty) return;
    // Decoy mode: create the folder only in memory so it looks real but
    // never persists or touches the hidden vault.
    if (_decoyMode) {
      setState(() {
        _folders.add(PrivateFolderMeta(
          id: 'decoy_${DateTime.now().microsecondsSinceEpoch}',
          name: name.trim(),
          createdAt: DateTime.now(),
        ));
      });
      return;
    }
    await _svc.createFolder(name);
    await _reload();
  }

  Future<void> _folderMenu(PrivateFolderMeta f) async {
    final s = AppStrings.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.drive_file_rename_outline, color: Colors.white),
              title: Text(s.rename,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.white),
              title: Text(s.delete,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') {
      final name = await _promptName(s.renameFolderTitle, f.name);
      if (name != null && name.trim().isNotEmpty) {
        final trimmed = name.trim();
        if (_decoyEdit(() {
          final i = _folders.indexWhere((x) => x.id == f.id);
          if (i >= 0) _folders[i] = _folders[i].copyWith(name: trimmed);
        })) {
          return;
        }
        await _svc.renameFolder(f.id, trimmed);
        await _reload();
      }
    } else if (action == 'delete') {
      await _confirmDeleteFolder(f);
    }
  }

  /// Folder-delete confirmation. An empty folder just deletes. A folder
  /// WITH files offers a clear choice: keep the files (they move back to
  /// the main vault, still locked) and only remove the folder, OR delete
  /// the folder together with everything inside it (permanent erase).
  Future<void> _confirmDeleteFolder(PrivateFolderMeta f) async {
    final s = AppStrings.of(context);
    final count = await _svc.folderItemCount(f.id);
    if (!mounted) return;

    // Empty folder → simple confirm.
    if (count == 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.darkSurface,
          title: Text(s.deleteFolderTitle,
              style: const TextStyle(color: Colors.white, fontSize: 16)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.cancel)),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.delete,
                    style: const TextStyle(color: AppColors.error))),
          ],
        ),
      );
      if (ok == true) {
        if (_decoyEdit(() {
          _folders.removeWhere((x) => x.id == f.id);
          for (var i = 0; i < _entries.length; i++) {
            if (_entries[i].folderId == f.id) {
              _entries[i] = _entries[i].copyWith(clearFolder: true);
            }
          }
        })) {
          return;
        }
        await _svc.deleteFolder(f.id);
        await _reload();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(s.folderDeleted),
              duration: const Duration(seconds: 2)));
        }
      }
      return;
    }

    // Non-empty folder → choice dialog (keep files vs delete everything).
    final choice = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.deleteFolderWithItemsTitle(count),
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.deleteFolderChoiceBody(count),
                style:
                    const TextStyle(color: AppColors.white70, fontSize: 13)),
            const SizedBox(height: 16),
            // Option 1: keep files, delete folder only.
            InkWell(
              onTap: () => Navigator.pop(dCtx, 'keep'),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 4),
                child: Row(
                  children: [
                    const Icon(Icons.drive_file_move_outline,
                        color: AppColors.accentBlue, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.unlockAndDeleteFolder,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                          Text(s.unlockAndDeleteFolderSub,
                              style: const TextStyle(
                                  color: AppColors.white55, fontSize: 11.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 8, color: AppColors.darkDivider),
            // Option 2: delete folder AND files (destructive).
            InkWell(
              onTap: () => Navigator.pop(dCtx, 'all'),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 4),
                child: Row(
                  children: [
                    const Icon(Icons.delete_forever,
                        color: AppColors.error, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.deleteFolderAndFiles,
                              style: const TextStyle(
                                  color: AppColors.error,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                          Text(s.deleteFolderAndFilesSub,
                              style: const TextStyle(
                                  color: AppColors.white55, fontSize: 11.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: Text(s.cancel)),
        ],
      ),
    );
    if (choice != 'keep' && choice != 'all') return;
    // Decoy session: apply to the in-memory list only. "Keep files" unfiles
    // them; "delete everything" removes them from the fake list. Both look
    // exactly like the real thing and write nothing.
    if (_decoyEdit(() {
      _folders.removeWhere((x) => x.id == f.id);
      if (choice == 'all') {
        _entries.removeWhere((x) => x.folderId == f.id);
      } else {
        for (var i = 0; i < _entries.length; i++) {
          if (_entries[i].folderId == f.id) {
            _entries[i] = _entries[i].copyWith(clearFolder: true);
          }
        }
      }
    })) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(s.folderDeleted),
            duration: const Duration(seconds: 2)));
      }
      return;
    }
    if (choice == 'keep') {
      await _svc.deleteFolder(f.id);
    } else {
      await _svc.deleteFolderWithContents(f.id);
    }
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.folderDeleted),
          duration: const Duration(seconds: 2)));
    }
  }

  Future<void> _entryMenu(PrivateEntry e) async {
    final s = AppStrings.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(e.videoTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline,
                  color: Colors.white),
              title: Text(AppStrings.of(context).renameEntry,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.drive_file_move_outline, color: Colors.white),
              title: Text(s.moveToFolder,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.share, color: Colors.white),
              title:
                  Text(s.shareFile, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_open, color: Colors.white),
              title: Text(s.unlockToLibrary,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, 'unlock'),
            ),
            const Divider(height: 0, color: AppColors.darkDivider),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: AppColors.error),
              title: Text(s.deletePermanently,
                  style: const TextStyle(color: AppColors.error)),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'rename') {
      await _renameEntryDialog(e);
    } else if (action == 'move') {
      await _moveEntryDialog(e);
    } else if (action == 'share') {
      try {
        await Share.shareXFiles([XFile(e.playablePath)]);
      } catch (err) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '${AppStrings.of(context).shareFailed}: $err')));
        }
      }
    } else if (action == 'unlock') {
      _remove(e);
    } else if (action == 'delete') {
      await _deleteEntryPermanently(e);
    }
  }

  // ── batch operations (multi-select) ──────────────────────────────
  /// Select every entry currently visible (respects folder/category/
  /// search filters — you can't accidentally select hidden items).
  void _selectAllVisible() {
    final visible = _visibleEntries();
    setState(() {
      if (_selected.length == visible.length && visible.isNotEmpty) {
        // Already all selected → toggle off.
        _selected.clear();
        _selectionMode = false;
      } else {
        _selected
          ..clear()
          ..addAll(visible.map((e) => e.videoUri));
      }
    });
  }

  List<PrivateEntry> _selectedEntries() =>
      _entries.where((e) => _selected.contains(e.videoUri)).toList();

  Future<void> _batchMove() async {
    if (_busy) return;
    final entries = _selectedEntries();
    if (entries.isEmpty) return;
    final target = await _chooseFolderForBatch();
    if (target == _kBatchCancelled) return;
    final folderId = target == _kBatchRoot ? null : target;
    final uris = entries.map((e) => e.videoUri).toSet();
    if (_decoyEdit(() {
      for (var i = 0; i < _entries.length; i++) {
        if (uris.contains(_entries[i].videoUri)) {
          _entries[i] = _entries[i]
              .copyWith(folderId: folderId, clearFolder: folderId == null);
        }
      }
      _exitSelectionInline();
    })) {
      return;
    }
    _busy = true;
    try {
      await _svc.moveEntries(uris, folderId);
      await _reload();
      if (!mounted) return;
      setState(_exitSelectionInline);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(AppStrings.of(context).itemsMovedFolder(entries.length)),
          duration: const Duration(seconds: 2)));
    } finally {
      _busy = false; // never leave the guard stuck, even on error/unmount
    }
  }

  Future<void> _batchUnlock() async {
    if (_busy) return;
    final entries = _selectedEntries();
    if (entries.isEmpty) return;
    final uris = entries.map((e) => e.videoUri).toSet();
    if (_decoyEdit(() {
      _entries.removeWhere((x) => uris.contains(x.videoUri));
      _exitSelectionInline();
    })) {
      return;
    }
    _busy = true;
    // Restoring is a real file COPY out of the vault, one file at a time and
    // potentially gigabytes of it. Two things were wrong here: nothing told
    // the user it was happening, and nothing caught a failure. An integrity
    // check failing on file three threw straight out of the loop — files
    // four onward were silently skipped, the list never refreshed, and the
    // user was shown nothing at all. Now every file is attempted, failures
    // are counted, and the result is reported honestly.
    var ok = 0;
    var failed = 0;
    final progress = VaultProgressController(
      total: entries.length,
      title: AppStrings.of(context).unlockingFiles,
    );
    // NOT awaited: showDialog completes only when the sheet closes, and this
    // method is what closes it. Awaiting here would deadlock the batch.
    unawaited(showVaultProgressSheet(context, progress));
    try {
      for (var i = 0; i < entries.length; i++) {
        if (progress.cancelled) break;
        progress.beginItem(i, entries[i].videoTitle);
        try {
          await _svc.restoreFromVault(
            entries[i],
            onProgress: progress.onBytes,
            isCancelled: () => progress.cancelled,
          );
          ok++;
        } on VaultCancelled {
          break;
        } catch (err) {
          failed++;
          if (kDebugMode) debugPrint('private_folder.batchUnlock: $err');
        }
      }
    } finally {
      _busy = false;
      progress.finish();
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    // The loop above can run for minutes on a large restore, and the user is
    // free to leave while it does. Riverpod's `ref` dies with the State
    // exactly like `context` does, so touching it here without a guard throws
    // "Cannot use ref functions after the dependency was disposed" — a crash
    // whose likelihood rises with the size of the batch.
    if (!mounted) return;
    ref.invalidate(privateFolderUrisProvider);
    await _reload();
    if (!mounted) return;
    setState(_exitSelectionInline);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed > 0
            ? AppStrings.of(context).someFilesFailed(failed)
            : AppStrings.of(context).itemsUnlocked(ok)),
        duration: const Duration(seconds: 2)));
  }

  Future<void> _batchDelete() async {
    final entries = _selectedEntries();
    if (entries.isEmpty) return;
    final s = AppStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.deleteSelectedTitle(entries.length),
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(s.deleteSelectedBody,
            style: const TextStyle(color: AppColors.white70, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text(s.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(s.deleteSelected),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final uris = entries.map((e) => e.videoUri).toSet();
    if (_decoyEdit(() {
      _entries.removeWhere((x) => uris.contains(x.videoUri));
      _exitSelectionInline();
    })) {
      return;
    }
    if (_busy) return;
    _busy = true;
    try {
      await _svc.deleteVaultedBatch(entries);
      await _reload();
      if (!mounted) return;
      setState(_exitSelectionInline);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.fileDeleted),
          duration: const Duration(seconds: 2)));
    } finally {
      _busy = false;
    }
  }

  // Sentinels for the batch folder chooser (root vs cancel — see the
  // single-entry chooser for the same pattern).
  static const String _kBatchCancelled = '__cancel__';
  static const String _kBatchRoot = '__root__';

  Future<String?> _chooseFolderForBatch() async {
    final s = AppStrings.of(context);
    final chosen = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 14),
            Text(s.moveToFolder,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.home_outlined,
                        color: AppColors.accentBlue),
                    title: Text(s.mainFolder,
                        style: const TextStyle(color: Colors.white)),
                    onTap: () => Navigator.pop(sheetCtx, _kBatchRoot),
                  ),
                  for (final f in _folders)
                    ListTile(
                      leading: const Icon(Icons.folder,
                          color: AppColors.accentBlue),
                      title: Text(f.name,
                          style: const TextStyle(color: Colors.white)),
                      onTap: () => Navigator.pop(sheetCtx, f.id),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    return chosen ?? _kBatchCancelled;
  }

  void _exitSelectionInline() {
    _selectionMode = false;
    _selected.clear();
    _busy = false; // batch op finished
  }

  Future<void> _renameEntryDialog(PrivateEntry e) async {
    final c = TextEditingController(text: e.videoTitle);
    final s = AppStrings.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.renameEntryTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: s.entryNameHint,
            hintStyle: const TextStyle(color: AppColors.white40),
          ),
          onSubmitted: (_) => Navigator.pop(dCtx, c.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: Text(s.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, c.text),
              child: Text(s.rename)),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final trimmed = name.trim();
    if (_decoyEdit(() {
      final i = _entries.indexWhere((x) => x.videoUri == e.videoUri);
      if (i >= 0) _entries[i] = _entries[i].copyWith(videoTitle: trimmed);
    })) {
      return;
    }
    await _svc.renameEntry(e.videoUri, trimmed);
    await _reload();
  }

  /// Permanently delete a vaulted file (destructive — the file is erased
  /// from the vault and cannot be recovered). Gated behind a confirm
  /// dialog because, unlike Unlock, there is no way back.
  Future<void> _deleteEntryPermanently(PrivateEntry e) async {
    final s = AppStrings.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.deletePermanentlyTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(s.deletePermanentlyBody,
            style: const TextStyle(color: AppColors.white70, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: Text(s.deletePermanently),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_decoyEdit(() =>
        _entries.removeWhere((x) => x.videoUri == e.videoUri))) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(s.fileDeleted),
            duration: const Duration(seconds: 2)));
      }
      return;
    }
    await ref.read(privateFolderServiceProvider).deleteVaulted(e);
    if (!mounted) return;
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.fileDeleted),
          duration: const Duration(seconds: 2)));
    }
  }

  Future<void> _moveEntryDialog(PrivateEntry e) async {
    final s = AppStrings.of(context);
    final target = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(s.chooseFolder,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined,
                  color: AppColors.accentBlue),
              title: Text(s.mainFolder,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, '__root__'),
            ),
            for (final f in _folders)
              ListTile(
                leading:
                    const Icon(Icons.folder, color: AppColors.accentBlue),
                title: Text(f.name,
                    style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context, f.id),
              ),
            const Divider(height: 0, color: AppColors.darkDivider),
            ListTile(
              leading:
                  const Icon(Icons.create_new_folder_outlined, color: Colors.white),
              title: Text(s.newFolder,
                  style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(context, '__new__'),
            ),
          ],
        ),
      ),
    );
    if (target == null) return;
    String? folderId;
    if (target == '__root__') {
      folderId = null;
    } else if (target == '__new__') {
      final name = await _promptName(s.createFolderTitle, '');
      if (name == null || name.trim().isEmpty) return;
      if (_decoyMode) {
        // A decoy session must never create a real folder. Mint a
        // memory-only id with the same shape the real one would have.
        folderId = 'decoy_${DateTime.now().microsecondsSinceEpoch}';
        setState(() => _folders.add(PrivateFolderMeta(
              id: folderId!,
              name: name.trim(),
              createdAt: DateTime.now(),
            )));
      } else {
        final meta = await _svc.createFolder(name);
        folderId = meta.id;
      }
    } else {
      folderId = target;
    }
    final destination = folderId;
    if (_decoyEdit(() {
      final i = _entries.indexWhere((x) => x.videoUri == e.videoUri);
      if (i >= 0) {
        _entries[i] = _entries[i].copyWith(
            folderId: destination, clearFolder: destination == null);
      }
    })) {
      return;
    }
    await _svc.moveEntry(e.videoUri, destination);
    await _reload();
  }

  Future<String?> _promptName(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    final s = AppStrings.of(context);
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: s.folderName,
            hintStyle: const TextStyle(color: AppColors.white40),
            enabledBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.white20)),
            focusedBorder: const UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.accentBlue)),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(s.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: Text(s.done)),
        ],
      ),
    );
  }


  // ── v0.50 typed-vault helpers ─────────────────────────────────────
  static const Set<String> _vidExts = {
    '.mp4', '.mkv', '.webm', '.mov', '.avi', '.3gp', '.m4v', '.ts', '.flv',
    '.wmv'
  };
  static const Set<String> _imgExts = {
    '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.heic', '.heif'
  };
  static const Set<String> _audExts = {
    '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.wma', '.amr'
  };

  String _kindOf(String path) {
    final e = pth.extension(path).toLowerCase();
    if (_vidExts.contains(e)) return 'video';
    if (_imgExts.contains(e)) return 'image';
    if (_audExts.contains(e)) return 'audio';
    return 'other';
  }

  IconData _iconFor(String kind) {
    switch (kind) {
      case 'video':
        return Icons.movie_outlined;
      case 'image':
        return Icons.image_outlined;
      case 'audio':
        return Icons.music_note_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  /// Resume the most-recently-watched VAULT video that still has a saved
  /// playback position. Privacy-safe: it only ever looks at vault entries
  /// and their resume positions — never the public history — so nothing
  /// outside the folder is exposed. Falls back to the newest video entry
  /// if none has a mid-way position, and shows a hint if there are no
  /// videos at all.
  Future<void> _resumeLastVaultVideo() async {
    final videos = _entries
        .where((e) => _kindOf(e.playablePath) == 'video')
        .toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    if (videos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppStrings.of(context).nothingToResume),
          duration: const Duration(seconds: 2)));
      return;
    }
    final resume = ref.read(resumeStorageProvider);
    PrivateEntry? best;
    for (final e in videos) {
      final pos = await resume.getPosition(e.playablePath);
      if (pos != null && pos.inSeconds > 3) {
        best = e; // videos are newest-first, so the first hit is the one
        break;
      }
    }
    best ??= videos.first;
    if (!mounted) return;
    _openEntry(best, 'video');
  }

  void _openEntry(PrivateEntry e, String kind) {
    // A vaulted file can go missing (storage corruption, app-data partly
    // cleared). Launching the player on a dead path would show a black
    // screen or a cryptic decoder error — check first and tell the user
    // plainly instead. Legacy soft-hide entries (no vaultPath) point at
    // the original URI and are exempt from this local-file check.
    if (e.vaultPath != null && !File(e.vaultPath!).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppStrings.of(context).vaultFileMissing),
          duration: const Duration(seconds: 3)));
      return;
    }
    switch (kind) {
      case 'video':
      case 'audio':
        // media_kit plays audio files through the same pipeline.
        // isPrivate:true → the player suppresses background play / PiP and
        // pauses the instant the app is backgrounded, so a vault video is
        // never audible or visible outside the unlocked folder.
        context.push(
          Routes.player,
          extra: {
            'uri': e.playablePath,
            'title': e.videoTitle,
            'isPrivate': true,
          },
        );
        break;
      case 'image':
        showDialog(
          context: context,
          barrierColor: Colors.black,
          builder: (_) => _VaultImageViewer(
              path: e.playablePath, title: e.videoTitle),
        );
        break;
      default:
        _showOtherFileSheet(e);
    }
  }

  void _showOtherFileSheet(PrivateEntry e) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) {
        final s = AppStrings.of(sheetCtx);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 14),
              Text(e.videoTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              ListTile(
                leading:
                    const Icon(Icons.share, color: AppColors.accentBlue),
                title: Text(s.shareFile,
                    style: const TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  try {
                    // The share sheet is another app's surface over ours.
                    await _withoutAutoLock(
                        () => Share.shareXFiles([XFile(e.playablePath)]));
                  } catch (err) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(
                            AppStrings.of(context).shareFailed +
                                ': ' + err.toString())));
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.lock_open,
                    color: AppColors.accentBlue),
                title: Text(s.unlockToLibrary,
                    style: const TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _remove(e);
                },
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }
}
