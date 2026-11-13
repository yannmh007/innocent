import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The look of the app's information dialogs (Properties, folder details),
/// on the same tokens as the player's menus (skill ui-design,
/// player_ui.dart): the dark surface, 20 dp corners, labels in the
/// secondary grey and values in white at one size, no rules between rows,
/// the accent "Okay" at the bottom right.
///
/// It was MX Player's card measured from screenshots — a warm grey with
/// 4 dp corners and 16.5 sp rows — and beside the redesigned player (the
/// Information tile opens it over the film) it read as another app's
/// (12 Nov 2026). The layout, the table of rows and the sizes' wording stay
/// MX's.
class MxDialog {
  MxDialog._();

  static const Color background = Color(0xFF1C1C1E);
  static const double radius = 20;
  static const EdgeInsets inset =
      EdgeInsets.symmetric(horizontal: 24, vertical: 24);
  static const ShapeBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(radius)));

  static const TextStyle title = TextStyle(
      color: Color(0xEBFFFFFF), fontSize: 18, fontWeight: FontWeight.w600);
  static const TextStyle label =
      TextStyle(color: Color(0x9EFFFFFF), fontSize: 15, height: 1.35);
  static const TextStyle value =
      TextStyle(color: Color(0xEBFFFFFF), fontSize: 15, height: 1.35);
  static const TextStyle ok = TextStyle(
      color: AppColors.specPrimary, fontSize: 15, fontWeight: FontWeight.w600);

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
