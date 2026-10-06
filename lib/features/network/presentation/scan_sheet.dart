import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../data/net_repository.dart';
import '../data/net_server.dart';
import 'net_widgets.dart';

/// MX's Scan: the servers of [protocol] on this Wi-Fi, by name where they
/// say one (NetBIOS, mDNS). Tapping one fills the form.
Future<ScanHit?> showScanSheet(BuildContext context, NetProtocol protocol) {
  return showModalBottomSheet<ScanHit>(
    context: context,
    backgroundColor: NetColors.dialog,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
    builder: (_) => _ScanSheet(protocol: protocol),
  );
}

class _ScanSheet extends ConsumerStatefulWidget {
  const _ScanSheet({required this.protocol});
  final NetProtocol protocol;

  @override
  ConsumerState<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends ConsumerState<_ScanSheet> {
  ScanResult? _result;
  NetFailure? _failure;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final r = await ref.read(netChannelProvider).scan(widget.protocol);
      if (mounted) setState(() => _result = r);
    } on NetFailure catch (f) {
      if (mounted) setState(() => _failure = f);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final p = widget.protocol.label;
    final hits = _result?.hits ?? const <ScanHit>[];
    final h = MediaQuery.sizeOf(context).height;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: h * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
              child: Row(children: <Widget>[
                const Icon(Icons.wifi_find_rounded, color: NetColors.scan),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.netScanTitle,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16.5,
                          fontWeight: FontWeight.w700)),
                ),
                if (!_busy)
                  TextButton(
                    key: const ValueKey('net-scan-again'),
                    onPressed: _run,
                    child: Text(s.netScanAgain,
                        style: const TextStyle(color: NetColors.scan)),
                  ),
              ]),
            ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: Column(children: <Widget>[
                  const LinearProgressIndicator(
                      color: NetColors.scan, backgroundColor: Colors.white10),
                  const SizedBox(height: 12),
                  Text(s.netScanning(p, _result?.subnet ?? 'Wi-Fi'),
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13.5)),
                ]),
              )
            else if (_failure != null)
              _Empty(
                icon: Icons.wifi_off_rounded,
                title: _failure!.code == 'unreachable'
                    ? s.netScanNoWifi
                    : s.netErrTimeout,
              )
            else if (hits.isEmpty)
              _Empty(
                  icon: Icons.search_off_rounded,
                  title: s.netScanNone(p),
                  body: s.netScanNoneHint)
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: hits.length,
                  itemBuilder: (_, i) {
                    final hit = hits[i];
                    final def = widget.protocol.defaultPort;
                    final named = (hit.name ?? '').isNotEmpty;
                    return ListTile(
                      key: ValueKey('net-hit-${hit.ip}'),
                      leading: const Icon(Icons.dns_rounded,
                          color: NetColors.monitor),
                      title: Text(named ? hit.name! : hit.ip,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        '${named ? '${hit.ip}  ·  ' : ''}${widget.protocol.label}${hit.port == def ? '' : ' :${hit.port}'}',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12.5),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded,
                          color: Colors.white38),
                      onTap: () => Navigator.of(context).pop(hit),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, this.body});
  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
      child: Column(children: <Widget>[
        Icon(icon, color: Colors.white38, size: 40),
        const SizedBox(height: 12),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 14.5,
                fontWeight: FontWeight.w600)),
        if (body != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(body!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, fontSize: 13)),
        ],
      ]),
    );
  }
}
