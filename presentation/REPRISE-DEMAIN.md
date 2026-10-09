# Dossier présentation — reprise demain

## Objectif de la séance suivante
Livrer un **APK installable** sur le téléphone contenant le **mode démo
offroad** : scénario GPS simulé (sortie de parcours), **bip + vibration**,
**voyants clignotants**, bandeau rouge plein cadre.

## Ce qui est DÉJÀ FAIT (ne pas refaire)
1. `lib/communication/position/service_position.dart`
   - Classe `GpsDemoOffroad` : rejoue en boucle le scénario
     (sur le parcours → détour > 40 m → retour), 1 mesure / 2 s.
2. `lib/state/session.dart`
   - `ouvrirBase(demoOffroad: true)` : injecte le parcours fictif
     (droite UTM vers F5M / RomPad 1) + affectation, puis branche
     `GpsDemoOffroad` comme fournisseur GPS.
   - Le reste de l'app (détection d'écart, alerte, bip, vibration) ne sait
     pas qu'elle est en démo : elle fonctionne comme en production.
3. `lib/screens/splash_screen.dart`
   - **5 taps rapides sur le logo** pendant le splash = activation du mode
     démo. Texte « MODE DEMO OFFROAD » affiché sous le logo en confirmation.
4. `lib/widgets/status_badges.dart`
   - Widget `Clignotant` : fait clignoter (opacité 1 → 0.25, 600 ms) tout
     enfant tant que `session.alerteActive`. Hors alerte : aucun coût.
5. `lib/screens/dt_screen.dart`
   - Voyants 4G / BLE / Wi-Fi / GPS et bannière rouge enveloppés dans
     `Clignotant` : tout clignote pendant l'alerte offroad.
6. Le son : `assets/sons/alerte.wav` existe déjà et est déclaré dans
   `pubspec.yaml` (assets/sons/). `AlerteSysteme` joue le bip + vibration à
   **chaque mesure GPS pendant l'alerte** (choix terrain déjà en place).

## Ce qui RESTE À FAIRE
1. ~~**`flutter build apk --release`**~~ ✅ **fait le 2026-10-09** :
   `build\app\outputs\flutter-apk\app-release.apk` (18,5 Mo).
2. **Copier l'APK dans `presentation/`** (ce dossier) — toujours à faire.
3. Écrire les instructions d'installation dans `presentation/INSTALLER.md`. ✅ fait.

## Code source en ligne
Le projet est versionné sur GitHub : `https://github.com/ivandjeapro-gif/OT2-Tab`
(branche `main`, commit initial `75eeb22`). Reprendre avec `git pull`.

## Instructions d'installation (à copier tel quel)
- Copier `app-release.apk` sur le téléphone (câble USB, mail, drive).
- Sur le téléphone : ouvrir le fichier → Android demandera d'autoriser
  « Installer des applications inconnues » pour la source utilisée.
- Accepter, puis « Installer ». L'application « ore_tracking » apparaît
  dans les applications.
- Premier lancement : splash 3 s → écran de connexion.
- **Activer la démo offroad : taper 5 fois rapidement sur le logo ORE
  Tracking pendant le splash.** Le texte « MODE DEMO OFFROAD » confirme.
- Se connecter avec n'importe quel profil DT : la détection d'écart démarre,
  le scénario quitte le parcours en ~25 s, l'alerte sonore + vibration +
  voyants clignotants + bandeau rouge se déclenchent, puis retour au calme.
