import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../data/net_repository.dart';
import '../data/net_server.dart';
import 'net_errors.dart';
import 'net_widgets.dart';
import 'scan_sheet.dart';

/// MX's "Add A New Server" card: the four protocols.
Future<NetProtocol?> pickProtocol(BuildContext context) {
  final s = AppStrings.of(context);
  return showDialog<NetProtocol>(
    context: context,
    builder: (ctx) => NetDialog(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Text(
              s.addNewServer,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700),
            ),
          ),
          for (final p in NetProtocol.values)
            InkWell(
              key: ValueKey('net-proto-${p.name}'),
              onTap: () => Navigator.of(ctx).pop(p),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Row(
                  children: <Widget>[
                    ProtocolGlyph(p),
                    const SizedBox(width: 16),
                    Text(p.label,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// "New SMB Server" … "New SFTP Server": MX's form, field for field, and
/// Connect that signs in for real before anything is saved. Returns the
/// saved server, signed in, or null.
Future<NetServer?> showServerForm(
  BuildContext context, {
  required NetProtocol protocol,
  NetServer? existing,
}) {
  return showDialog<NetServer>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ServerFormDialog(protocol: protocol, existing: existing),
  );
}

class ServerFormDialog extends ConsumerStatefulWidget {
  const ServerFormDialog({super.key, required this.protocol, this.existing});
  final NetProtocol protocol;
  final NetServer? existing;

  @override
  ConsumerState<ServerFormDialog> createState() => _ServerFormDialogState();
}

class _ServerFormDialogState extends ConsumerState<ServerFormDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _name;
  late final TextEditingController _path;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _key;
  late final TextEditingController _phrase;
  late bool _anonymous;
  late bool _passive;
  late bool _implicit;
  late bool _useKey;
  late String _encoding;
  bool _portEdited = false;
  bool _showPass = false;
  bool _busy = false;
  String? _error;

  NetProtocol get p => widget.protocol;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(
        text: e != null && e.port > 0
            ? '${e.port}'
            : (p == NetProtocol.smb ? '' : '${p.defaultPort}'));
    _portEdited = e != null && e.port > 0;
    _name = TextEditingController(text: e?.name ?? '');
    _path = TextEditingController(text: e?.path ?? '');
    _user = TextEditingController(
        text: e == null
            ? ''
            : (e.domain.isNotEmpty ? '${e.domain}\\${e.user}' : e.user));
    _pass = TextEditingController();
    _key = TextEditingController();
    _phrase = TextEditingController();
    // MX ticks "Connect Anonymously" for SMB (a NAS's public share is the
    // common first case) and leaves it off for FTP.
    _anonymous = e?.anonymous ?? (p == NetProtocol.smb);
    _passive = e?.passive ?? true;
    _implicit = e?.implicitTls ?? false;
    _useKey = e?.useKey ?? false;
    _encoding = e?.encoding ?? 'UTF-8';
    if (e != null) {
      unawaited(
          ref.read(netServersProvider.notifier).secretsOf(e.id).then((sec) {
        if (!mounted) return;
        _pass.text = sec.password;
        _key.text = sec.privateKey;
        _phrase.text = sec.passphrase;
      }));
    }
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[
      _host,
      _port,
      _name,
      _path,
      _user,
      _pass,
      _key,
      _phrase
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// "smb://nas.local/Movies", "ftp://192.168.1.4:2121" pasted into Server:
  /// take it apart rather than fail on it.
  void _onHostChanged(String v) {
    final t = v.trim();
    final m = RegExp(r'^(smb|ftps?|sftp)://([^/:]+)(?::(\d+))?(/.*)?$',
            caseSensitive: false)
        .firstMatch(t);
    if (m == null) return;
    _host.text = m.group(2)!;
    if (m.group(3) != null) {
      _port.text = m.group(3)!;
      _portEdited = true;
    }
    final rest = m.group(4);
    if (rest != null && rest.length > 1) {
      _path.text = Uri.decodeComponent(rest.substring(1));
    }
    setState(() {});
  }

  void _setImplicit(bool v) {
    setState(() {
      _implicit = v;
      if (!_portEdited) _port.text = v ? '990' : '21';
    });
  }

  Future<void> _scan() async {
    final hit = await showScanSheet(context, p);
    if (hit == null || !mounted) return;
    setState(() {
      _host.text = hit.ip;
      if (_name.text.trim().isEmpty && (hit.name ?? '').isNotEmpty) {
        _name.text = hit.name!;
      }
      final def = p == NetProtocol.ftps && _implicit ? 990 : p.defaultPort;
      if (hit.port != def) {
        _port.text = '${hit.port}';
        _portEdited = true;
      }
      _error = null;
    });
  }

  Future<void> _chooseKey() async {
    try {
      final r = await FilePicker.platform.pickFiles(withData: true);
      final f = r?.files.single;
      if (f == null) return;
      final bytes = f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (bytes == null || bytes.length > 64 * 1024) return;
      setState(() => _key.text = String.fromCharCodes(bytes).trim());
    } catch (_) {}
  }

  int _portValue() {
    final t = _port.text.trim();
    if (t.isEmpty) return 0;
    final v = int.tryParse(t) ?? -1;
    final def = p == NetProtocol.ftps && _implicit ? 990 : p.defaultPort;
    return v == def ? 0 : v;
  }

  Future<void> _connect() async {
    final s = AppStrings.of(context);
    final host = _host.text.trim();
    if (host.isEmpty) return setState(() => _error = s.netErrNeedHost);
    final port = _portValue();
    if (port < 0 || port > 65535) {
      return setState(() => _error = s.netErrBadPort);
    }
    if (p == NetProtocol.sftp && _useKey && _key.text.trim().isEmpty) {
      return setState(() => _error = s.netErrNeedKey);
    }
    final anon = (p == NetProtocol.smb || p == NetProtocol.ftp) && _anonymous;
    final (user, domain) = NetServer.splitDomain(_user.text);
    var server = NetServer(
      id: widget.existing?.id ?? NetServersNotifier.newId(),
      protocol: p,
      host: host,
      port: port,
      name: _name.text.trim(),
      path: _path.text.trim(),
      user: anon ? '' : user,
      domain: anon ? '' : domain,
      anonymous: anon,
      passive: _passive,
      encoding: _encoding,
      implicitTls: p == NetProtocol.ftps && _implicit,
      useKey: p == NetProtocol.sftp && _useKey,
      // Same address: keep the identity we know. A new address is a new
      // server, met for the first time.
      pinned: widget.existing?.host == host && widget.existing?.port == port
          ? widget.existing?.pinned
          : null,
      lastUsed: DateTime.now().millisecondsSinceEpoch,
    );
    final secrets = NetSecrets(
      password: anon ? '' : _pass.text,
      privateKey: server.useKey ? _key.text.trim() : '',
      passphrase: server.useKey ? _phrase.text : '',
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    final channel = ref.read(netChannelProvider);
    try {
      final r = await _tryConnect(channel, server, secrets);
      if (r == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      if (server.pinned == null && r.fingerprint != null) {
        server = server.copyWith(pinned: r.fingerprint);
      }
      await ref.read(netServersProvider.notifier).put(server, secrets);
      if (mounted) Navigator.of(context).pop(server);
    } on NetFailure catch (f) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = netErrorText(context, f, server);
      });
    }
  }

  /// Signs in; on a changed identity asks, and on "trust" tries again pinned
  /// to the new one. Null = the person declined.
  Future<({String home, String? fingerprint})?> _tryConnect(
      NetChannel channel, NetServer server, NetSecrets secrets) async {
    try {
      return await channel.connect(server.spec(secrets));
    } on NetFailure catch (f) {
      if (f.code != 'hostkey_changed' || !mounted) rethrow;
      final trust = await confirmNewIdentity(context, f, server);
      if (!trust) return null;
      final pinned = server.copyWith(pinned: f.detail);
      final r = await channel.connect(pinned.spec(secrets));
      return (home: r.home, fingerprint: f.detail);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final mm = s.locale.languageCode == 'my';
    final title = widget.existing == null
        ? s.netNewServer(p.label)
        : s.netEditServer(p.label);
    final showCreds =
        !((p == NetProtocol.smb || p == NetProtocol.ftp) && _anonymous);

    // MX's order, protocol by protocol (see the PDF of its screens): SMB
    // asks for the address, a name and the share, with "Connect
    // Anonymously" last; FTP/FTPS/SFTP for address, port and account first.
    final rows = <Widget>[
      _row(
          s.netServer,
          _field(_host, s.netServerIp,
              key: 'net-host',
              keyboard: TextInputType.url,
              onChanged: _onHostChanged,
              autofocus: widget.existing == null)),
      if (p != NetProtocol.smb)
        _row(
            s.netPort,
            _field(_port, '${p.defaultPort}',
                key: 'net-port',
                keyboard: TextInputType.number,
                onChanged: (_) => _portEdited = true,
                formatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly
                ])),
      if (showCreds) ...<Widget>[
        _row(s.netUsername, _field(_user, s.netUsername, key: 'net-user')),
        if (!(p == NetProtocol.sftp && _useKey))
          _row(
              s.netPassword,
              _field(_pass, s.netPassword,
                  key: 'net-pass',
                  obscure: !_showPass,
                  suffix: IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                        _showPass
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        size: 18,
                        color: NetColors.hint),
                    onPressed: () => setState(() => _showPass = !_showPass),
                  ))),
      ],
      if (p == NetProtocol.ftp)
        _check(
            s.netAnonymous, _anonymous, (v) => setState(() => _anonymous = v),
            key: 'net-anon'),
      if (p == NetProtocol.sftp) ...<Widget>[
        _check(s.netUseKey, _useKey, (v) => setState(() => _useKey = v),
            key: 'net-usekey'),
        if (_useKey) ...<Widget>[
          _row(
              s.netPrivateKey,
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _field(_key, s.netPrivateKeyHint,
                      key: 'net-key', lines: 3, mono: true),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _chooseKey,
                      icon: const Icon(Icons.key_rounded,
                          size: 16, color: NetColors.action),
                      label: Text(s.netChooseKeyFile,
                          style: const TextStyle(
                              color: NetColors.action, fontSize: 13)),
                    ),
                  ),
                ],
              )),
          _row(
              s.netPassphrase,
              _field(_phrase, s.netPassphraseHint,
                  key: 'net-phrase', obscure: true)),
        ],
      ],
      _row(
          s.netServerName, _field(_name, s.netServerNameHint, key: 'net-name')),
      if (p == NetProtocol.smb) ...<Widget>[
        _row(s.netSharedPath,
            _field(_path, s.netSharedPathHint, key: 'net-path')),
        _check(
            s.netAnonymous, _anonymous, (v) => setState(() => _anonymous = v),
            key: 'net-anon'),
      ],
      if (p == NetProtocol.ftp || p == NetProtocol.ftps) ...<Widget>[
        _row(
            s.netMode,
            _radios(
                <(String, bool)>[(s.netActive, false), (s.netPassive, true)],
                _passive,
                (v) => setState(() => _passive = v))),
        _row(s.netEncoding, _encodingBox()),
      ],
      if (p == NetProtocol.ftps)
        _row(
            s.netSecurityMode,
            _radios(
                <(String, bool)>[(s.netImplicit, true), (s.netExplicit, false)],
                _implicit,
                _setImplicit)),
    ];

    return NetDialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        height: mm ? 1.5 : 1.2)),
              ),
              OutlinedButton(
                key: const ValueKey('net-scan'),
                onPressed: _busy ? null : _scan,
                style: OutlinedButton.styleFrom(
                  foregroundColor: NetColors.scan,
                  side: const BorderSide(color: NetColors.scan),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(3)),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 36),
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(s.netScan,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(
              child: AbsorbPointer(
                absorbing: _busy,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: rows),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.error_outline_rounded,
                        color: NetColors.error, size: 17),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!,
                        key: const ValueKey('net-error'),
                        style: TextStyle(
                            color: NetColors.error,
                            fontSize: 13,
                            height: mm ? 1.6 : 1.35)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(s.cancel,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('net-connect'),
                onPressed: _busy ? null : _connect,
                child: _busy
                    ? Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                        const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: NetColors.action)),
                        const SizedBox(width: 10),
                        Text(s.netConnecting,
                            style: const TextStyle(
                                color: NetColors.action, fontSize: 14)),
                      ])
                    : Text(widget.existing == null ? s.netConnect : s.netSave,
                        style: const TextStyle(
                            color: NetColors.action,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── MX's row: label on the left, box on the right; stacked when the
  //    dialog is narrow or the language's labels are long ─────────────────

  Widget _row(String label, Widget field) {
    return LayoutBuilder(builder: (context, c) {
      final mm = AppStrings.of(context).locale.languageCode == 'my';
      // Side by side as in MX down to a 320 dp phone; stacked only below
      // that, where a label column would leave the box too narrow to type in.
      final stacked = c.maxWidth < (mm ? 286 : 270);
      final l = Text(label,
          style: TextStyle(
              color: Colors.white, fontSize: 14, height: mm ? 1.45 : 1.2));
      if (stacked) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                l,
                const SizedBox(height: 5),
                field,
              ]),
        );
      }
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              SizedBox(width: c.maxWidth < 330 ? 96 : 112, child: l),
              const SizedBox(width: 6),
              Expanded(child: field),
            ]),
      );
    });
  }

  Widget _field(
    TextEditingController c,
    String hint, {
    required String key,
    bool obscure = false,
    TextInputType? keyboard,
    ValueChanged<String>? onChanged,
    List<TextInputFormatter>? formatters,
    Widget? suffix,
    int lines = 1,
    bool mono = false,
    bool autofocus = false,
  }) {
    const border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(3)),
      borderSide: BorderSide(color: NetColors.fieldBorder),
    );
    return TextField(
      key: ValueKey(key),
      controller: c,
      obscureText: obscure,
      keyboardType: lines > 1 ? TextInputType.multiline : keyboard,
      inputFormatters: formatters,
      onChanged: onChanged,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      minLines: lines,
      maxLines: lines,
      style: TextStyle(
        color: Colors.white,
        fontSize: mono ? 12 : 14,
        fontFamily: mono ? 'monospace' : null,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: NetColors.hint, fontSize: 13.5),
        filled: true,
        fillColor: NetColors.field,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        enabledBorder: border,
        border: border,
        focusedBorder: border.copyWith(
            borderSide: const BorderSide(color: NetColors.action, width: 1.4)),
        suffixIcon: suffix,
        suffixIconConstraints:
            const BoxConstraints(minHeight: 32, minWidth: 36),
      ),
    );
  }

  Widget _check(String label, bool v, ValueChanged<bool> on,
      {required String key}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: ValueKey(key),
        onTap: () => on(!v),
        child: Row(children: <Widget>[
          SizedBox(
            width: 28,
            height: 32,
            child: Checkbox(
              value: v,
              onChanged: (x) => on(x ?? false),
              activeColor: NetColors.action,
              side: const BorderSide(color: Colors.white70, width: 1.4),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 14))),
        ]),
      ),
    );
  }

  Widget _radios(List<(String, bool)> opts, bool value, ValueChanged<bool> on) {
    return Wrap(
      spacing: 6,
      children: <Widget>[
        for (final (label, v) in opts)
          InkWell(
            onTap: () => on(v),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Radio<bool>(
                value: v,
                groupValue: value,
                onChanged: (x) => on(x ?? v),
                activeColor: NetColors.action,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(width: 6),
            ]),
          ),
      ],
    );
  }

  Widget _encodingBox() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: NetColors.field,
        border: Border.all(color: NetColors.fieldBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const ValueKey('net-encoding'),
          value: _encoding,
          isExpanded: true,
          dropdownColor: NetColors.dialog,
          iconEnabledColor: Colors.white,
          // The theme's face, not the dropdown's bare default.
          style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
              .copyWith(color: Colors.white, fontSize: 14),
          items: <DropdownMenuItem<String>>[
            for (final e in kFtpEncodings)
              DropdownMenuItem<String>(value: e, child: Text(e)),
          ],
          onChanged: (v) => setState(() => _encoding = v ?? 'UTF-8'),
        ),
      ),
    );
  }
}
