import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// THE BUTTONS ANDROID COULD NOT NAME.
///
/// Every icon-only button in the app is named by its tooltip — "Search",
/// "More", "Hide" — which is Flutter's rule and the lint everybody follows.
/// On Android 9 and later the engine hands that tooltip to Android as
/// tooltip text ONLY, never as the content description
/// (shell/platform/android/.../AccessibilityBridge.java: before API 28 the
/// tooltip is appended to the description; from 28 it goes to
/// setTooltipText and nowhere else). Whatever reads names — Voice Access
/// ("tap Search"), Switch Access, Accessibility Scanner, UiAutomator and so
/// the device lab and Test Lab's Robo — saw some 160 nameless buttons, the
/// Video tab's ⋮ among them, and TalkBack's reading depended on its version.
///
/// The fix sits where every widget's semantics meet: the builder that
/// carries each frame's semantics update to the engine. A node that has a
/// tooltip and no label of its own gets the tooltip AS its label (Android's
/// content description), as a native toolbar button carries its title; a
/// node whose tooltip only repeats its label drops the copy, so a screen
/// reader does not say it twice. Every other field passes through
/// untouched. One place, every screen and every package's widgets, now and
/// later — no button can be added without a name again.
///
/// Installed by [InnocentBinding.ensureInitialized] in main(), before
/// anything else creates a binding.
class InnocentBinding extends WidgetsFlutterBinding {
  /// The app's binding: [WidgetsFlutterBinding] with tooltips named.
  static WidgetsBinding ensureInitialized() {
    if (!_made) {
      _made = true;
      InnocentBinding();
    }
    return WidgetsBinding.instance;
  }

  static bool _made = false;

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      TooltipLabelBuilder(super.createSemanticsUpdateBuilder());
}

/// What a node is called once its tooltip has been considered: the label to
/// send, its attributes, and the tooltip left over.
@visibleForTesting
({String label, List<ui.StringAttribute> labelAttributes, String tooltip})
    nameFromTooltip(
  String label,
  List<ui.StringAttribute> labelAttributes,
  String tooltip,
) {
  if (tooltip.isEmpty) {
    return (label: label, labelAttributes: labelAttributes, tooltip: tooltip);
  }
  if (label.isEmpty) {
    return (
      label: tooltip,
      labelAttributes: const <ui.StringAttribute>[],
      tooltip: '',
    );
  }
  if (label.trim() == tooltip.trim()) {
    return (label: label, labelAttributes: labelAttributes, tooltip: '');
  }
  return (label: label, labelAttributes: labelAttributes, tooltip: tooltip);
}

/// A [ui.SemanticsUpdateBuilder] that names nodes by their tooltips
/// ([nameFromTooltip]) and hands everything to [_inner] otherwise as it is.
class TooltipLabelBuilder implements ui.SemanticsUpdateBuilder {
  TooltipLabelBuilder(this._inner);

  final ui.SemanticsUpdateBuilder _inner;

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
    final named = nameFromTooltip(label, labelAttributes, tooltip);
    _inner.updateNode(
      id: id,
      flags: flags,
      actions: actions,
      maxValueLength: maxValueLength,
      currentValueLength: currentValueLength,
      textSelectionBase: textSelectionBase,
      textSelectionExtent: textSelectionExtent,
      platformViewId: platformViewId,
      scrollChildren: scrollChildren,
      scrollIndex: scrollIndex,
      scrollPosition: scrollPosition,
      scrollExtentMax: scrollExtentMax,
      scrollExtentMin: scrollExtentMin,
      elevation: elevation,
      thickness: thickness,
      rect: rect,
      identifier: identifier,
      label: named.label,
      labelAttributes: named.labelAttributes,
      value: value,
      valueAttributes: valueAttributes,
      increasedValue: increasedValue,
      increasedValueAttributes: increasedValueAttributes,
      decreasedValue: decreasedValue,
      decreasedValueAttributes: decreasedValueAttributes,
      hint: hint,
      hintAttributes: hintAttributes,
      tooltip: named.tooltip,
      textDirection: textDirection,
      transform: transform,
      childrenInTraversalOrder: childrenInTraversalOrder,
      childrenInHitTestOrder: childrenInHitTestOrder,
      additionalActions: additionalActions,
      headingLevel: headingLevel,
      linkUrl: linkUrl,
      role: role,
      controlsNodes: controlsNodes,
      validationResult: validationResult,
      inputType: inputType,
    );
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) =>
      _inner.updateCustomAction(
          id: id, label: label, hint: hint, overrideId: overrideId);

  @override
  ui.SemanticsUpdate build() => _inner.build();
}
