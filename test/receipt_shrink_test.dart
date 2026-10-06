import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/presentation/account/receipt_picker.dart';

Future<Uint8List> _png(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  // Noise-like stripes, so the PNG does not compress to nothing.
  for (var y = 0; y < h; y += 3) {
    c.drawRect(Rect.fromLTWH(0, y.toDouble(), w.toDouble(), 2),
        Paint()..color = Color(0xFF000000 | (y * 2654435761) & 0xFFFFFF));
  }
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

void main() {
  testWidgets('a small receipt is sent as it is', (t) async {
    await t.runAsync(() async {
      final raw = await _png(200, 400);
      expect(identical(await shrinkReceipt(raw), raw), isTrue);
    });
  });

  testWidgets('a large one is redrawn 1080 wide, and only ever gets smaller', (t) async {
    await t.runAsync(() async {
      final raw = await _png(1440, 3200);
      final out = await shrinkReceipt(raw, limit: 1024);
      expect(out.length, lessThan(raw.length));
      final codec = await ui.instantiateImageCodec(out);
      final f = await codec.getNextFrame();
      expect(f.image.width, 1080);
    });
  });

  testWidgets('something that is not an image comes back untouched', (t) async {
    await t.runAsync(() async {
      final junk = Uint8List.fromList(List<int>.filled(4096, 7));
      expect(await shrinkReceipt(junk, limit: 10), junk);
    });
  });
}
