import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../../../core/localization/app_strings.dart';
import '../video_hub_theme.dart';

/// The receipt: the screenshot a viewer takes of KPay's "transfer
/// successful" page, the proof Myanmar shops and sellers already ask for.
///
/// THE RECENT SCREENSHOTS FIRST, as Telegram's attachment sheet shows recent
/// photos: the receipt was taken a minute ago, so it is the first thing
/// there and one tap picks it. Drawn only when the app already may read the
/// photos (it asks for them for the video library); otherwise — and always
/// — "Choose from gallery" opens Android's own photo picker, which needs no
/// permission at all. Nothing on this screen asks for a permission.
class ReceiptPicker extends StatefulWidget {
  const ReceiptPicker({super.key, required this.selected, required this.onChanged});

  final Uint8List? selected;
  final ValueChanged<Uint8List?> onChanged;

  @override
  State<ReceiptPicker> createState() => _ReceiptPickerState();
}

class _ReceiptPickerState extends State<ReceiptPicker> {
  List<AssetEntity> _recent = const <AssetEntity>[];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    try {
      final ps = await PhotoManager.getPermissionState(
          requestOption: const PermissionRequestOption());
      if (!ps.hasAccess) return;
      final paths = await PhotoManager.getAssetPathList(
          type: RequestType.image, onlyAll: true);
      if (paths.isEmpty) return;
      final list = await paths.first.getAssetListRange(start: 0, end: 12);
      // A receipt is from today, give or take: a week back at most, so the
      // strip is the recent screenshots rather than the whole camera roll.
      final since = DateTime.now().subtract(const Duration(days: 7));
      final recent = list.where((a) => a.createDateTime.isAfter(since)).toList()
        ..sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      if (mounted) setState(() => _recent = recent.take(8).toList());
    } catch (_) {
      // No strip; the gallery button still works.
    }
  }

  Future<void> _pickRecent(AssetEntity a) async {
    final bytes = await a.originBytes;
    if (bytes == null || !mounted) return;
    setState(() => _selectedId = a.id);
    widget.onChanged(bytes);
  }

  Future<void> _pickGallery() async {
    try {
      final picked = await FilePicker.platform
          .pickFiles(type: FileType.image, withData: true);
      final f = picked?.files.single;
      final bytes = f?.bytes;
      if (bytes == null || !mounted) return;
      setState(() => _selectedId = null);
      widget.onChanged(bytes);
    } on PlatformException {
      // The picker could not open; nothing chosen.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final chosen = widget.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (chosen != null)
          _Chosen(
            bytes: chosen,
            onRemove: () {
              setState(() => _selectedId = null);
              widget.onChanged(null);
            },
          )
        else ...<Widget>[
          if (_recent.isNotEmpty) ...<Widget>[
            Text(s.vhPayRecentShots, style: VH.meta.copyWith(fontSize: 12)),
            const SizedBox(height: VH.s2),
            SizedBox(
              height: 128,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _recent.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => _Thumb(
                  asset: _recent[i],
                  selected: _recent[i].id == _selectedId,
                  onTap: () => _pickRecent(_recent[i]),
                ),
              ),
            ),
            const SizedBox(height: VH.s3),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _pickGallery,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
              label: Text(s.vhPayChooseShot),
              style: OutlinedButton.styleFrom(
                foregroundColor: VH.textPrimary,
                side: const BorderSide(color: VH.hairline),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(VH.rControl),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.asset, required this.selected, required this.onTap});

  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected ? VH.accent : VH.hairline, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: FutureBuilder<Uint8List?>(
          future: asset.thumbnailDataWithSize(const ThumbnailSize(160, 320)),
          builder: (context, snap) => snap.data == null
              ? const ColoredBox(color: VH.surface2)
              : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      ),
    );
  }
}

/// The chosen receipt, large enough to check it is the right one, with a
/// way to take it back.
class _Chosen extends StatelessWidget {
  const _Chosen({required this.bytes, required this.onRemove});

  final Uint8List bytes;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(bytes, width: 110, height: 200, fit: BoxFit.cover),
        ),
        const SizedBox(width: VH.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.check_circle_rounded, color: VH.accent, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(s.vhPayShotAttached, style: VH.label)),
                ],
              ),
              const SizedBox(height: VH.s2),
              Text(s.vhPayShotCheck, style: VH.meta.copyWith(fontSize: 12, height: 1.4)),
              const SizedBox(height: VH.s2),
              TextButton.icon(
                onPressed: onRemove,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: Text(s.vhPayShotChange),
                style: TextButton.styleFrom(foregroundColor: VH.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A receipt small enough to send on a slow connection. A phone screenshot
/// is 0.3–1.5 MB as PNG; one over [limit] is redrawn 1080 px wide (a KPay
/// receipt stays readable far below that). Never larger than it came.
Future<Uint8List> shrinkReceipt(Uint8List raw, {int limit = 1500 * 1024}) async {
  if (raw.length <= limit) return raw;
  try {
    final probe = await ui.instantiateImageCodec(raw);
    final frame = await probe.getNextFrame();
    final w = frame.image.width;
    frame.image.dispose();
    final codec = await ui.instantiateImageCodec(raw,
        targetWidth: w > 1080 ? 1080 : null);
    final img = (await codec.getNextFrame()).image;
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (png == null) return raw;
    final out = png.buffer.asUint8List();
    return out.length < raw.length ? out : raw;
  } catch (_) {
    return raw;
  }
}
