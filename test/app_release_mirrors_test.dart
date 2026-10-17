import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/domain/app_release.dart';

/// Migration 045: the same APK in more than one place. The CDN first, then
/// the off-site bucket, then the GitHub release — each one asked only when
/// the one before it cannot deliver. What reaches the download is checked
/// here: https only, no repeats, nothing naming another build's file.
void main() {
  const sha64 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const sha32 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const cdn = 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/apk';
  const b2 = 'https://s3.eu-central-003.backblazeb2.com/innocent-apk/apk';
  const gh = 'https://github.com/o/r/releases/download/v1.64.66-379';

  Map<String, dynamic> row({Object? mirrors, Object? mirrors32}) =>
      <String, dynamic>{
        'version_name': '1.64.66',
        'version_code': 379,
        'apk_url': '$cdn/innocent-1.64.66-379.apk',
        'apk_sha256': sha64,
        'apk_bytes': 96000000,
        'apk_url_arm32': '$cdn/innocent-1.64.66-379-arm32.apk',
        'apk_sha256_arm32': sha32,
        'apk_bytes_arm32': 88000000,
        'apk_mirrors': mirrors,
        'apk_mirrors_arm32': mirrors32,
      };

  test('the CDN first, then the mirrors in the order given', () {
    final r = AppRelease.fromJson(row(mirrors: <Object>[
      '$b2/innocent-1.64.66-379.apk',
      '$gh/innocent-1.64.66-379.apk',
    ]))!;
    expect(r.apkSources, <String>[
      '$cdn/innocent-1.64.66-379.apk',
      '$b2/innocent-1.64.66-379.apk',
      '$gh/innocent-1.64.66-379.apk',
    ]);
    expect(r.canDownload, isTrue);
  });

  test('a row from before 045 (no column) has the CDN alone', () {
    final json = row()..remove('apk_mirrors');
    final r = AppRelease.fromJson(json)!;
    expect(r.apkMirrors, isEmpty);
    expect(r.apkSources, <String>['$cdn/innocent-1.64.66-379.apk']);
  });

  test('not https, repeated, the CDN again, or not a string: left out', () {
    final r = AppRelease.fromJson(row(mirrors: <Object?>[
      'http://plain.example/innocent-1.64.66-379.apk',
      '$cdn/innocent-1.64.66-379.apk',
      '  $b2/innocent-1.64.66-379.apk  ',
      '$b2/innocent-1.64.66-379.apk',
      42,
      null,
    ]))!;
    expect(r.apkMirrors, <String>['$b2/innocent-1.64.66-379.apk']);
  });

  test('a mirror left at the last release is never tried', () {
    // It would serve 1.64.65's APK: refused by its length, but only after
    // the request — so it is dropped before any.
    final r = AppRelease.fromJson(row(mirrors: <Object>[
      '$b2/innocent-1.64.65-378.apk',
      '$gh/innocent-1.64.66-379.apk',
    ]))!;
    expect(r.apkMirrors, <String>['$gh/innocent-1.64.66-379.apk']);
  });

  test('at most three are kept', () {
    final r = AppRelease.fromJson(row(mirrors: <Object>[
      for (var i = 0; i < 6; i++) 'https://m$i.example/innocent-1.64.66-379.apk',
    ]))!;
    expect(r.apkMirrors.length, AppRelease.maxMirrors);
  });

  test('a 32-bit phone gets the 32-bit mirrors, never the arm64 ones', () {
    final r = AppRelease.fromJson(
      row(
        mirrors: <Object>['$b2/innocent-1.64.66-379.apk'],
        mirrors32: <Object>['$b2/innocent-1.64.66-379-arm32.apk'],
      ),
      abis: const <String>['armeabi-v7a'],
    )!;
    expect(r.apkSources, <String>[
      '$cdn/innocent-1.64.66-379-arm32.apk',
      '$b2/innocent-1.64.66-379-arm32.apk',
    ]);
  });

  test('a stale 32-bit APK brings no mirrors with it', () {
    final json = row(mirrors32: <Object>['$b2/innocent-1.64.65-378-arm32.apk'])
      ..['apk_url_arm32'] = '$cdn/innocent-1.64.65-378-arm32.apk';
    final r = AppRelease.fromJson(json, abis: const <String>['armeabi-v7a'])!;
    expect(r.canDownload, isFalse);
    expect(r.apkSources, isEmpty);
  });
}
