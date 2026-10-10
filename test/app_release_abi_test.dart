import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/domain/app_release.dart';

/// Migration 044: a release has an arm64 APK and, for phones whose Android
/// is 32-bit, an armeabi-v7a one. A phone is offered the file it can install
/// and no other.
void main() {
  const sha64 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const sha32 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const cdn = 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/apk';

  Map<String, dynamic> row({String? url32, String? sha32Value, int? bytes32}) =>
      <String, dynamic>{
        'version_name': '1.64.60',
        'version_code': 373,
        'apk_url': '$cdn/innocent-1.64.60-373.apk',
        'apk_sha256': sha64,
        'apk_bytes': 92000000,
        'apk_url_arm32': url32,
        'apk_sha256_arm32': sha32Value,
        'apk_bytes_arm32': bytes32,
      };

  test('a 64-bit phone gets the arm64 APK, though it also runs 32-bit code', () {
    final r = AppRelease.fromJson(
      row(url32: '$cdn/innocent-1.64.60-373-arm32.apk', sha32Value: sha32, bytes32: 81000000),
      abis: const <String>['arm64-v8a', 'armeabi-v7a', 'armeabi'],
    )!;
    expect(r.apkUrl, '$cdn/innocent-1.64.60-373.apk');
    expect(r.apkSha256, sha64);
    expect(r.apkBytes, 92000000);
  });

  test('a phone running 32-bit Android gets the 32-bit APK', () {
    final r = AppRelease.fromJson(
      row(url32: '$cdn/innocent-1.64.60-373-arm32.apk', sha32Value: sha32, bytes32: 81000000),
      abis: const <String>['armeabi-v7a', 'armeabi'],
    )!;
    expect(r.apkUrl, '$cdn/innocent-1.64.60-373-arm32.apk');
    expect(r.apkSha256, sha32);
    expect(r.apkBytes, 81000000);
    expect(r.canDownload, isTrue);
  });

  test('a 32-bit phone is never offered the arm64 APK', () {
    final r = AppRelease.fromJson(row(), abis: const <String>['armeabi-v7a'])!;
    expect(r.apkUrl, isNull);
    expect(r.canDownload, isFalse,
        reason: 'the installer would refuse it after the whole download');
    // Still a release: the screen can say a newer version exists.
    expect(r.versionCode, 373);
  });

  test('a 32-bit file left over from an earlier build is not offered as this one', () {
    final r = AppRelease.fromJson(
      row(url32: '$cdn/innocent-1.64.59-372-arm32.apk', sha32Value: sha32, bytes32: 81000000),
      abis: const <String>['armeabi-v7a'],
    )!;
    expect(r.canDownload, isFalse);
    expect(r.apkSha256, isNull);
  });

  test('ABIs not known keep the arm64 APK, as every earlier build did', () {
    final r = AppRelease.fromJson(row())!;
    expect(r.apkUrl, '$cdn/innocent-1.64.60-373.apk');
    expect(r.canDownload, isTrue);
  });

  test('which phones count as 32-bit only', () {
    expect(AppRelease.phoneRuns32BitOnly(const <String>['armeabi-v7a', 'armeabi']), isTrue);
    expect(AppRelease.phoneRuns32BitOnly(const <String>['arm64-v8a', 'armeabi-v7a']), isFalse);
    expect(AppRelease.phoneRuns32BitOnly(const <String>['arm64-v8a']), isFalse);
    expect(AppRelease.phoneRuns32BitOnly(const <String>['x86_64', 'arm64-v8a']), isFalse);
    expect(AppRelease.phoneRuns32BitOnly(const <String>[]), isFalse);
  });
}
