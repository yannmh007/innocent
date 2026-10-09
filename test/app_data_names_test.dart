// Android/data folders in the Local list are named after the app they belong
// to when their own name says nothing ("cache", "files"), and keep their name
// when it does.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/local_browser/domain/app_data_names.dart';

void main() {
  const root = '/storage/emulated/0/Android/data';

  test('the package is read from Android/data and Android/obb', () {
    expect(appDataPackage('$root/org.telegram.messenger/cache'), 'org.telegram.messenger');
    expect(appDataPackage('/storage/emulated/0/Android/obb/com.game.x/main'), 'com.game.x');
    expect(appDataPackage('/storage/emulated/0/Movies'), isNull);
  });

  test('a generic folder is named after its app', () {
    expect(appDataFolderName('$root/org.telegram.messenger/cache'), 'Telegram · cache');
    expect(appDataFolderName('$root/com.facebook.orca/files/video'), 'Messenger · video');
    expect(appDataFolderName('$root/com.ss.android.ugc.trill/cache/'), 'TikTok · cache');
  });

  test('a folder whose name already says what it is keeps it', () {
    expect(
        appDataFolderName('$root/org.telegram.messenger/files/Telegram/Telegram Video'),
        'Telegram Video');
  });

  test('a numbered or hashed folder gets the app too', () {
    expect(appDataFolderName('$root/com.viber.voip/files/123456'), 'Viber · 123456');
    expect(appDataFolderName('$root/com.viber.voip/files/a1b2c3'), 'Viber · a1b2c3');
  });

  test('the package directory itself is just the app', () {
    expect(appDataFolderName('$root/org.telegram.messenger'), 'Telegram');
  });

  test('an unknown app is named by the telling word of its package', () {
    expect(appLabelForPackage('com.example.coolplayer'), 'Coolplayer');
    expect(appLabelForPackage('com.example.android.app'), 'Example');
    expect(appLabelForPackage('com.android'), 'com.android');
    expect(appDataFolderName('$root/com.example.coolplayer/cache'), 'Coolplayer · cache');
  });

  test('outside Android/data the name is the folder\'s own', () {
    expect(appDataFolderName('/storage/emulated/0/Movies/cache'), 'cache');
  });
}
