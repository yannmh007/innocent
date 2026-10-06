import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/me/presentation/local_network_screen.dart';
import 'package:innocent/features/network/data/net_repository.dart';
import 'package:innocent/features/network/data/net_server.dart';
import 'package:innocent/features/network/presentation/net_browser_screen.dart';

import 'harness.dart';

/// The native side, answered from memory.
class _FakeChannel extends NetChannel {
  const _FakeChannel({this.fail});
  final String? fail;

  @override
  Future<({String home, String? fingerprint})> connect(Map<String, dynamic> spec) async {
    if (fail != null) throw NetFailure(fail!);
    return (home: '/Movies', fingerprint: null);
  }

  @override
  Future<List<NetEntry>> list(Map<String, dynamic> spec, String path) async {
    const mb = 1024 * 1024;
    final t = DateTime(2026, 9, 30).millisecondsSinceEpoch;
    return <NetEntry>[
      NetEntry(name: 'Season 1', path: '$path/Season 1', dir: true, size: 0, modified: t),
      NetEntry(name: 'Documentaries', path: '$path/Documentaries', dir: true, size: 0, modified: t),
      NetEntry(name: 'The Long Road (2024).mkv', path: '$path/a.mkv', dir: false, size: 2400 * mb, modified: t),
      NetEntry(name: 'The Long Road (2024).srt', path: '$path/a.srt', dir: false, size: 88000, modified: t),
      NetEntry(name: 'ငါ့ဇာတ်ကား.mp4', path: '$path/b.mp4', dir: false, size: 812 * mb, modified: t),
      NetEntry(name: 'Theme song.mp3', path: '$path/c.mp3', dir: false, size: 6 * mb, modified: t),
      NetEntry(name: 'notes.txt', path: '$path/n.txt', dir: false, size: 1200, modified: t),
    ];
  }

  @override
  Future<ScanResult> scan(NetProtocol p) async => const ScanResult('192.168.1.x', <ScanHit>[
        ScanHit('192.168.1.10', 445, 'DESKTOP-7Q2LM'),
        ScanHit('192.168.1.23', 445, 'NAS'),
        ScanHit('192.168.1.41', 445, null),
      ]);

  @override
  Future<void> register(List<Map<String, dynamic>> specs) async {}
}

final _servers = <NetServer>[
  const NetServer(id: 'a', protocol: NetProtocol.smb, host: '192.168.1.23', name: 'Living-room NAS',
      path: 'Movies', anonymous: true),
  const NetServer(id: 'b', protocol: NetProtocol.sftp, host: '192.168.1.10', user: 'mya', useKey: true),
  const NetServer(id: 'c', protocol: NetProtocol.ftp, host: '192.168.1.41', port: 2121, name: 'Old laptop',
      user: 'guest'),
  const NetServer(id: 'd', protocol: NetProtocol.ftps, host: 'files.home', name: 'Office',
      user: r'WORK\tun', implicitTls: true),
];

Map<String, Object> get _saved =>
    <String, Object>{'net.servers.v1': jsonEncode(_servers.map((s) => s.toJson()).toList())};

Future<void> _tap(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _form(WidgetTester t, String proto) async {
  await _tap(t, 'net-add');
  await _tap(t, 'net-proto-$proto');
}

void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  List<Override> ok() => [netChannelProvider.overrideWithValue(const _FakeChannel())];
  const both = [Locale('my'), Locale('en')];

  screens('net_empty', () => const LocalNetworkScreen(), overrides: ok, locales: both,
      phones: const [tiny, small, large, tablet]);
  screens('net_list', () => const LocalNetworkScreen(), overrides: ok, prefs: _saved, locales: both);
  screens('net_info', () => const LocalNetworkScreen(), overrides: ok, locales: both,
      act: (t) => _tap(t, 'net-info'));
  screens('net_add', () => const LocalNetworkScreen(), overrides: ok, locales: both,
      act: (t) => _tap(t, 'net-add'));
  for (final p in <String>['smb', 'ftp', 'ftps']) {
    screens('net_form_$p', () => const LocalNetworkScreen(), overrides: ok, locales: both,
        phones: const [tiny, small, large], act: (t) => _form(t, p));
  }
  screens('net_form_sftp_key', () => const LocalNetworkScreen(), overrides: ok, locales: both,
      act: (t) async {
    await _form(t, 'sftp');
    await _tap(t, 'net-usekey');
  });
  screens('net_form_smb_user', () => const LocalNetworkScreen(), overrides: ok, locales: both,
      act: (t) async {
    await _form(t, 'smb');
    await _tap(t, 'net-anon');
  });
  screens('net_scan', () => const LocalNetworkScreen(), overrides: ok, locales: both,
      act: (t) async {
    await _form(t, 'smb');
    await _tap(t, 'net-scan');
  });
  screens('net_form_error', () => const LocalNetworkScreen(),
      overrides: () => [netChannelProvider.overrideWithValue(const _FakeChannel(fail: 'unreachable'))],
      locales: both, act: (t) async {
    await _form(t, 'smb');
    await t.enterText(find.byKey(const ValueKey('net-host')), '192.168.1.99');
    await _tap(t, 'net-connect');
  });
  screens('net_browser', () => NetBrowserScreen(server: _servers.first, home: '/Movies'),
      overrides: ok, locales: both, phones: const [small, large, tablet]);
  screens('net_browser_error', () => NetBrowserScreen(server: _servers[2]),
      overrides: () => [netChannelProvider.overrideWithValue(const _FakeChannel(fail: 'auth'))],
      locales: both);
}
