import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/services/diagnostics/crash_diagnostics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/ui/tablet_constrained_width.dart';

/// v1.61 — Settings → Diagnostics.
///
/// Deliberately in English and deliberately not localised: every line in it is
/// a machine-generated Android record that is only ever read by someone
/// debugging, and inventing three translations for "REASON_CRASH_NATIVE" would
/// add work and risk without adding a reader.
///
/// The one button that matters is **Copy report**. Everything on this screen
/// goes to the clipboard as one block, which is what gets pasted into a chat
/// when asking why the app died.
class SettingsDiagnosticsScreen extends StatefulWidget {
  const SettingsDiagnosticsScreen({super.key});

  @override
  State<SettingsDiagnosticsScreen> createState() =>
      _SettingsDiagnosticsScreenState();
}

class _SettingsDiagnosticsScreenState extends State<SettingsDiagnosticsScreen> {
  String? _report;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    String text;
    try {
      text = await CrashDiagnostics.report();
    } catch (e) {
      text = 'Could not build the report: $e';
    }
    if (!mounted) return;
    setState(() {
      _report = text;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    final text = _report;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Diagnostics copied. Paste it into the chat.'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _copy,
        icon: const Icon(Icons.copy_all),
        label: const Text('Copy report'),
      ),
      body: TabletConstrainedWidth(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: [
                  const Card(
                    margin: EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'If the app closed by itself, open this screen straight '
                        'afterwards and tap Copy report.\n\n'
                        'The "process exit history" section is Android telling '
                        'us how the last process ended. The "previous session" '
                        'section is what the app was doing just before that. '
                        'Together they name the cause; separately neither '
                        'does.',
                        style: TextStyle(fontSize: 13, height: 1.4),
                      ),
                    ),
                  ),
                  SelectableText(
                    _report ?? '',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
