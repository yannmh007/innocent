import 'package:flutter/material.dart';

import '../../../core/localization/app_strings.dart';
import '../data/net_repository.dart';
import '../data/net_server.dart';
import 'net_widgets.dart';

/// A [NetFailure] as one sentence a person can act on.
String netErrorText(BuildContext context, NetFailure f, NetServer server) {
  final s = AppStrings.of(context);
  switch (f.code) {
    case 'unreachable':
      return s.netErrUnreachable(server.host);
    case 'timeout':
      return s.netErrTimeout;
    case 'auth':
      return server.anonymous ? s.netErrAuthAnon : s.netErrAuth;
    case 'denied':
      return s.netErrDenied;
    case 'not_found':
      return s.netErrNotFound;
    case 'tls':
      return s.netErrTls;
    case 'bad_key':
      return s.netErrKey;
    case 'hostkey_changed':
      return s.netErrHostKey;
    case 'unsupported':
      return s.netErrUnsupported;
    default:
      return s.netErrProtocol(server.protocol.label);
  }
}

/// The server's key or certificate is not the one it had: ask, with the
/// fingerprints side by side. True = trust the new one.
Future<bool> confirmNewIdentity(
    BuildContext context, NetFailure f, NetServer server) async {
  final s = AppStrings.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => NetDialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.gpp_maybe_rounded,
              color: Color(0xFFFFB74D), size: 30),
          const SizedBox(height: 10),
          Text(s.netErrHostKey,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(s.netErrHostKeyBody,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 13.5, height: 1.45)),
          const SizedBox(height: 12),
          _Fp(label: '−', value: server.pinned ?? '?'),
          _Fp(label: '+', value: f.detail ?? '?'),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child:
                    Text(s.cancel, style: const TextStyle(color: Colors.white)),
              ),
              TextButton(
                key: const ValueKey('net-trust'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(s.netTrustNew,
                    style: const TextStyle(color: Color(0xFFFFB74D))),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  return ok ?? false;
}

class _Fp extends StatelessWidget {
  const _Fp({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        '$label $value',
        style: const TextStyle(
          color: Colors.white60,
          fontFamily: 'monospace',
          fontSize: 11.5,
        ),
      ),
    );
  }
}
