import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Bandeau gris du haut : logo Lafigue + filet + logo ORE Tracking.
class AppHeader extends StatelessWidget {
  const AppHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final double k = mise.k;
    return Container(
      color: AppColors.bar,
      height: mise.hauteurEntete,
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/images/logo_lafigue.png',
            height: (46 * k).clamp(24.0, 46.0),
            fit: BoxFit.contain,
          ),
          SizedBox(width: 28 * k),
          Container(width: 1.5, height: (52 * k).clamp(28.0, 52.0), color: Colors.white),
          SizedBox(width: 28 * k),
          Image.asset(
            'assets/images/logo_ore_tracking.png',
            height: (58 * k).clamp(30.0, 58.0),
            fit: BoxFit.contain,
          ),
        ],
      ),
    );
  }
}

/// Pied de page gris des ecrans de connexion (logo Lafigue blanc).
class AppFooter extends StatelessWidget {
  const AppFooter({super.key, this.mise});

  final MiseEnPage? mise;

  @override
  Widget build(BuildContext context) {
    final MiseEnPage m = mise ?? MiseEnPage.depuis(context);
    return Container(
      color: AppColors.bar,
      height: m.hauteurBandeau,
      alignment: Alignment.center,
      child: Image.asset(
        'assets/images/logo_lafigue.png',
        height: 44 * m.k,
        fit: BoxFit.contain,
      ),
    );
  }
}
