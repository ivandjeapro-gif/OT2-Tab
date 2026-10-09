import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme/app_theme.dart';

/// Carte de suivi du DT : fond OpenStreetMap, trajet du depart vers la
/// destination, camion en route et destination marquees.
///
/// La carte ne lit rien elle meme : elle recoit des points que la session a
/// deja lus dans la base. Le recadrage se fait par la cle du `FlutterMap`,
/// donc uniquement quand la destination change - un tick de synchro de plus
/// deplace le camion sans jamais faire sauter le zoom choisi a la main.
class CarteSuivi extends StatelessWidget {
  const CarteSuivi({
    super.key,
    required this.destination,
    required this.arrivee,
    this.depart,
    this.position,
    this.libelleDestination,
  });

  /// Code de la destination : c'est lui qui pilote le recadrage.
  final String destination;

  /// Point de depart du trajet. Absent => pas de trace, seulement un point.
  final ({double lat, double lng})? depart;

  /// Destination a atteindre.
  final ({double lat, double lng})? arrivee;

  /// Position courante du DT sur le trajet.
  final ({double lat, double lng})? position;

  final String? libelleDestination;

  LatLng _latLng(({double lat, double lng}) p) => LatLng(p.lat, p.lng);

  @override
  Widget build(BuildContext context) {
    final ({double lat, double lng})? arrivee = this.arrivee;
    if (arrivee == null) return const SizedBox.shrink();

    final ({double lat, double lng})? depart = this.depart;
    final ({double lat, double lng})? position = this.position;

    // Les points connus encadrent le trajet : on cadre dessus, avec une
    // marge pour que rien ne colle au bord. maxZoom empeche deux points
    // proches de zoomer jusqu'a des carreaux illisibles.
    final List<LatLng> points = [
      if (depart != null) _latLng(depart),
      _latLng(arrivee),
      if (position != null) _latLng(position),
    ];

    // L'attribution vit hors de la carte, en overlay : celle de flutter_map
    // n'est pas elargie par la fenetre et deborde des que la carte retrecit.
    return ClipRRect(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          FlutterMap(
            key: ValueKey<String>('carte-$destination'),
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(points),
                padding: const EdgeInsets.all(48),
                maxZoom: 17,
              ),
              // La rotation d'un plan de mine se brouille vite : on garde le
              // nord en haut et on laisse zoom/deplacer.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.oretracking.ore_tracking',
                maxZoom: 19,
              ),
              // Trace complet en noir, puis la partie deja parcourue en vert :
              // la meme lecture que la barre de trajet sous le tableau.
              PolylineLayer(
                polylines: [
                  if (depart != null)
                    Polyline(
                      points: [_latLng(depart), _latLng(arrivee)],
                      strokeWidth: 4,
                      color: Colors.black,
                    ),
                  if (depart != null && position != null)
                    Polyline(
                      points: [_latLng(depart), _latLng(position)],
                      strokeWidth: 4,
                      color: AppColors.green,
                    ),
                ],
              ),
              MarkerLayer(
                markers: [
                  if (depart != null)
                    Marker(
                      point: _latLng(depart),
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.fromBorderSide(
                            BorderSide(color: Colors.black, width: 2.5),
                          ),
                        ),
                      ),
                    ),
                  Marker(
                    point: _latLng(arrivee),
                    width: 110,
                    height: 64,
                    // Le drapeau doit se poser sur la destination : le bas du
                    // widget est ancre au point, pas son centre.
                    alignment: Alignment.bottomCenter,
                    child: _Destination(
                      libelle: libelleDestination ?? destination,
                    ),
                  ),
                  if (position != null)
                    Marker(
                      point: _latLng(position),
                      width: 40,
                      height: 40,
                      child: const _Camion(),
                    ),
                ],
              ),
            ],
          ),
          const Positioned(
            right: 4,
            bottom: 4,
            child: _Attribution(),
          ),
        ],
      ),
    );
  }
}

/// Mention « © OpenStreetMap » sous la carte : le texte se reduit (une seule
/// ligne, ellipse) plutot que de deborder quand la carte est etroite.
class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white70,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      child: const Text(
        '© OpenStreetMap',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: kSerif,
          fontSize: 11,
          color: Colors.black54,
        ),
      ),
    );
  }
}

/// Destination : un drapeau noir, avec son code pose au dessus.
class _Destination extends StatelessWidget {
  const _Destination({required this.libelle});

  final String libelle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: AppColors.ink, width: 1.5),
          ),
          child: Text(
            libelle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kSerif,
              fontSize: 13,
              color: AppColors.ink,
            ),
          ),
        ),
        const Icon(Icons.location_on, size: 30, color: Colors.black),
      ],
    );
  }
}

/// Le DT : pastille verte a l'ecusson camion, comme les badges du reseau.
class _Camion extends StatelessWidget {
  const _Camion();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.green,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4),
        ],
      ),
      child: const Icon(Icons.local_shipping, size: 20, color: Colors.white),
    );
  }
}
