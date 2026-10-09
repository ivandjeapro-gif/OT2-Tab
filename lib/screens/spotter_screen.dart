import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/base_locale.dart';
import '../models/models.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/profile_shell.dart';

/// Ecran du spotter geologique.
///
/// La selection vit dans la session : un blast, puis un bloc de ce blast.
/// Toutes les lignes du tableau et toutes les lignes ajoutees par le bouton
/// `+` appartiennent au bloc selectionne, et la carte vient de ce bloc.
///
/// `Lock` valide le **bloc courant** (paire blast/bloc) : les lignes deja
/// saisies dans ce bloc sont comptees, il est ferme et le bouton `+` devient
/// inactif pour lui — les autres blocs du blast restent ouverts. `Envoyer`
/// transmet ensuite selon le mode parametre (`meta.envoi_mode`) : le blast
/// entier, le bloc courant ou les seuls blocs verrouilles. Changer de bloc ou
/// de blast reste toujours possible, meme sur un bloc verrouille.
class SpotterScreen extends StatefulWidget {
  const SpotterScreen({super.key, required this.session});

  final Session session;

  @override
  State<SpotterScreen> createState() => _SpotterScreenState();
}

class _SpotterScreenState extends State<SpotterScreen> {
  Session get session => widget.session;

  Blast? get _blast => session.blast;
  BlocTravail? get _bloc => session.bloc;
  bool get _verrouille => session.verrouille;

  List<LigneBlast> get _lignes => _bloc?.lignes ?? const <LigneBlast>[];

  /// Nombre de lignes saisies sur le blast entier, et pas seulement sur le
  /// bloc affiche : c'est ce que compte le verrouillage.
  int get _lignesDuBlast {
    final Blast? blast = _blast;
    if (blast == null) return 0;
    return blast.blocs.fold<int>(0, (total, b) => total + b.nombreLignes);
  }

/// Ajoute une ligne dans le bloc selectionne.
  ///
  /// Le blast, le bloc et la carte ne sont pas saisissables : ils viennent de
  /// la selection courante, donc une ligne ne peut pas partir dans un autre
  /// bloc par erreur.
  ///
  /// DT et Id DT sont deux listes liees, lues dans la base : on choisit
  /// d'abord la famille de DT (DT 1500, DT 785...), puis un DT dans le lot de
  /// cette famille. Les identifiants etant non redondants sur tout le parc,
  /// le second menu ne propose jamais le meme numero ailleurs.
  Future<void> _addRecord() async {
    final Blast? blast = _blast;
    final BlocTravail? bloc = _bloc;
    if (blast == null || bloc == null || bloc.verrouille) return;

    final TextEditingController comment = TextEditingController();

    // La photo n'est pas un drapeau : c'est un bouton qui ouvre l'appareil
    // photo et y depose les octets de l'image prise.
    Uint8List? photo;

    // Le type est choisi en premier, puis le numero dans le lot de ce type :
    // les deux listes sont liees, pas independantes.
    String typeChoisi = session.base.typesDT.first.code;
    String? idDtChoisi;

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          final TypeDT? famille = session.base.typeDT(typeChoisi);

          Future<void> capturer(ImageSource source) async {
            final ImagePicker picker = ImagePicker();
            XFile? capture;
            try {
              capture = await picker.pickImage(
                source: source,
                maxWidth: 1600,
                imageQuality: 85,
              );
            } catch (e) {
              if (!context.mounted) return;
              session.push(
                source == ImageSource.camera
                    ? 'Appareil photo indisponible : $e - choisissez plutot '
                        'une image dans la galerie'
                    : 'Galerie indisponible : $e',
              );
              return;
            }

            // capture null = l'utilisateur a abandonne : on ne force rien.
            if (capture == null || !context.mounted) return;
            try {
              final Uint8List octets = await capture.readAsBytes();
              // La lecture est asynchrone : le dialogue a pu fermer entre
              // temps, et un setState sur un StatefulBuilder defunt casserait
              // le moteur.
              if (!context.mounted) return;
              setStateDialog(() => photo = octets);
            } catch (e) {
              if (!context.mounted) return;
              session.push('Photo illisible : $e');
            }
          }

          // Le bouton n'impose rien : on demande d'abord ou la photo vient,
          // puis on ouvre la source demandee.
          Future<void> choisirPhoto() async {
            final ImageSource? source = await showDialog<ImageSource>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Picture'),
                children: [
                  SimpleDialogOption(
                    onPressed: () =>
                        Navigator.pop(context, ImageSource.camera),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.photo_camera,
                          size: 26,
                          color: AppColors.green,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Appareil photo',
                                style: TextStyle(
                                  fontFamily: kSerif,
                                  fontSize: 16,
                                  color: AppColors.ink,
                                ),
                              ),
                              Text(
                                'Prendre une photo maintenant',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF9A9DA1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SimpleDialogOption(
                    onPressed: () =>
                        Navigator.pop(context, ImageSource.gallery),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.photo_library_outlined,
                          size: 26,
                          color: AppColors.green,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Galerie',
                                style: TextStyle(
                                  fontFamily: kSerif,
                                  fontSize: 16,
                                  color: AppColors.ink,
                                ),
                              ),
                              Text(
                                'Choisir une image dans les dossiers '
                                    'du telephone',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF9A9DA1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );

            // Fermeture sans choix : on ne force rien.
            if (source == null || !context.mounted) return;
            await capturer(source);
          }

          return AlertDialog(
          title: const Text('Nouvelle ligne'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rappel non modifiable du contexte : la ligne rejoint le bloc
                // actuellement affiché, pas un bloc choisi dans le formulaire.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F5),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Text(
                    'Blast ${blast.numero}   Bloc ${bloc.numero}   '
                    'Carte ${blast.carte}',
                    style: const TextStyle(
                      fontFamily: kSerif,
                      fontSize: 17,
                      color: AppColors.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Liste 1 : la famille de DT (DT 1500, DT 785, DT 1000...).
                // Une vraie liste deroulante : on clique, elle s'ouvre, on
                // choisit. Le menu affiche le nombre de DT de chaque famille.
                DropdownButtonFormField<String>(
                  initialValue: typeChoisi,
                  isExpanded: true,
                  style: const TextStyle(
                    fontFamily: kSerif,
                    fontSize: 16,
                    color: AppColors.ink,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'DT',
                    labelStyle: TextStyle(
                      fontFamily: kSerif,
                      letterSpacing: 1,
                      color: AppColors.slate,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final TypeDT option in session.base.typesDT)
                      DropdownMenuItem<String>(
                        value: option.code,
                        child: Text('${option.libelle}  (${option.nombreDts})'),
                      ),
                  ],
                  onChanged: (String? code) {
                    if (code == null) return;
                    setStateDialog(() {
                      typeChoisi = code;
                      // Les identifiants sont non redondants : changer de
                      // famille invalide le numero retenu, on le remet a
                      // zero plutot que de garder un DT mal classe.
                      final TypeDT? nouvelle = session.base.typeDT(code);
                      if (idDtChoisi != null &&
                          nouvelle?.contient(idDtChoisi!) != true) {
                        idDtChoisi = null;
                      }
                    });
                  },
                ),
                const SizedBox(height: 14),
                // Liste 2 : les DT de la famille choisie. Le menu se remplit
                // en fonction de la premiere liste.
                DropdownButtonFormField<String>(
                  initialValue: idDtChoisi,
                  isExpanded: true,
                  hint: Text(
                    famille == null
                        ? 'Aucun DT'
                        : 'Select dans ${famille.libelle}',
                    style: const TextStyle(
                      fontFamily: kSerif,
                      fontSize: 16,
                      color: Color(0xFF9A9DA1),
                    ),
                  ),
                  style: const TextStyle(
                    fontFamily: kSerif,
                    fontSize: 16,
                    color: AppColors.ink,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Id DT',
                    labelStyle: TextStyle(
                      fontFamily: kSerif,
                      letterSpacing: 1,
                      color: AppColors.slate,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final String id in session.idsDuType(typeChoisi))
                      DropdownMenuItem<String>(
                        value: id,
                        child: Text('DT $id'),
                      ),
                  ],
                  onChanged: (String? id) =>
                      setStateDialog(() => idDtChoisi = id),
                ),
                const SizedBox(height: 14),
                // Picture : un bouton, pas une case a cocher. Il demande
                // d'abord la source (appareil photo ou galerie), puis
                // affiche la vignette de l'image retenue.
                _BoutonPhoto(
                  photo: photo,
                  onTap: choisirPhoto,
                  onClear: photo == null
                      ? null
                      : () => setStateDialog(() => photo = null),
                ),
                TextField(
                  controller: comment,
                  decoration: const InputDecoration(labelText: 'Comment'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.slate,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (idDtChoisi == null) {
                  Navigator.pop(context, false);
                  session.push(
                    'Choisissez un numero de DT dans le lot '
                    '$typeChoisi avant d\'enregistrer',
                  );
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Enregistrer'),
            ),
          ],
        );
        },
      ),
    );

    final String commentaire = comment.text.trim();
    comment.dispose();

    if (saved != true) return;

    // Dart ne promeut pas cette variable : elle est reassignee par les
    // closures du formulaire. On fige la valeur retenue avant l'ecriture.
    final String idRetenu = idDtChoisi ?? '';
    final Uint8List? octetsPhoto = photo;
    if (idRetenu.isEmpty) return;

    final DateTime now = DateTime.now();
    final bool ok = session.ajouterLigne(
      LigneBlast(
        time:
            '${now.hour.toString().padLeft(2, '0')}h'
            '${now.minute.toString().padLeft(2, '0')}',
        dt: typeChoisi,
        idDt: idRetenu,
        hasPicture: octetsPhoto != null,
        photo: octetsPhoto,
        comment: commentaire,
      ),
    );

    if (!ok) return;
    session.push(
      'Ligne ajoutee - blast ${blast.numero}, bloc ${bloc.numero} '
      '(carte ${blast.carte})',
    );
    setState(() {});
  }

  /// Confirmation avant de fermer le **bloc courant** (paire blast/bloc) :
  /// la validation est definitive pour ce bloc, on ne peut plus rien y
  /// ajouter ensuite — les autres blocs du blast ne sont pas touches.
  Future<void> _toggleLock() async {
    final Blast? blast = _blast;
    final BlocTravail? bloc = _bloc;
    if (blast == null || bloc == null) return;

    if (bloc.verrouille) {
      final bool? ouvrir = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            'Deverrouiller le bloc ${bloc.numero} '
            'du blast ${blast.numero} ?',
          ),
          content: const Text(
            'Vous pourrez de nouveau ajouter des lignes dans ce bloc.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.slate,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Deverrouiller'),
            ),
          ],
        ),
      );
      if (ouvrir == true) session.deverrouillerBloc();
      return;
    }

    final int sansPicture = bloc.lignes
        .where((LigneBlast l) => !l.hasPicture)
        .length;

    final bool? valider = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Enregistrer et verrouiller le bloc ${bloc.numero} '
          'du blast ${blast.numero} ?',
        ),
        content: Text(
          '${bloc.nombreLignes} ligne(s) enregistreee(s) dans ce bloc.\n\n'
          'Aucune ligne ne pourra plus etre ajoutee dans ce bloc. Les autres '
          'blocs du blast restent ouverts, et vous pourrez toujours consulter '
          'les donnees et changer de bloc ou de blast.\n\n'
          'Sans picture : $sansPicture',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.slate,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );

    if (valider == true) session.verrouillerBloc();
  }

  /// Nombre de lignes du perimetre d'envoi courant, selon [Session.envoiMode].
  int get _lignesDuPerimetre {
    final Blast? blast = _blast;
    if (blast == null) return 0;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        return _bloc?.nombreLignes ?? 0;
      case BaseLocale.envoiModeVerrouilles:
        return blast.blocs
            .where((BlocTravail b) => b.verrouille)
            .fold<int>(0, (int t, BlocTravail b) => t + b.nombreLignes);
      default:
        return _lignesDuBlast;
    }
  }

  /// Nombre de blocs du perimetre d'envoi courant.
  int get _blocsDuPerimetre {
    final Blast? blast = _blast;
    if (blast == null) return 0;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        return _bloc == null ? 0 : 1;
      case BaseLocale.envoiModeVerrouilles:
        return blast.blocs.where((BlocTravail b) => b.verrouille).length;
      default:
        return blast.nombreBlocs;
    }
  }

  /// Vrai si le perimetre du mode courant est pret a partir : verrouille et
  /// non vide. C'est ce que compte le bouton `Envoyer`.
  bool get _envoiPret {
    final Blast? blast = _blast;
    if (blast == null) return false;
    if (blast.envoye) return false;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        final BlocTravail? bloc = _bloc;
        return bloc != null && bloc.verrouille && bloc.nombreLignes > 0;
      case BaseLocale.envoiModeVerrouilles:
        return _blocsDuPerimetre > 0 && _lignesDuPerimetre > 0;
      default:
        return blast.verrouille && _lignesDuBlast > 0;
    }
  }

  /// Annonce le refus que la base produirait, avant d'ouvrir la fenetre.
  /// Inutile de proposer un envoi que la base refusera ; elle reste elle
  /// seule juge au moment de l'ecriture.
  String? _motifEnvoiImpossible() {
    final Blast? blast = _blast;
    if (blast == null) return 'Aucun blast selectionne : rien a envoyer';
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        final BlocTravail? bloc = _bloc;
        if (bloc == null) return 'Aucun bloc selectionne : rien a envoyer';
        if (!bloc.verrouille) {
          return 'Bloc ${bloc.numero} non verrouille : verrouillez-le avant '
              'd\'envoyer les donnees';
        }
        if (bloc.nombreLignes == 0) {
          return 'Bloc ${bloc.numero} sans donnee : rien a envoyer';
        }
      case BaseLocale.envoiModeVerrouilles:
        if (_blocsDuPerimetre == 0) {
          return 'Aucun bloc verrouille dans le blast ${blast.numero} : '
              'verrouillez au moins un bloc avant d\'envoyer';
        }
        if (_lignesDuPerimetre == 0) {
          return 'Aucune donnee dans les blocs verrouilles : rien a envoyer';
        }
      default:
        if (!blast.verrouille) {
          return 'Blast ${blast.numero} non verrouille : verrouillez-le avant '
              'd\'envoyer les donnees';
        }
        if (blast.nombreLignes == 0) {
          return 'Blast ${blast.numero} sans donnee : rien a envoyer';
        }
    }
    if (blast.envoye) return 'Blast ${blast.numero} deja envoye';
    return null;
  }

  /// Transmet les donnees sauvegardees du perimetre courant au point d'acces.
  ///
  /// La fenetre annonce le perimetre exact du mode en cours : blast entier,
  /// bloc courant ou blocs verrouilles.
  Future<void> _envoyer() async {
    final Blast? blast = _blast;
    if (blast == null) return;

    final String? motif = _motifEnvoiImpossible();
    if (motif != null) {
      session.push(motif);
      return;
    }

    final String perimetre;
    switch (session.envoiMode) {
      case BaseLocale.envoiModeBloc:
        perimetre =
            'Bloc ${_bloc!.numero} du blast ${blast.numero} - '
            '${_bloc!.nombreLignes} ligne(s), carte ${blast.carte}.';
      case BaseLocale.envoiModeVerrouilles:
        perimetre =
            'Les $_blocsDuPerimetre bloc(s) verrouille(s) du blast '
            '${blast.numero} - $_lignesDuPerimetre ligne(s), '
            'carte ${blast.carte}.';
      default:
        perimetre =
            '$_lignesDuBlast ligne(s) sur ${blast.nombreBlocs} bloc(s), '
            'carte ${blast.carte}.';
    }

    final bool? confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Envoyer les donnees du blast ${blast.numero} ?'),
        content: Text(
          '$perimetre\n\n'
          'Les donnees sauvegardees seront transmises au point d\'acces '
          'Master.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.slate,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Envoyer'),
          ),
        ],
      ),
    );

    if (confirme == true) session.envoyerDonnees();
  }

  /// Les deux listes deroulantes lisent la base, jamais une liste en dur :
  /// `Select blast` et `Select bloc` y puisent leurs options.
  Future<void> _choisirBlast() async {
    final List<String> numeros = session.base.numerosBlast;
    final String? choisi = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select blast'),
        children: [
          for (final numero in numeros)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, numero),
              child: _BlastOption(
                numero: numero,
                blast: session.base.parNumero(numero)!,
                actif: numero == _blast?.numero,
              ),
            ),
        ],
      ),
    );
    if (choisi != null) session.selectionnerBlast(choisi);
  }

  Future<void> _choisirBloc() async {
    final Blast? blast = _blast;
    if (blast == null) return;
    final String? choisi = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select bloc'),
        children: [
          // Blocs du blast courant, lus dans la base.
          for (final bloc in session.base.blocsDe(blast.numero))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, bloc.numero),
              child: _BlocOption(
                bloc: bloc,
                carte: blast.carte,
                actif: bloc == _bloc,
              ),
            ),
        ],
      ),
    );
    if (choisi != null) session.selectionnerBloc(choisi);
  }

  /// Ouvre le plan du blast courant dans une fenetre, en pleine place.
  ///
  /// Le bouton `Afficher map` n'a aucun menu : la carte est deja celle du
  /// blast, il n'y a rien a choisir. Il sert juste a voir le plan, que la
  /// vignette du bouton est trop petite pour lire.
  void _afficherCarte() {
    final Blast? blast = _blast;
    if (blast == null) return;

    final Size ecran = MediaQuery.sizeOf(context);
    // Le plan est cale sur la fenetre (titre + boutons prennent le reste) :
    // un multiple fixe de la hauteur debordait des la fenetre basse. Le
    // defilement de secours couvre le cas ou la boite reste trop haute.
    final double largeur = (ecran.width * 0.7).clamp(0.0, 720.0).toDouble();
    final double hauteur = (ecran.height * 0.45).clamp(0.0, 480.0).toDouble();
    final String libelle = session.base.libelleCarte(blast.carte) ?? '';

    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Carte ${blast.carte}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Blast ${blast.numero} - $libelle',
                style: const TextStyle(
                  fontFamily: kSerif,
                  fontSize: 15,
                  color: AppColors.slate,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border, width: 1.5),
                ),
                // La carte est un plan taille : on peut la pincer pour lire un
                // detail, la vignette du bouton ne le permet pas.
                child: InteractiveViewer(
                  maxScale: 6,
                  child: SizedBox(
                    width: largeur,
                    height: hauteur,
                    child: Image.asset(
                      blast.plan,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stack) => SizedBox(
                        width: largeur,
                        height: hauteur,
                        child: const Center(
                          child: Text(
                            'Plan introuvable',
                            style: TextStyle(color: AppColors.slate),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Toute lecture de la selection (blast, bloc, ligne, verrou) se fait
    // DANS le builder du ListenableBuilder : lu avant, elle serait figee au
    // dernier build de cet etat, et les boutons afficheraient encore l'ancien
    // choix alors que la session a deja change.
    return ProfileShell(
      session: session,
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final MiseEnPage mise = MiseEnPage.depuis(context);
          final Blast? blast = _blast;
          final BlocTravail? bloc = _bloc;

          return Padding(
            padding: mise.margeEcran,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cinq boutons d'un meme rang ne tiennent plus des qu'une
                // fenetre fait moins de 700 px de contenu : on coupe en deux
                // ranges (selection, puis carte + verrou + envoi) plutot que
                // d'ecraser les boutons jusqu'a ce qu'ils debordent.
                LayoutBuilder(
                  builder: (context, contraintes) {
                    final List<Widget> boutons = [
                      _FilterButton(
                        titre: 'Select blast',
                        valeur: blast?.numero,
                        detail: blast == null
                            ? null
                            : '${blast.nombreBlocs} bloc(s)',
                        onTap: _choisirBlast,
                      ),
                      _FilterButton(
                        titre: 'Select bloc',
                        valeur: bloc?.numero,
                        detail: bloc == null
                            ? null
                            : '${bloc.nombreLignes} ligne(s)'
                                  '${bloc.verrouille ? ' - verrouille' : ''}',
                        onTap: _choisirBloc,
                      ),
                      // La carte appartient au blast, pas au bloc : le choix du
                      // blast la selectionne de facto, donc ce bouton n'expose
                      // aucun menu, il ouvre seulement le plan en grand.
                      _FilterButton(
                        titre: 'Afficher map',
                        valeur: blast?.carte,
                        detail: blast == null
                            ? null
                            : session.base.libelleCarte(blast.carte),
                        lectureSeule: true,
                        apercu: session.planCourant,
                        onTap: _afficherCarte,
                      ),
                      // Le cadenas porte sur le bloc courant (paire
                      // blast/bloc) : verrouiller le bloc 8 n'empeche pas
                      // d'ecrire dans le bloc 6 du meme blast.
                      _LockButton(
                        verrouille: _verrouille,
                        numero: bloc?.numero,
                        onTap: _toggleLock,
                      ),
                      // L'envoi porte ce qui est deja enregistre : le perimetre
                      // depend du mode (blast, bloc courant ou blocs
                      // verrouilles), et le bouton se fige une fois l'envoi fait.
                      _SendButton(
                        pret: _envoiPret,
                        envoye: blast?.envoye ?? false,
                        onTap: _envoyer,
                      ),
                    ];

                    final List<Widget> ecarts = [
                      for (var i = 1; i < boutons.length; i++)
                        SizedBox(width: 14 * mise.k),
                    ];

                    if (contraintes.maxWidth < 700) {
                      return Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: boutons[0]),
                              SizedBox(width: 14 * mise.k),
                              Expanded(child: boutons[1]),
                            ],
                          ),
                          SizedBox(height: 14 * mise.k),
                          Row(
                            children: [
                              Expanded(child: boutons[2]),
                              SizedBox(width: 14 * mise.k),
                              Expanded(child: boutons[3]),
                              SizedBox(width: 14 * mise.k),
                              Expanded(child: boutons[4]),
                            ],
                          ),
                        ],
                      );
                    }

                    return Row(
                      children: [
                        for (var i = 0; i < boutons.length; i++) ...[
                          if (i > 0) ecarts[i - 1],
                          Expanded(child: boutons[i]),
                        ],
                      ],
                    );
                  },
                ),
                SizedBox(height: 14 * mise.k),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.border, width: 1.5),
                    ),
                    child: Column(
                      children: [
                        const _TableHeader(),
                        Expanded(
                          // Un bloc peut contenir une centaine de lignes :
                          // la liste doit defiler sous l'en-tete.
                          child: _lignes.isEmpty
                              ? const _Vide()
                              : ListView.separated(
                                  padding: EdgeInsets.zero,
                                  itemCount: _lignes.length,
                                  separatorBuilder: (context, _) =>
                                      const Divider(height: 1),
                                  itemBuilder: (context, i) => _TableRow(
                                    ligne: _lignes[i],
                                    blast: blast?.numero ?? '-',
                                    bloc: bloc?.numero ?? '-',
                                  ),
                                ),
                        ),
                        _AddStrip(
                          onAdd: (blast == null ||
                                  bloc == null ||
                                  bloc.verrouille)
                              ? null
                              : _addRecord,
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 6 * mise.k),
                Text(
                  blast == null && session.base.numerosBlast.isEmpty
                      ? 'Aucun blast - en attente du serveur'
                      : blast == null || bloc == null
                            ? 'Aucun bloc selectionne'
                            : 'Bloc ${bloc.numero} - carte ${blast.carte} - '
                                  '${_lignes.length} ligne(s) affichee(s) sur '
                                  '$_lignesDuBlast pour le blast ${blast.numero}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15 * mise.k,
                    color: const Color(0xFF9A9DA1),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BlastOption extends StatelessWidget {
  const _BlastOption({
    required this.numero,
    required this.blast,
    required this.actif,
  });

  final String numero;
  final Blast blast;
  final bool actif;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            numero,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: actif ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${blast.nombreBlocs} bloc(s)'
            '${blast.verrouille ? ' - verrouille' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, color: AppColors.slate),
          ),
        ),
      ],
    );
  }
}

/// Bouton « Picture » du formulaire.
///
/// Ce n'est pas une case a cocher : un tap demande d'abord la source
/// (appareil photo Android ou image deja presente dans le telephone), puis
/// la vignette de l'image retenue remplace le texte. Le X permet de retirer
/// une photo prise par erreur.
class _BoutonPhoto extends StatelessWidget {
  const _BoutonPhoto({
    required this.photo,
    required this.onTap,
    this.onClear,
  });

  final Uint8List? photo;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final bool pris = photo != null;

    return Material(
      color: pris ? const Color(0xFFF7F9F5) : Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: AppColors.border,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.photo_camera,
                size: 26,
                color: AppColors.green,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Picture',
                      style: TextStyle(
                        fontFamily: kSerif,
                        fontSize: 16,
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      pris
                          ? 'Photo chargee - retoucher'
                          : 'Prendre une photo ou charger une image',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF9A9DA1),
                      ),
                    ),
                  ],
                ),
              ),
              if (pris) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Image.memory(
                    photo!,
                    width: 66,
                    height: 44,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => Container(
                      width: 66,
                      height: 44,
                      color: const Color(0xFFEFF0F1),
                      child: const Icon(Icons.broken_image, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: onClear,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 20, color: AppColors.slate),
                  ),
                ),
              ] else
                const Icon(
                  Icons.chevron_right,
                  size: 26,
                  color: AppColors.border,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Un bloc de la liste « Select bloc », avec la carte du blast dont il tient.
///
/// La carte est reportee par la vue : elle appartient au blast, pas au bloc,
/// donc on ne la lit pas sur l'entite. Le cadenas signale un bloc verrouille
/// (paire blast/bloc) : la saisie y est fermee, mais le bloc reste choissable
/// pour le consulter.
class _BlocOption extends StatelessWidget {
  const _BlocOption({
    required this.bloc,
    required this.carte,
    required this.actif,
  });

  final BlocTravail bloc;

  /// Carte du blast qui contient [bloc].
  final String carte;
  final bool actif;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  'Bloc ${bloc.numero}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (bloc.verrouille) ...[
                const SizedBox(width: 6),
                const Icon(
                  Icons.lock,
                  size: 15,
                  color: AppColors.slate,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '$carte - ${bloc.nombreLignes} ligne(s)'
            '${bloc.verrouille ? ' - verrouille' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, color: AppColors.slate),
          ),
        ),
      ],
    );
  }
}

class _Vide extends StatelessWidget {
  const _Vide();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Aucune ligne sur ce bloc',
        style: TextStyle(fontSize: 17, color: Color(0xFF9A9DA1)),
      ),
    );
  }
}

const _columns = [
  'Times',
  'Blast',
  'Bloc',
  'DT',
  'Id DT',
  'Picture',
  'Comment',
];
const _weights = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.7];

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    // En-tete du tableau : hauteur libre bornee par la place restante. Les
    // 46 px de reference sont un plafond, pas une exigence : sur une fenetre
    // basse l'en-tete se comprime au lieu de pousser le tableau hors de
    // l'ecran.
    return Container(
      color: AppColors.bar,
      constraints: const BoxConstraints(maxHeight: 46),
      height: double.infinity,
      child: Row(
        children: [
          for (var i = 0; i < _columns.length; i++)
            Expanded(
              flex: (_weights[i] * 10).round(),
              child: Container(
                alignment: Alignment.center,
                decoration: i == 0
                    ? null
                    : const BoxDecoration(
                        border: Border(
                          left: BorderSide(color: Colors.white, width: 1),
                        ),
                      ),
                child: Text(
                  _columns[i].spaced,
                  style: const TextStyle(
                    fontFamily: kSerif,
                    fontSize: 15,
                    letterSpacing: 1,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.ligne,
    required this.blast,
    required this.bloc,
  });

  final LigneBlast ligne;

  /// Blast et bloc de la ligne, redonnes a l'affichage : ils sont portes par
  /// l'arbre, pas par la ligne.
  final String blast;
  final String bloc;

  @override
  Widget build(BuildContext context) {
    // DT est la categorie, Id DT le numero du DT dans cette categorie : deux
    // colonnes distinctes, comme dans le formulaire.
    final values = [
      ligne.time,
      blast,
      bloc,
      ligne.dt,
      ligne.idDt,
      '',
      ligne.comment,
    ];
    return SizedBox(
      // 44 px en reference, mais jamais plus que la place disponible : idem
      // l'en-tete, la ligne se comprime sur une fenetre basse.
      height: 44,
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              flex: (_weights[i] * 10).round(),
              child: Container(
                alignment: Alignment.center,
                decoration: i == 0
                    ? null
                    : const BoxDecoration(
                        border: Border(
                          left: BorderSide(color: AppColors.border, width: 1),
                        ),
                      ),
                child: i == 5
                    ? InkWell(
                        onTap: () => _voirPhoto(context, ligne),
                        child: Icon(
                          ligne.hasPicture
                              ? Icons.document_scanner
                              : Icons.add_a_photo_outlined,
                          size: 20,
                          color: AppColors.green,
                        ),
                      )
                    : Text(
                        values[i],
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: kSerif,
                          fontSize: 17,
                          color: AppColors.ink,
                        ),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Affiche la photo prise pour une ligne.
///
/// Les octets sont conserves en base (colonne `lignes.photo`) et repartent
/// avec l'evenement LINE_ADD : la photo survit donc a l'arret de
/// l'application et part en ligne comme le reste du formulaire. Une ligne
/// sans octets (pas de photo, ou photo saisie sur un autre poste) est
/// signalee au lieu d'afficher un cadre vide.
void _voirPhoto(BuildContext context, LigneBlast ligne) {
  final Uint8List? octets = ligne.photo;

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Photo ${ligne.idDt}'),
      content: octets == null
          ? const SizedBox(
              width: 280,
              child: Text(
                'Aucune image enregistree sur ce poste pour cette ligne.',
                style: TextStyle(fontSize: 15, color: AppColors.slate),
              ),
            )
          : Image.memory(
              octets,
              width: 320,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => const Text(
                'Image illisible.',
                style: TextStyle(color: AppColors.slate),
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}

class _AddStrip extends StatelessWidget {
  const _AddStrip({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.tan,
      constraints: const BoxConstraints(maxHeight: 40),
      height: double.infinity,
      child: Center(
        child: InkWell(
          onTap: onAdd,
          child: Container(
            width: 34,
            height: 26,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(
              Icons.add,
              size: 18,
              color: onAdd == null ? AppColors.border : AppColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

/// Bloc de selection, avec son titre (`Select blast`, `Select bloc`) visible
/// meme une valeur choisie.
///
/// En mode [lectureSeule] (`Afficher map`), le bloc n'a pas de menu ni de
/// chevron : la valeur est deja choisie ailleurs, le tap ouvre un apercu
/// (voir [_SpotterScreenState._afficherCarte]) plutot qu'une liste.
class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.titre,
    this.onTap,
    this.valeur,
    this.detail,
    this.lectureSeule = false,
    this.apercu,
  });

  final String titre;
  final String? valeur;
  final String? detail;

  /// Ouvre la liste. En mode lecture seule c'est l'apercu de la carte.
  final VoidCallback? onTap;

  /// La valeur est celle du blast, deja chargee : rien a selectionner, donc
  /// pas de menu, pas de chevron, et pas de grise meme quand le blast est
  /// ferme (consulter la carte reste toujours possible).
  final bool lectureSeule;

  /// Plan JPG du blast courant, affiche en vignette dans le bloc.
  final String? apercu;

  @override
  Widget build(BuildContext context) {
    // Pas d'`Expanded` ici : c'est le rang (large ou etroit) qui donne sa
    // largeur au bouton, sinon le meme widget ne peut plus passer d'un rang
    // a l'autre.
    return InkWell(
      onTap: onTap,
      child: LayoutBuilder(
        builder: (context, contraintes) {
          // La vignette cote a cote pese 68 px fixes : des qu'un rang
          // etroit ne lui laisse plus de place, elle disparait et le texte
          // garde le bouton pour lui.
          final bool vignette =
              apercu != null && contraintes.maxWidth >= 170;

          return Container(
            height: 62,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border, width: 1.5),
              color: Colors.white,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                if (vignette) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Image.asset(
                      apercu!,
                      width: 56,
                      height: 40,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) => Container(
                        width: 56,
                        height: 40,
                        color: const Color(0xFFEFF0F1),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titre,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: kSerif,
                          fontSize: 13,
                          letterSpacing: 1,
                          color: AppColors.slate,
                        ),
                      ),
                      if (valeur != null)
                        Text(
                          valeur!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kSerif,
                            fontSize: 19,
                            color: AppColors.ink,
                          ),
                        ),
                    ],
                  ),
                ),
                if (detail != null)
                  Flexible(
                    child: Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: kSerif,
                        fontSize: 12,
                        color: Color(0xFF9A9DA1),
                      ),
                    ),
                  ),
                // Pas de chevron sur un bloc qui n'ouvre aucun menu : le
                // chevron annonce une liste deroulante.
                // Le chevron annonce une liste deroulante. En lecture seule,
                // le bouton ouvre un apercu : on met l'icone d'agrandissement.
                if (lectureSeule)
                  const Icon(
                    Icons.fullscreen,
                    size: 26,
                    color: AppColors.slate,
                  )
                else
                  const Icon(
                    Icons.keyboard_arrow_down,
                    size: 28,
                    color: AppColors.ink,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Bouton « Envoyer » : transmet au point d'acces les donnees deja
/// enregistrees, donc uniquement sur un blast verrouille.
///
/// Une fois l'envoi fait, le bouton passe en « Envoye » et se fige : il ne
/// redevient actif que si le blast est rouvert, puis de nouveau verrouille.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.pret,
    required this.envoye,
    required this.onTap,
  });

  /// Vrai quand les donnees sont pretes : blast verrouille et non vide.
  final bool pret;

  /// Vrai des que la transmission a reussi.
  final bool envoye;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool actif = pret && !envoye;
    final Color encre = envoye
        ? AppColors.green
        : actif
            ? AppColors.ink
            : const Color(0xFF9A9DA1);

    // Comme les filtres : la largeur vient du rang, pas d'ici.
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.5),
          color: actif ? Colors.white : const Color(0xFFF3F4F5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: Center(
                // Le libelle est espaces comme la maquette, mais il tient
                // dans un bloc plus etroit que Lock : on le reduit plutot
                // que de deborder.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    (envoye ? 'Envoye' : 'Envoyer').spaced,
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontSize: 19,
                      letterSpacing: 4,
                      color: encre,
                    ),
                  ),
                ),
              ),
            ),
            Icon(
              envoye
                  ? Icons.check_circle_outline
                  : Icons.upload_outlined,
              size: 24,
              color: encre,
            ),
          ],
        ),
      ),
    );
  }
}

class _LockButton extends StatelessWidget {
  const _LockButton({
    required this.verrouille,
    required this.onTap,
    this.numero,
  });

  final bool verrouille;
  final String? numero;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Comme les filtres : la largeur vient du rang, pas d'ici.
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border, width: 1.5),
          color: verrouille ? AppColors.slate : Colors.white,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  'Lock'.spaced,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontSize: 19,
                    letterSpacing: 4,
                    color: verrouille ? Colors.white : AppColors.ink,
                  ),
                ),
              ),
            ),
            Icon(
              verrouille ? Icons.lock : Icons.lock_open,
              size: 24,
              color: verrouille ? Colors.white : AppColors.ink,
            ),
          ],
        ),
      ),
    );
  }
}
