import 'package:flutter/material.dart';

import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/profile_shell.dart';
import '../widgets/status_badges.dart';

/// Ecran de l'excavatrice : compteurs E/N/E rafraichis a chaque synchro.
class ExcavatorScreen extends StatelessWidget {
  const ExcavatorScreen({super.key, required this.session});

  final Session session;

  @override
  Widget build(BuildContext context) {
    return ProfileShell(
      session: session,
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          // Meme mise en page que les deux autres ecrans profils : meme
          // marge, memes echelles, donc les blocs commencent aux memes
          // coordonnees d'un ecran a l'autre.
          final MiseEnPage mise = MiseEnPage.depuis(context);
          final double k = mise.k;

          return Padding(
            padding: mise.margeEcran,
            // En paysage large et bas (ou en fenetre reduite), le tableau ne
            // tient plus sous l'en-tete : il defile au lieu de deborder. En
            // paysage tablette il n'y a rien a defiler, le rendu est identique.
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      (MediaQuery.sizeOf(context).height -
                              mise.margeEcran.vertical)
                          .clamp(0.0, double.infinity),
                ),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Reseaux externes (vers le serveur) a gauche du nom :
                    // la 4G, comme sur l'ecran DT. `remplir: true` : ce badge
                    // n'est pas dans une ligne a partager, il prend donc sa
                    // taille de reference.
                    GsmStatusBadge(etat: session.etat4G, remplir: true),
                    Expanded(
                      child: Center(
                        child: Column(
                          children: [
                            Text(
                              session.deviceName.isEmpty
                                  ? (session.profile?.titre ?? 'Excavator')
                                  : session.deviceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: kSerif,
                                fontSize: (54 * k).clamp(24.0, 54.0),
                                color: AppColors.ink,
                              ),
                            ),
                            SizedBox(height: 4 * k),
                            Text(
                              'Synchro #${session.syncCount}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: kSerif,
                                fontSize: (18 * k).clamp(12.0, 18.0),
                                color: const Color(0xFF6E7278),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Liens et capteurs a droite du nom : BLE (voyant
                    // bluetooth, lien vers le DT), Wi-Fi hotspot (voyant
                    // wifi) et GPS externe USB-C.
                    Padding(
                      padding: EdgeInsets.only(right: 12 * k),
                      child: BleStatusBadge(etat: session.etatBle, remplir: true),
                    ),
                    SizedBox(width: 10 * k),
                    GpsStatusBadge(etat: session.etatGps, remplir: true),
                  ],
                ),
                SizedBox(height: 22 * k),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border, width: 1.5),
                    ),
                    // L'en-tete et les valeurs se partagent la hauteur
                    // disponible : le tableau se resserre avec la fenetre au
                    // lieu d'ajouter des hauteurs fixes et de deborder.
                    child: Column(
                      children: [
                        Expanded(
                          flex: 64,
                          child: Container(
                            color: AppColors.tan,
                            child: IntrinsicHeight(
                              child: Row(
                                children: [
                                  for (var i = 0; i < 3; i++) ...[
                                    if (i > 0)
                                      Container(
                                        width: 1.5,
                                        color: AppColors.border,
                                      ),
                                    Expanded(
                                      child: Container(
                                        height: double.infinity,
                                        alignment: Alignment.center,
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            const [
                                              'Easting',
                                              'Northing',
                                              'Elevation',
                                            ][i],
                                            style: TextStyle(
                                              fontFamily: kSerif,
                                              fontSize: (24 * k)
                                                  .clamp(13.0, 24.0),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 180,
                          child: Container(
                            color: Colors.white,
                            alignment: Alignment.center,
                            child: Row(
                              children: [
                                for (var i = 0; i < 3; i++) ...[
                                  if (i > 0)
                                    Container(
                                      width: 2.5,
                                      height: double.infinity,
                                      color: AppColors.ink,
                                    ),
                                  Expanded(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 12 * k,
                                        ),
                                        child: Text(
                                          i == 0
                                              ? '${session.easting}'
                                              : i == 1
                                                  ? '${session.northing}'
                                                  : '${session.elevation}',
                                          style: TextStyle(
                                            fontFamily: kSerif,
                                            fontSize: (72 * k)
                                                .clamp(28.0, 72.0),
                                            color: AppColors.ink,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 10 * k),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
