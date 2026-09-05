import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
/// Cloud Drive screen — MX Player parity.
/// Lists supported cloud providers; user taps to connect.
class CloudDriveScreen extends StatefulWidget {
  const CloudDriveScreen({super.key});

  @override
  State<CloudDriveScreen> createState() => _CloudDriveScreenState();
}

class _CloudDriveScreenState extends State<CloudDriveScreen> {
  final Set<String> _connected = <String>{};

  static const _providers = <_Provider>[
    _Provider('Google Drive', Icons.cloud, Color(0xFF4285F4),
        'Stream from Drive without downloading'),
    _Provider('Dropbox', Icons.cloud_queue, Color(0xFF0061FF),
        'Connect your Dropbox account'),
    _Provider('OneDrive', Icons.cloud_outlined, Color(0xFF0078D4),
        'Microsoft cloud storage'),
    _Provider('iCloud Drive', Icons.cloud_circle, Color(0xFF747577),
        'Apple iCloud (web-link only)'),
    _Provider('Yandex Disk', Icons.cloud_done, Color(0xFFFF0000),
        'Yandex cloud storage'),
    _Provider('MEGA', Icons.cloud_sync, Color(0xFFD9272E),
        'Encrypted cloud storage'),
    _Provider('pCloud', Icons.cloud_upload, Color(0xFF17BED0),
        'European cloud storage'),
  ];

  void _toggle(_Provider p) {
    // Cloud sync isn't wired yet — there's no OAuth/SDK behind these
    // providers. Be honest with the user instead of faking a "connected"
    // state that does nothing.
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('${p.name} — ' + AppStrings.of(context).comingSoon),
          duration: const Duration(milliseconds: 1500),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).cloudDrive),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, size: 22),
            tooltip: 'About cloud drive',
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: AppColors.darkSurface,
                  title: Text(AppStrings.of(context).aboutCloudDrive,
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                  content: Text(AppStrings.of(context).cloudDriveBody,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.75),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(AppStrings.of(context).gotIt.toUpperCase(),
                          style: TextStyle(color: AppColors.primaryBlue)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(AppStrings.of(context).connectCloudCaps,
              style: TextStyle(
                color: AppColors.white50,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: _providers.length,
              separatorBuilder: (_, __) => Divider(
                  color: AppColors.white06, height: 1),
              itemBuilder: (_, i) {
                final p = _providers[i];
                final isConnected = _connected.contains(p.name);
                return ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: p.color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(p.icon, color: p.color, size: 22),
                  ),
                  title: Text(p.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500)),
                  subtitle: Text(p.subtitle,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                  trailing: isConnected
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle,
                                color: Color(0xFF4CAF50), size: 20),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () => _toggle(p),
                              child: Text(AppStrings.of(context).disconnect,
                                  style: TextStyle(
                                      color: Color(0xFFEF5350), fontSize: 12)),
                            ),
                          ],
                        )
                      : TextButton(
                          onPressed: () => _toggle(p),
                          style: TextButton.styleFrom(
                              foregroundColor: AppColors.primaryBlue),
                          child: Text(AppStrings.of(context).connect,
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                  onTap: () => _toggle(p),
                );
              },
            ),
          ),
          if (_connected.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.darkSurface,
                border: Border(
                  top: BorderSide(color: AppColors.white08),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle,
                      color: Color(0xFF4CAF50), size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '${_connected.length} account${_connected.length == 1 ? '' : 's'} connected',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Provider {
  final String name;
  final IconData icon;
  final Color color;
  final String subtitle;
  const _Provider(this.name, this.icon, this.color, this.subtitle);
}
