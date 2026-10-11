import 'dart:async';

import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';

/// Bandeau de notification defilant (bas de l'ecran).
///
/// Deux regimes :
/// - **alerte active** ([Session.alerteActive]) : le message d'alerte est
///   force en rouge, plein cadre, sans defilement — une sortie de parcours
///   ne doit jamais etre noyee entre deux notifications de synchro ;
/// - **regime normal** : le ticker fait defiler les derniers evenements
///   reels journalises par la session (connexions, ACK, synchro serveur).
///   Plus aucun message de demo n'est produit par l'application.
class NotificationTicker extends StatefulWidget {
  const NotificationTicker({super.key, required this.session});

  final Session session;

  @override
  State<NotificationTicker> createState() => _NotificationTickerState();
}

class _NotificationTickerState extends State<NotificationTicker> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted) return;
      final total = widget.session.notifications.length;
      if (total == 0) return;
      setState(() => _index = (_index + 1) % total);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);
    final bool enAlerte = widget.session.alerteActive;

    // Alerte : un seul message, rouge, pas de defilement (le message ne
    // bouge pas tant que le DT reste hors parcours).
    if (enAlerte) {
      return Container(
        height: mise.hauteurTicker,
        decoration: const BoxDecoration(color: AppColors.red),
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        child: Text(
          widget.session.alerteCourante,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: (26 * mise.k).clamp(18.0, 30.0),
            letterSpacing: 0.5,
          ),
        ),
      );
    }

    // Regime normal : defilement des evenements reels.
    final messages = widget.session.notifications;
    final message = messages.isEmpty ? '' : messages[_index % messages.length];
    return Container(
      height: mise.hauteurTicker,
      // color: + clipBehavior: leve l'assertion de Container (le clip exige
      // un decoration). On passe donc par BoxDecoration.
      decoration: const BoxDecoration(color: AppColors.bar),
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 450),
        switchInCurve: Curves.easeOut,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.6, 0), end: Offset.zero)
                .animate(animation),
            child: child,
          ),
        ),
        child: Text(
          message,
          key: ValueKey<String>(message),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: (17 * mise.k).clamp(11.0, 17.0),
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
