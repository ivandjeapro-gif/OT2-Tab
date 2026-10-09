import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

/// Canal d'alerte sonore et vibratoire (choix terrain : signal a chaque
/// mesure GPS tant que le DT reste hors du parcours).
///
/// Interface injectable comme [FournisseurPosition] : les tests branchent
/// [AlerteFactice] et comptent les declenchements au lieu d'attendre un
/// materiel qui vibre.
abstract class AlerteMetier {
  /// Joue un bip court + une vibration. Ne leve jamais : un capteur absent
  /// ou une plateforme sans audio n'arrete pas l'application.
  void jouer();

  /// Libere les ressources systeme (lecteur audio). Vide par defaut.
  void fermer() {}
}

/// Compteur d'appels, pour les tests et le banc.
class AlerteFactice implements AlerteMetier {
  int appels = 0;

  @override
  void jouer() => appels++;

  @override
  void fermer() {}
}

/// Implementation systeme : vibration (`vibration`) + bip WAV embarque
/// (`audioplayers`), avec repli silencieux partout ou la plateforme ne
/// supporte pas l'un des deux (Windows sans vibreur, tests sans audio).
class AlerteSysteme implements AlerteMetier {
  AlerteSysteme({this.cheminBip = 'sons/alerte.wav'});

  /// Fichier WAV joue a chaque declenchemet (asset du package).
  final String cheminBip;

  AudioPlayer? _lecteur;

  @override
  void jouer() {
    _vibrer();
    _bip();
  }

  void _vibrer() {
    // try/catch systematique : vibration n'est pas implemente sur toutes les
    // plateformes, et l'alerte doit rester un bip meme sans vibreur.
    try {
      Vibration.vibrate(duration: 350);
    } catch (_) {
      try {
        // Repli : retour haptique du framework (aucune permission requise).
        HapticFeedback.vibrate();
      } catch (_) {}
    }
  }

  void _bip() {
    // try/catch partout : y compris l'acces a [Platform], indisponible sur
    // certaines cibles — `jouer()` ne doit jamais lever.
    try {
      if (!Platform.isAndroid && !Platform.isIOS && !Platform.isWindows) {
        return;
      }
      final AudioPlayer lecteur = _lecteur ??= AudioPlayer();
      lecteur.stop().then(
            (void _) => lecteur.play(AssetSource(cheminBip)),
            onError: (Object _) {},
          );
    } catch (_) {
      // Pas d'audio sur cette machine : la vibration a deja joue son role.
    }
  }

  @override
  void fermer() {
    _lecteur?.dispose();
    _lecteur = null;
  }
}
