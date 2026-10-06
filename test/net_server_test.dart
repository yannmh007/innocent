import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/network/data/net_server.dart';

void main() {
  test('a Windows "DOMAIN\\user" is split, anything else is left alone', () {
    expect(NetServer.splitDomain(r'WORK\tun'), ('tun', 'WORK'));
    expect(NetServer.splitDomain('alice'), ('alice', ''));
    expect(NetServer.splitDomain(r'\alice'), (r'\alice', ''));
    expect(NetServer.splitDomain(r'WORK\'), (r'WORK\', ''));
  });

  test('anonymous servers never send the saved password', () {
    const s = NetServer(id: 'x', protocol: NetProtocol.smb, host: ' nas ', anonymous: true, user: 'bob');
    final spec = s.spec(const NetSecrets(password: 'secret'));
    expect(spec['password'], '');
    expect(spec['user'], '');
    expect(spec['host'], 'nas');
  });

  test('the private key goes only with "Login With Private Key"', () {
    const off = NetServer(id: 'x', protocol: NetProtocol.sftp, host: 'h', user: 'u');
    const key = NetSecrets(password: 'p', privateKey: 'KEY', passphrase: 'q');
    expect(off.spec(key).containsKey('privateKey'), isFalse);
    final on = off.copyWith(useKey: true).spec(key);
    expect(on['privateKey'], 'KEY');
    expect(on['passphrase'], 'q');
  });

  test('address reads like a URL, default ports left out', () {
    expect(const NetServer(id: 'x', protocol: NetProtocol.smb, host: '10.0.0.5', path: r'\Movies\2024').address,
        'smb://10.0.0.5/Movies/2024');
    expect(const NetServer(id: 'x', protocol: NetProtocol.ftp, host: 'h', port: 2121).address, 'ftp://h:2121');
    expect(const NetServer(id: 'x', protocol: NetProtocol.ftps, host: 'h', implicitTls: true).effectivePort, 990);
  });

  test('secrets survive the round trip, and garbage reads as none', () {
    const s = NetSecrets(password: 'p"w', privateKey: '-----BEGIN\nx', passphrase: 'q');
    final back = NetSecrets.decode(s.encode());
    expect((back.password, back.privateKey, back.passphrase), (s.password, s.privateKey, s.passphrase));
    expect(NetSecrets.decode('{oops').password, '');
  });

  test('saved servers survive JSON, pin included', () {
    const s = NetServer(
        id: 'a', protocol: NetProtocol.ftps, host: 'h', encoding: 'GBK', passive: false, pinned: 'SHA256:x');
    final b = NetServer.fromJson(s.toJson());
    expect((b.protocol, b.encoding, b.passive, b.pinned), (NetProtocol.ftps, 'GBK', false, 'SHA256:x'));
  });

  test('media kinds by extension', () {
    NetEntry e(String n) => NetEntry(name: n, path: '/$n', dir: false, size: 1, modified: 0);
    expect(e('a.MKV').isVideo, isTrue);
    expect(e('a.flac').isAudio, isTrue);
    expect(e('a.srt').isSubtitle, isTrue);
    expect(e('a.txt').isPlayable, isFalse);
  });
}
