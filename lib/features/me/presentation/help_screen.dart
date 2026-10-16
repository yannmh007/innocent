import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/ui/nav_bar_space.dart';
/// Help screen — FAQ items and support contact
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});


  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final faqItems = <(String, String)>[
      (s.hlpQ1, s.hlpA1),
      (s.hlpQ2, s.hlpA2),
      (s.hlpQ3, s.hlpA3),
      (s.hlpQ4, s.hlpA4),
      (s.hlpQ5, s.hlpA5),
      (s.hlpQ6, s.hlpA6),
      (s.hlpQ7, s.hlpA7),
      (s.hlpQ8, s.hlpA8),
    ];
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).help)),
      body: ListView.builder(
        padding: const EdgeInsets.all(16).plusNavBar(context),
        itemCount: faqItems.length,
        itemBuilder: (_, i) {
          final (question, answer) = faqItems[i];
          return ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            iconColor: AppColors.primaryBlue,
            collapsedIconColor: Colors.white38,
            title: Text(
              question,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                child: Text(
                  answer,
                  style: const TextStyle(
                    color: AppColors.white60,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
