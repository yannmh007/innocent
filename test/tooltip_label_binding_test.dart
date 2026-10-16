import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/ui/tooltip_label_binding.dart';

/// Android names a node by its content description; from API 28 the engine
/// sends a Flutter tooltip only as tooltip text. The app's semantics builder
/// makes the tooltip the name of a node that has none.
void main() {
  test('a tooltip-only node is named by its tooltip', () {
    final r = nameFromTooltip('', const <ui.StringAttribute>[], 'More');
    expect(r.label, 'More');
    expect(r.tooltip, isEmpty);
  });

  test('a tooltip that repeats the label is not sent twice', () {
    final r = nameFromTooltip('Hide', const <ui.StringAttribute>[], 'Hide');
    expect(r.label, 'Hide');
    expect(r.tooltip, isEmpty);
  });

  test('a label and a different tooltip are both kept', () {
    final r = nameFromTooltip('Film.mp4', const <ui.StringAttribute>[],
        'Full name of the film.mp4');
    expect(r.label, 'Film.mp4');
    expect(r.tooltip, 'Full name of the film.mp4');
  });

  test('a node without a tooltip is left alone', () {
    final r = nameFromTooltip('Play', const <ui.StringAttribute>[], '');
    expect(r.label, 'Play');
    expect(r.tooltip, isEmpty);
  });

  // The real tree: what an IconButton with a tooltip sends through the
  // builder, field by field.
  testWidgets('an IconButton reaches the engine named', (t) async {
    final sent = _Recorder();
    final builder = TooltipLabelBuilder(sent);
    final handle = t.ensureSemantics();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: IconButton(
          tooltip: 'Search',
          icon: const Icon(Icons.search),
          onPressed: () {},
        ),
      ),
    ));
    final owner = t.binding.renderViews.first.owner!.semanticsOwner!;
    void walk(SemanticsNode n) {
      final d = n.getSemanticsData();
      builder.updateNode(
        id: n.id,
        flags: d.flags,
        actions: d.actions,
        maxValueLength: -1,
        currentValueLength: -1,
        textSelectionBase: -1,
        textSelectionExtent: -1,
        platformViewId: -1,
        scrollChildren: 0,
        scrollIndex: 0,
        scrollPosition: 0,
        scrollExtentMax: 0,
        scrollExtentMin: 0,
        elevation: 0,
        thickness: 0,
        rect: d.rect,
        identifier: d.identifier,
        label: d.label,
        labelAttributes: d.attributedLabel.attributes,
        value: d.value,
        valueAttributes: const <ui.StringAttribute>[],
        increasedValue: '',
        increasedValueAttributes: const <ui.StringAttribute>[],
        decreasedValue: '',
        decreasedValueAttributes: const <ui.StringAttribute>[],
        hint: d.hint,
        hintAttributes: const <ui.StringAttribute>[],
        tooltip: d.tooltip,
        textDirection: d.textDirection,
        transform: Float64List(16),
        childrenInTraversalOrder: Int32List(0),
        childrenInHitTestOrder: Int32List(0),
        additionalActions: Int32List(0),
        controlsNodes: null,
        inputType: ui.SemanticsInputType.none,
      );
      n.visitChildren((c) {
        walk(c);
        return true;
      });
    }

    walk(owner.rootSemanticsNode!);
    // Flutter's own tree: the button's name is only a tooltip.
    expect(
        find.bySemanticsLabel('Search').evaluate().isEmpty &&
            find.byTooltip('Search').evaluate().isNotEmpty,
        isTrue);
    // What the engine is handed: the name, once.
    expect(sent.byTooltipOrLabel('Search'), (label: 'Search', tooltip: ''));
    handle.dispose();
  });
}

class _Recorder implements ui.SemanticsUpdateBuilder {
  final List<({String label, String tooltip})> nodes =
      <({String label, String tooltip})>[];

  ({String label, String tooltip})? byTooltipOrLabel(String s) {
    for (final n in nodes) {
      if (n.label == s || n.tooltip == s) return n;
    }
    return null;
  }

  @override
  void updateNode({
    required int id,
    required int flags,
    required int actions,
    required int maxValueLength,
    required int currentValueLength,
    required int textSelectionBase,
    required int textSelectionExtent,
    required int platformViewId,
    required int scrollChildren,
    required int scrollIndex,
    required double scrollPosition,
    required double scrollExtentMax,
    required double scrollExtentMin,
    required double elevation,
    required double thickness,
    required ui.Rect rect,
    required String identifier,
    required String label,
    required List<ui.StringAttribute> labelAttributes,
    required String value,
    required List<ui.StringAttribute> valueAttributes,
    required String increasedValue,
    required List<ui.StringAttribute> increasedValueAttributes,
    required String decreasedValue,
    required List<ui.StringAttribute> decreasedValueAttributes,
    required String hint,
    required List<ui.StringAttribute> hintAttributes,
    required String tooltip,
    required ui.TextDirection? textDirection,
    required Float64List transform,
    required Int32List childrenInTraversalOrder,
    required Int32List childrenInHitTestOrder,
    required Int32List additionalActions,
    int headingLevel = 0,
    String linkUrl = '',
    ui.SemanticsRole role = ui.SemanticsRole.none,
    required List<String>? controlsNodes,
    ui.SemanticsValidationResult validationResult =
        ui.SemanticsValidationResult.none,
    required ui.SemanticsInputType inputType,
  }) {
    nodes.add((label: label, tooltip: tooltip));
  }

  @override
  void updateCustomAction(
      {required int id, String? label, String? hint, int overrideId = -1}) {}

  @override
  ui.SemanticsUpdate build() => throw UnimplementedError();
}
