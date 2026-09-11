import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/ui/app_snackbar.dart';

import '../../../core/localization/app_strings.dart';
/// Local Network / Networks screen matching MX Player (UI PDF page 10)
/// Blue hero banner + How to use + FAB → Add A New Server picker
class LocalNetworkScreen extends StatelessWidget {
  const LocalNetworkScreen({super.key});

  void _showAddServer(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text(AppStrings.of(context).addNewServer,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _protocolTile('SMB', const Color(0xFF2196F3)),
              _protocolTile('FTP', const Color(0xFF4CAF50)),
              _protocolTile('FTPS', const Color(0xFFFF9800)),
              _protocolTile('SFTP', const Color(0xFF9C27B0)),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  static Widget _protocolTile(String protocol, Color color) {
    return Builder(
      builder: (context) => ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              protocol,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        title: Text(protocol, style: const TextStyle(color: Colors.white)),
        onTap: () {
          Navigator.pop(context);
          // Phase 41: use the root messenger so the toast survives the pop.
          AppSnackbar.global('$protocol server setup');
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).networks),
        actions: [
          IconButton(
            tooltip: 'Info',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: AppColors.darkSurface,
                  title: Text(AppStrings.of(context).networks, style: const TextStyle(color: Colors.white)),
                  content: const Text(
                    'Access remote files from SMB, FTP, FTPS or SFTP servers directly on your device.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(AppStrings.of(context).ok),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primaryBlue,
        child: const Icon(Icons.add, color: Colors.white),
        onPressed: () => _showAddServer(context),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── BLUE HERO BANNER ───
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1565C0), Color(0xFF1E88E5)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.computer,
                        color: AppColors.white90, size: 40),
                    SizedBox(width: 16),
                    Icon(Icons.storage,
                        color: AppColors.white90, size: 40),
                  ],
                ),
                const SizedBox(height: 16),
                Text(AppStrings.of(context).supportedProtocols,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'SMB  |  FTP  |  FTPS  |  SFTP',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ─── HOW TO USE ───
          Text(AppStrings.of(context).howToUse,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _instructionStep(
            '1.',
            'Add a server by tapping the ',
            icon: Icons.add_circle,
          ),
          const SizedBox(height: 8),
          const _InstructionText(
            number: '2.',
            text:
                'Access all your remote files directly from your device.',
          ),
        ],
      ),
    );
  }

  static Widget _instructionStep(String number, String text,
      {IconData? icon}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(number,
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              children: [
                TextSpan(text: text),
                if (icon != null)
                  WidgetSpan(
                    child: Icon(icon,
                        color: AppColors.primaryBlue, size: 18),
                    alignment: PlaceholderAlignment.middle,
                  ),
                if (icon != null) const TextSpan(text: ' button.'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InstructionText extends StatelessWidget {
  final String number;
  final String text;
  const _InstructionText({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(number,
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Colors.white70, fontSize: 14)),
        ),
      ],
    );
  }
}
