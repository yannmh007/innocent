import 'dart:convert';

/// The four protocols of MX Player's Local Network, in MX's order.
enum NetProtocol {
  smb('SMB', 445),
  ftp('FTP', 21),
  ftps('FTPS', 21),
  sftp('SFTP', 22);

  const NetProtocol(this.label, this.defaultPort);
  final String label;
  final int defaultPort;

  static NetProtocol parse(String s) => NetProtocol.values
      .firstWhere((p) => p.name == s.toLowerCase(), orElse: () => smb);
}

/// The FTP control-connection character sets worth offering: UTF-8 first,
/// then what Chinese, Taiwanese, Japanese, Korean, Russian and Western
/// servers still run on.
const List<String> kFtpEncodings = <String>[
  'UTF-8',
  'GBK',
  'GB18030',
  'Big5',
  'Shift_JIS',
  'EUC-JP',
  'EUC-KR',
  'windows-1251',
  'windows-1252',
  'ISO-8859-1',
];

/// One saved server. The secrets (password, private key, passphrase) are
/// NOT here: they live in the Keystore-backed secure storage, see
/// [NetSecrets], and only meet this object on the way to the native side.
class NetServer {
  const NetServer({
    required this.id,
    required this.protocol,
    required this.host,
    this.port = 0,
    this.name = '',
    this.path = '',
    this.user = '',
    this.domain = '',
    this.anonymous = false,
    this.passive = true,
    this.encoding = 'UTF-8',
    this.implicitTls = false,
    this.useKey = false,
    this.pinned,
    this.lastUsed = 0,
  });

  final String id;
  final NetProtocol protocol;
  final String host;

  /// 0 = the protocol's default.
  final int port;

  /// "Server Name (optional)": what the list shows.
  final String name;

  /// SMB "Shared Path" ("Movies" or "Movies/2024"); FTP/SFTP start folder.
  final String path;
  final String user;
  final String domain;
  final bool anonymous;
  final bool passive;
  final String encoding;
  final bool implicitTls;
  final bool useKey;

  /// The server's identity as first seen (SFTP host key / FTPS certificate).
  final String? pinned;
  final int lastUsed;

  int get effectivePort => port > 0
      ? port
      : (protocol == NetProtocol.ftps && implicitTls
          ? 990
          : protocol.defaultPort);

  /// What a person calls it: their name for it, else the address.
  String get title => name.trim().isNotEmpty ? name.trim() : host;

  /// "smb://192.168.1.5/Movies" — the line under the title.
  String get address {
    final scheme = protocol.name;
    final p = port > 0 && port != protocol.defaultPort ? ':$port' : '';
    final tail = path.trim().isEmpty
        ? ''
        : '/${path.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '')}';
    return '$scheme://$host$p$tail';
  }

  NetServer copyWith({
    String? host,
    int? port,
    String? name,
    String? path,
    String? user,
    String? domain,
    bool? anonymous,
    bool? passive,
    String? encoding,
    bool? implicitTls,
    bool? useKey,
    String? pinned,
    bool clearPinned = false,
    int? lastUsed,
  }) =>
      NetServer(
        id: id,
        protocol: protocol,
        host: host ?? this.host,
        port: port ?? this.port,
        name: name ?? this.name,
        path: path ?? this.path,
        user: user ?? this.user,
        domain: domain ?? this.domain,
        anonymous: anonymous ?? this.anonymous,
        passive: passive ?? this.passive,
        encoding: encoding ?? this.encoding,
        implicitTls: implicitTls ?? this.implicitTls,
        useKey: useKey ?? this.useKey,
        pinned: clearPinned ? null : (pinned ?? this.pinned),
        lastUsed: lastUsed ?? this.lastUsed,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'name': name,
        'path': path,
        'user': user,
        'domain': domain,
        'anonymous': anonymous,
        'passive': passive,
        'encoding': encoding,
        'implicitTls': implicitTls,
        'useKey': useKey,
        if (pinned != null) 'pinned': pinned,
        'lastUsed': lastUsed,
      };

  factory NetServer.fromJson(Map<String, dynamic> j) => NetServer(
        id: j['id'] as String,
        protocol: NetProtocol.parse(j['protocol'] as String? ?? 'smb'),
        host: j['host'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 0,
        name: j['name'] as String? ?? '',
        path: j['path'] as String? ?? '',
        user: j['user'] as String? ?? '',
        domain: j['domain'] as String? ?? '',
        anonymous: j['anonymous'] as bool? ?? false,
        passive: j['passive'] as bool? ?? true,
        encoding: j['encoding'] as String? ?? 'UTF-8',
        implicitTls: j['implicitTls'] as bool? ?? false,
        useKey: j['useKey'] as bool? ?? false,
        pinned: j['pinned'] as String?,
        lastUsed: (j['lastUsed'] as num?)?.toInt() ?? 0,
      );

  /// What the native side needs to sign in: this plus the secrets.
  Map<String, dynamic> spec(NetSecrets s) => <String, dynamic>{
        'id': id,
        'protocol': protocol.name,
        'host': host.trim(),
        'port': port,
        'path': path.trim().replaceAll('\\', '/'),
        'user': anonymous ? '' : user.trim(),
        'password': anonymous ? '' : s.password,
        'domain': domain.trim(),
        'anonymous': anonymous,
        'passive': passive,
        'encoding': encoding,
        'implicitTls': implicitTls,
        if (useKey && s.privateKey.isNotEmpty) 'privateKey': s.privateKey,
        if (useKey && s.passphrase.isNotEmpty) 'passphrase': s.passphrase,
        if (pinned != null) 'pinned': pinned,
      };

  /// "WORKGROUP\alice" in the user name box is how Windows people type a
  /// domain account; split it rather than ask for a Domain field MX does not
  /// have.
  static (String user, String domain) splitDomain(String raw) {
    final t = raw.trim();
    final i = t.indexOf('\\');
    if (i <= 0 || i == t.length - 1) return (t, '');
    return (t.substring(i + 1), t.substring(0, i));
  }
}

class NetSecrets {
  const NetSecrets(
      {this.password = '', this.privateKey = '', this.passphrase = ''});
  final String password;
  final String privateKey;
  final String passphrase;

  static const NetSecrets none = NetSecrets();

  String encode() => jsonEncode(<String, String>{
        'p': password,
        if (privateKey.isNotEmpty) 'k': privateKey,
        if (passphrase.isNotEmpty) 'q': passphrase,
      });

  static NetSecrets decode(String? raw) {
    if (raw == null || raw.isEmpty) return none;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return NetSecrets(
        password: m['p'] as String? ?? '',
        privateKey: m['k'] as String? ?? '',
        passphrase: m['q'] as String? ?? '',
      );
    } catch (_) {
      return none;
    }
  }
}

/// One row of a remote folder.
class NetEntry {
  const NetEntry({
    required this.name,
    required this.path,
    required this.dir,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path;
  final bool dir;
  final int size;
  final int modified;

  factory NetEntry.fromMap(Map<dynamic, dynamic> m) => NetEntry(
        name: m['name'] as String,
        path: m['path'] as String,
        dir: m['dir'] as bool,
        size: (m['size'] as num).toInt(),
        modified: (m['modified'] as num).toInt(),
      );

  String get ext {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  bool get isVideo => !dir && kNetVideoExts.contains(ext);
  bool get isAudio => !dir && kNetAudioExts.contains(ext);
  bool get isSubtitle => !dir && kNetSubtitleExts.contains(ext);
  bool get isPlayable => isVideo || isAudio;
}

const Set<String> kNetVideoExts = <String>{
  'mp4',
  'm4v',
  'mkv',
  'webm',
  'mov',
  'avi',
  'wmv',
  'flv',
  'ts',
  'm2ts',
  'mts',
  'mpg',
  'mpeg',
  '3gp',
  'vob',
  'ogv',
  'rmvb',
  'rm',
  'asf',
  'divx',
};
const Set<String> kNetAudioExts = <String>{
  'mp3',
  'm4a',
  'aac',
  'flac',
  'wav',
  'ogg',
  'opus',
  'wma',
  'ape',
  'alac',
};
const Set<String> kNetSubtitleExts = <String>{
  'srt',
  'ass',
  'ssa',
  'vtt',
  'sub'
};
