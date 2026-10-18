import 'package:flutter/material.dart';

import '../data/base_locale.dart';
import '../models/models.dart';
import '../state/session.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/app_header.dart';
import 'dt_screen.dart';
import 'excavator_screen.dart';
import 'parametres_screen.dart';
import 'spotter_screen.dart';

/// Ecran d'accueil : choix du profil + identifiants de connexion.
///
/// Deux presentations, pilotees par MiseEnPage :
/// - sur grand ecran, les deux colonnes sont cote a cote ;
/// - sur telephone/tablette en portrait, elles s'empilent.
///
/// Aucune zone ne defile : la page tient toujours dans la hauteur visible.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.session});

  final Session session;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  /// Profil choisi, lu dans `base.profils()` (CDC §2.3) : rien n'est ecrit
  /// en dur ici, la base decide de la liste et de leur ordre.
  Profil? _profil;
  String? _id;
  String? _name;

  @override
  void initState() {
    super.initState();
    final List<Profil> profils = widget.session.base.profilsActifs;
    _profil = profils.isEmpty ? null : profils.first;
  }

  void _choisirProfil(Profil profil) {
    setState(() {
      _profil = profil;
      _id = null;
      _name = null;
    });
  }

  void _connecter() {
    final Profil? profil = _profil;
    if (profil == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucun profil disponible.')),
      );
      return;
    }
    if (_id == null || _name == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selectionnez votre identifiant et votre nom.'),
        ),
      );
      return;
    }
    // Les deux menus sont independants (maquette Connexion) : c'est le seul
    // endroit ou l'on refuse un couple qui ne designerait pas un seul et meme
    // equipement. La base decide, l'ecran n'invente rien (REQ-002).
    final String? attendu =
        widget.session.base.nomDuProfil(profil, _id!);
    if (attendu == null || attendu != _name) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Identifiant et nom ne designent pas le meme equipement.',
          ),
        ),
      );
      return;
    }
    // Defense en profondeur : on a change de profil depuis la selection de
    // l'ID (race theorique : un autre widget appelle setState). Si l'ID ne
    // fait plus partie du profil courant, on refuse plutot que d'envoyer une
    // combinaison absurde a la session.
    if (!widget.session.base.idsDuProfil(profil).contains(_id!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selectionnez un identifiant compatible avec le profil.'),
        ),
      );
      return;
    }
    // La validite du login vient des referentiels locaux, pas de l'etat Wi-Fi
    // (une tablette hors ligne doit pouvoir ouvrir son profil).
    final bool connecte =
        widget.session.connect(selected: profil, id: _id!, name: _name!);
    if (!connecte) {
      final String motif = widget.session.base.refusEnCours ??
          'Connexion refusee : referentiels serveur manquants ou obsoletes';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(motif)),
      );
      return;
    }

    // L'ecran suit le role CDC du profil (REQ-002) : TAB 1 = spotter,
    // TAB 2 = DT, TAB 3 = excavatrice. Le libelle, lui, vient de la table.
    final Widget ecran = switch (profil.roleCdc) {
      BaseLocale.roleTab2 => DtScreen(session: widget.session),
      BaseLocale.roleTab3 => ExcavatorScreen(session: widget.session),
      _ => SpotterScreen(session: widget.session),
    };

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => ecran),
    );
  }

  @override
  Widget build(BuildContext context) {
    final MiseEnPage mise = MiseEnPage.depuis(context);

    // Acces aux cles `meta` (PARAMETRES.md §7) : preparer une tablette ne
    // demande aucune connexion, le bouton vit donc sur cet ecran.
    //
    // Le `Transform.translate` decale le bouton vers la droite pour
    // annuler le `margeHorizontale` du Padding parent (32 px quand
    // largeur > 600, 18 sinon) et le coller au bord reel de l'ecran.
    // On utilise une translation plutot qu'un padding negatif pour
    // eviter l'assertion `padding.isNonNegative` levee depuis
    // `shifted_box.dart:117`.
    final double decalageDroitBoutonParametres =
        (MediaQuery.sizeOf(context).width > 600 ? 32.0 : 18.0) - 4;
    final Widget boutonParametres = Align(
      alignment: Alignment.centerRight,
      child: Transform.translate(
        offset: Offset(decalageDroitBoutonParametres, 0),
        child: TextButton.icon(
          key: const ValueKey<String>('bouton-parametres'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ParametresScreen(session: widget.session),
            ),
          ),
          icon: const Icon(Icons.settings, size: 20, color: AppColors.slate),
          label: Text(
            'Parametres',
            style: TextStyle(
              fontSize: (15 * mise.k).clamp(12.0, 15.0),
              fontWeight: FontWeight.w700,
              color: AppColors.slate,
            ),
          ),
        ),
      ),
    );

    // Boutons de profil lus dans la table `profils` (§2.3), jamais dans le
    // code : ajouter un profil revient a ajouter une ligne.
    final List<Profil> profils = widget.session.base.profilsActifs;
    final Widget colonneProfils = _ProfilePicker(
      profils: profils,
      profil: _profil,
      surChangement: _choisirProfil,
      mise: mise,
      compactPortrait: MiseEnPage.estCompactPortrait(context),
    );
    final Widget colonneIdentifiants = _Credentials(
      // Identifiants et noms enrrols lus dans la base (REQ-002) : les deux
      // menus sortent de la meme table, pas du code.
      ids: _profil == null
          ? const <String>[]
          : widget.session.base.idsDuProfil(_profil!),
      noms: _profil == null
          ? const <String>[]
          : widget.session.base.nomsDuProfil(_profil!),
      id: _id,
      nom: _name,
      surId: (v) => setState(() => _id = v),
      surNom: (v) => setState(() => _name = v),
      surConnexion: _connecter,
      mise: mise,
      compactPortrait: MiseEnPage.estCompactPortrait(context),
    );

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, contraintesPage) {
                  final double hauteurUtile = contraintesPage.maxHeight;
                  // Regle unique, exposee par MiseEnPage : evitent les trois
                  // predictions divergentes (cf. fix #3 de l'audit).
                  final bool portraitCompact = MiseEnPage.estCompactPortrait(context) ||
                      hauteurUtile < 720;
                  final double maxLargeur = contraintesPage.maxWidth > 760
                      ? 920
                      : contraintesPage.maxWidth;
                  final double margeHorizontale =
                      contraintesPage.maxWidth > 600 ? 32 : 18;
                  final double margeVerticale = portraitCompact ? 10 : 20;

                  // Aucun defilement : le contenu est centre, jamais scrolle.
                  return Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxLargeur),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: margeHorizontale,
                          vertical: margeVerticale,
                        ),
                        child: _LoginBody(
                          mise: mise,
                          portraitCompact: portraitCompact,
                          hauteurUtile: hauteurUtile,
                          boutonParametres: boutonParametres,
                          profils: colonneProfils,
                          identifiants: colonneIdentifiants,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            AppFooter(mise: mise),
          ],
        ),
      ),
    );
  }
}

/// Corps central de l'ecran de connexion : logo, titre et la zone des deux
/// colonnes (profils + identifiants) en cote-a-cote ou empilees selon la
/// disposition decidee par [MiseEnPage].
///
/// Extrait du build de `_LoginScreenState` pour rendre la methode principale
/// lisible et faciliter le test visuel des deux variantes.
class _LoginBody extends StatelessWidget {
  const _LoginBody({
    required this.mise,
    required this.portraitCompact,
    required this.hauteurUtile,
    required this.boutonParametres,
    required this.profils,
    required this.identifiants,
  });

  final MiseEnPage mise;
  final bool portraitCompact;
  final double hauteurUtile;
  final Widget boutonParametres;
  final Widget profils;
  final Widget identifiants;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: boutonParametres,
        ),
        SizedBox(
          height: portraitCompact ? 90 : mise.hauteurLogo,
          child: Image.asset(
            'assets/images/logo_ore_tracking.png',
            fit: BoxFit.contain,
          ),
        ),
        SizedBox(height: portraitCompact ? 8 : mise.ecartTitre),
        Text(
          'Welcome here, select your profil',
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: portraitCompact ? 24 : mise.policeTitre.clamp(22.0, 32.0),
            fontWeight: FontWeight.w800,
            letterSpacing: portraitCompact ? 0.6 : 1.0 * mise.k,
            color: AppColors.ink,
          ),
        ),
        SizedBox(height: portraitCompact ? 18 : mise.ecartSection),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: portraitCompact ? 500 : double.infinity,
          ),
          child: mise.aEmpile
              ? _StackedBody(
                  profils: profils,
                  identifiants: identifiants,
                  mise: mise,
                  compactPortrait: portraitCompact,
                )
              : _SideBySideBody(
                  profils: profils,
                  identifiants: identifiants,
                  mise: mise,
                  hauteurUtile: hauteurUtile,
                ),
        ),
      ],
    );
  }
}

/// Deux colonnes alignees sur une meme ligne, sans filet vertical.
class _SideBySideBody extends StatelessWidget {
  const _SideBySideBody({
    required this.profils,
    required this.identifiants,
    required this.mise,
    required this.hauteurUtile,
  });

  final Widget profils;
  final Widget identifiants;
  final MiseEnPage mise;
  final double hauteurUtile;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (hauteurUtile - 260).clamp(220.0, 600.0),
      ),
      child: Row(
        children: [
          Expanded(child: profils),
          SizedBox(width: mise.ecartElement),
          Expanded(child: identifiants),
        ],
      ),
    );
  }
}

/// Variante empilee : le wrapper choisit entre cote-a-cote et empile en
/// fonction de [MiseEnPage.aEmpile]. La separation visuelle entre les deux
/// blocs est assuree par [_ColonnesEmpilees].
class _StackedBody extends StatelessWidget {
  const _StackedBody({
    required this.profils,
    required this.identifiants,
    required this.mise,
    required this.compactPortrait,
  });

  final Widget profils;
  final Widget identifiants;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    return _ColonnesEmpilees(
      profils: profils,
      identifiants: identifiants,
      mise: mise,
      compactPortrait: compactPortrait,
    );
  }
}

/// Version telephone : une seule colonne, separee par un trait horizontal.
class _ColonnesEmpilees extends StatelessWidget {
  const _ColonnesEmpilees({
    required this.profils,
    required this.identifiants,
    required this.mise,
    this.compactPortrait = false,
  });

  final Widget profils;
  final Widget identifiants;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        profils,
        SizedBox(height: compactPortrait ? 16 : mise.ecartSection),
        Container(height: 1.5, color: AppColors.ink),
        SizedBox(height: compactPortrait ? 16 : mise.ecartSection),
        identifiants,
      ],
    );
  }
}

class _ProfilePicker extends StatelessWidget {
  const _ProfilePicker({
    required this.profils,
    required this.profil,
    required this.surChangement,
    required this.mise,
    this.compactPortrait = false,
  });

  /// Profils proposes, dans l'ordre de la table `profils`.
  final List<Profil> profils;
  final Profil? profil;
  final ValueChanged<Profil> surChangement;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    final Widget contenu = Column(
      mainAxisAlignment: compactPortrait
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (profils.isEmpty)
          Text(
            'Aucun profil configure.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: (21 * mise.k).clamp(15.0, 21.0),
              fontWeight: FontWeight.w700,
              color: const Color(0xFF70747A),
            ),
          ),
        for (int i = 0; i < profils.length; i++) ...[
          if (i > 0) SizedBox(height: mise.ecartElement),
          _ProfileButton(
            key: ValueKey<String>('profil-${profils[i].code}'),
            libelle: profils[i].libelle,
            selectionne: profils[i] == profil,
            surAppui: () => surChangement(profils[i]),
            hauteur: compactPortrait
                ? (54 * mise.k).clamp(48.0, 58.0)
                : mise.hauteurBouton,
            police: compactPortrait
                ? 18
                : (21 * mise.k).clamp(15.0, 21.0),
          ),
        ],
      ],
    );

    if (mise.aEmpile) {
      return Padding(
        padding: EdgeInsets.symmetric(
          vertical: compactPortrait ? 2 : mise.margeColonne.vertical,
        ),
        child: contenu,
      );
    }

    // Aucun defilement : le contenu est centre dans la colonne.
    return Padding(
      padding: mise.margeColonne,
      child: Center(child: contenu),
    );
  }
}

class _ProfileButton extends StatelessWidget {
  const _ProfileButton({
    super.key,
    required this.libelle,
    required this.selectionne,
    required this.surAppui,
    required this.hauteur,
    required this.police,
  });

  final String libelle;
  final bool selectionne;
  final VoidCallback surAppui;
  final double hauteur;
  final double police;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selectionne ? AppColors.slate : AppColors.greyButton,
      child: InkWell(
        onTap: surAppui,
        child: Container(
          constraints: const BoxConstraints(minHeight: 54),
          height: hauteur < 54 ? 54 : hauteur,
          alignment: Alignment.center,
          child: Text(
            libelle,
            style: TextStyle(
              fontSize: police,
              fontWeight: FontWeight.w700,
              color: selectionne ? Colors.white : const Color(0xFF70747A),
            ),
          ),
        ),
      ),
    );
  }
}

class _Credentials extends StatelessWidget {
  const _Credentials({
    required this.ids,
    required this.noms,
    required this.id,
    required this.nom,
    required this.surId,
    required this.surNom,
    required this.surConnexion,
    required this.mise,
    this.compactPortrait = false,
  });

  /// Identifiants et noms du role choisi, tous deux lus dans `equipements`.
  ///
  /// Meme longueur, meme ordre : les deux menus presentent les lignes de la
  /// meme table, et c'est [BaseLocale.nomDu] qui valide le couple au moment
  /// de la connexion.
  final List<String> ids;
  final List<String> noms;
  final String? id;
  final String? nom;
  final ValueChanged<String?> surId;
  final ValueChanged<String?> surNom;
  final VoidCallback surConnexion;
  final MiseEnPage mise;
  final bool compactPortrait;

  @override
  Widget build(BuildContext context) {
    final Widget contenu = Column(
      mainAxisAlignment: compactPortrait
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectField(
          key: const ValueKey<String>('champ-id'),
          indice: 'Your Id',
          valeur: id,
          elements: ids,
          surChangement: surId,
          mise: mise,
        ),
        SizedBox(height: compactPortrait ? 10 : mise.ecartElement),
        SelectField(
          key: const ValueKey<String>('champ-nom'),
          indice: 'Name',
          valeur: nom,
          elements: noms,
          surChangement: surNom,
          mise: mise,
        ),
        SizedBox(height: compactPortrait ? 10 : mise.ecartElement),
        // Largeur bornee par la colonne : `largeurBouton` plafonne le bouton,
        // mais sur un ecran plus etroit que cette valeur, le bouton prend la
        // largeur disponible au lieu de deborder de la colonne.
        ConstrainedBox(
          key: const ValueKey<String>('bouton-connexion'),
          constraints: BoxConstraints(
            maxWidth: mise.largeurBouton,
            minHeight: compactPortrait
                ? 54
                : (mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton),
            maxHeight: compactPortrait
                ? 54
                : (mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton),
          ),
          child: Material(
            color: AppColors.slate,
            child: InkWell(
              onTap: surConnexion,
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'Connect',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: (24 * mise.k).clamp(16.0, 24.0),
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (mise.aEmpile) {
      return Padding(
        padding: EdgeInsets.symmetric(
          vertical: compactPortrait ? 2 : mise.margeColonne.vertical,
        ),
        child: contenu,
      );
    }

    // Aucun defilement : le contenu est centre dans la colonne.
    return Padding(
      padding: mise.margeColonne,
      child: Center(child: contenu),
    );
  }
}

/// Champ de selection encadre avec chevron (maquette Connexion).
class SelectField extends StatelessWidget {
  const SelectField({
    super.key,
    required this.indice,
    required this.elements,
    required this.surChangement,
    required this.mise,
    this.valeur,
  });

  final String indice;
  final String? valeur;
  final List<String> elements;
  /// Callback appele uniquement avec une valeur reelle (jamais `null`).
  ///
  /// Le [DropdownButton] sous-jacent peut theoriquement appeler `onChanged`
  /// avec `null` quand la liste change, mais en pratique la liste est figee
  /// pendant la duree de vie du widget : on filtre donc ce cas pour exposer
  /// une signature non-null, plus sure pour les appelants.
  final ValueChanged<String> surChangement;
  final MiseEnPage mise;

  @override
  Widget build(BuildContext context) {
    // Taille de police bornee, calculee une seule fois par build : on la
    // partage entre l'indice, la valeur selectionnee et les items du dropdown,
    // ce qui supprime la duplication d'origine (cf. fix #6 de l'audit).
    final double fontSize = (19 * mise.k).clamp(14.0, 19.0);
    final TextStyle baseStyle = TextStyle(
      fontSize: fontSize,
      decoration: TextDecoration.underline,
    );
    final TextStyle styleIndice = baseStyle.copyWith(
      color: const Color(0xFF8A8D91),
    );
    final TextStyle styleValeur = baseStyle.copyWith(color: AppColors.ink);
    final TextStyle styleItem = TextStyle(fontSize: fontSize);

    return Container(
      constraints: BoxConstraints(
        minHeight: mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton,
      ),
      height: mise.hauteurBouton < 54 ? 54 : mise.hauteurBouton,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: valeur,
                isExpanded: true,
                alignment: Alignment.center,
                icon: const SizedBox.shrink(),
                hint: Center(child: Text(indice, style: styleIndice)),
                selectedItemBuilder: (context) => [
                  for (final element in elements)
                    Center(child: Text(element, style: styleValeur)),
                ],
                items: [
                  for (final element in elements)
                    DropdownMenuItem<String>(
                      value: element,
                      child: Center(
                        child: Text(element, style: styleItem),
                      ),
                    ),
                ],
                onChanged: (String? v) {
                  if (v != null) {
                    surChangement(v);
                  }
                },
              ),
            ),
          ),
          Icon(
            Icons.keyboard_arrow_down,
            size: (30 * mise.k).clamp(20.0, 30.0),
          ),
        ],
      ),
    );
  }
}
