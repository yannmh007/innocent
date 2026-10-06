import 'package:flutter/rendering.dart';

/// Lab builds only: print the semantics tree as Android's accessibility
/// bridge sees it — each node's rect carried through its ancestors'
/// transforms into window pixels — so a node TalkBack places wrongly can be
/// found by its line ("LAB sem …" in lab_trace.txt).
void labDumpSemantics(String tag, {int maxLines = 160}) {
  var lines = 0;
  for (final view in RendererBinding.instance.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root == null) {
      debugPrint('LAB sem $tag: semantics off');
      continue;
    }
    debugPrint('LAB sem $tag: view ${view.size} dpr ${view.flutterView.devicePixelRatio}');
    void walk(SemanticsNode n, Matrix4 parent, int depth) {
      if (lines >= maxLines) return;
      final t = n.transform;
      final global = t == null ? parent : parent.multiplied(t);
      final r = MatrixUtils.transformRect(global, n.rect);
      final d = n.getSemanticsData();
      final name = [
        if (d.identifier.isNotEmpty) 'id=${d.identifier}',
        if (d.label.isNotEmpty)
          'label="${d.label.replaceAll('\n', ' / ')}"',
        if (d.tooltip.isNotEmpty) 'tip="${d.tooltip}"',
        if (d.hasAction(SemanticsAction.tap)) 'tap',
        if (d.hasFlag(SemanticsFlag.isHidden)) 'hidden',
      ].join(' ');
      final tx = t == null ? '' : ' T=${_matrix(t)}';
      debugPrint('LAB sem ${'  ' * depth}#${n.id} '
          '${r.left.round()},${r.top.round()} ${r.width.round()}x${r.height.round()}'
          ' own=${n.rect.left.round()},${n.rect.top.round()} '
          '${n.rect.width.round()}x${n.rect.height.round()}$tx $name');
      lines++;
      n.visitChildren((c) {
        walk(c, global, depth + 1);
        return true;
      });
    }

    walk(root, Matrix4.identity(), 0);
  }
}

String _matrix(Matrix4 m) {
  String f(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);
  final s = m.storage;
  // Column-major: scale x/y, translation, and the projective row.
  return '[sx ${f(s[0])} sy ${f(s[5])} tx ${f(s[12])} ty ${f(s[13])}'
      '${s[3] != 0 || s[7] != 0 || s[15] != 1 ? ' w ${f(s[3])},${f(s[7])},${f(s[15])}' : ''}'
      '${s[1] != 0 || s[4] != 0 ? ' skew ${f(s[1])},${f(s[4])}' : ''}]';
}

