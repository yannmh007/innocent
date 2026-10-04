import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The look of MX Player's information dialogs (Properties, folder details),
/// measured from its screenshots on a 411 dp phone: a warm dark grey card
/// with nearly square corners, 32 dp from the screen edges, labels in grey
/// and values in white at the same size, no rules between rows, and a bold
/// light-blue "Okay" at the bottom right.
class MxDialog {
  MxDialog._();

  static const Color background = Color(0xFF383435);
  static const double radius = 4;
  static const EdgeInsets inset =
      EdgeInsets.symmetric(horizontal: 32, vertical: 24);
  static const ShapeBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(radius)));

  static const TextStyle title = TextStyle(
      color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700);
  static const TextStyle label =
      TextStyle(color: Color(0xFFB4AFB0), fontSize: 16.5, height: 1.3);
  static const TextStyle value =
      TextStyle(color: Colors.white, fontSize: 16.5, height: 1.3);
  static const TextStyle ok = TextStyle(
      color: AppColors.specCheckbox, fontSize: 16, fontWeight: FontWeight.w700);

  /// Label and value rows laid out as a table: the values line up one gap
  /// after the LONGEST label, as MX's do, instead of at a fixed width that
  /// either wastes room or wraps a long Burmese label.
  static Widget rows(List<(String, String)> rows) => Table(
        columnWidths: const <int, TableColumnWidth>{
          0: IntrinsicColumnWidth(),
          1: FlexColumnWidth(),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: <TableRow>[
          for (final (l, v) in rows)
            TableRow(children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 14, top: 5, bottom: 5),
                child: Text(l, style: label),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(v, style: value, softWrap: true),
              ),
            ]),
        ],
      );

  /// "2.4 GB (2,412,345,678 bytes)", as MX writes a size.
  static String sizeWithBytes(int bytes) {
    final grouped = bytes.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    return '${humanSize(bytes)} ($grouped bytes)';
  }

  static String humanSize(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(b >= 10 << 30 ? 0 : 1)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }
}
