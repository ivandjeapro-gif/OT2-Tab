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
/// - sur grand ecran, les deux colonnes sont cote a cote et partagent
///   exactement le meme haut et le meme bas ;
/// - sur telephone, elles s'empilent dans un defilement unique.
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
    widget.session.connect(selected: profil, id: _id!, name: _name!);

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
    final Widget boutonParametres = Align(
      alignment: Alignment.centerRight,
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
    );

    // Boutons de profil lus dans la table `profils` (§2.3), jamais dans le
    // code : ajouter un profil revient a ajouter une ligne.
    final List<Profil> profils = widget.session.base.profilsActifs;
    final Widget colonneProfils = _ProfilePicker(
      profils: profils,
      profil: _profil,
      surChangement: _choisirProfil,
      mise: mise,
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
    );

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: mise.margePage,
                child: Column(
                  children: [
                    boutonParametres,
                    // Le logo est borne par la place disponible : sur une
                    // fenetre basse il se reduit au lieu de pousser le reste
                    // hors de l'ecran.
                    Flexible(
                      fit: FlexFit.loose,
                      child: Image.asset(
                        'assets/images/logo_ore_tracking.png',
                        height: mise.hauteurLogo,
                        fit: BoxFit.contain,
                      ),
                    ),
                    SizedBox(height: mise.ecartTitre),
                    Text(
                      'Welcome here, select your profil',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: mise.policeTitre,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5 * mise.k,
                        color: AppColors.ink,
                      ),
                    ),
                    // Ecart fixe et reglable entre le titre et le formulaire.
                    // C'est un `SizedBox` : la distance ne depend plus du
                    // partage de la place libre avec le formulaire, elle vaut
                    // exactement `ecartSection` (40 px sur la tablette).
                    SizedBox(height: mise.ecartSection),
                    Expanded(
                      child: mise.aEmpile
                          ? _ColonnesEmpilees(
                              profils: colonneProfils,
                              identifiants: colonneIdentifiants,
                              mise: mise,
                            )
                          : Row(
                              children: [
                                Expanded(child: colonneProfils),
                                SizedBox(width: mise.margeFilet),
                                _FiletVertical(mise: mise),
                                SizedBox(width: mise.margeFilet),
                                Expanded(child: colonneIdentifiants),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ),
            AppFooter(mise: mise),
          ],
        ),
      ),
    );
  }
}

/// Trait vertical entre les deux colonnes, volontairement plus court que la
/// zone disponible et espace des deux cotes.
class _FiletVertical extends StatelessWidget {
  const _FiletVertical({required this.mise});

  final MiseEnPage mise;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1.5,
      child: FractionallySizedBox(
        heightFactor: mise.ratioFilet,
        child: Container(color: AppColors.ink),
      ),
    );
  }
}

/// Version telephone : une seule colonne defilante, separee par un trait
/// horizontal.
class _ColonnesEmpilees extends StatelessWidget {
  const _ColonnesEmpilees({
    required this.profils,
    required this.identifiants,
    required this.mise,
  });

  final Widget profils;
  final Widget identifiants;
  final MiseEnPage mise;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          profils,
          SizedBox(height: mise.ecartSection),
          Container(height: 1.5, color: AppColors.ink),
          SizedBox(height: mise.ecartSection),
          identifiants,
        ],
      ),
    );
  }
}

class _ProfilePicker extends StatelessWidget {
  const _ProfilePicker({
    required this.profils,
    required this.profil,
    required this.surChangement,
    required this.mise,
  });

  /// Profils proposes, dans l'ordre de la table `profils`.
  final List<Profil> profils;
  final Profil? profil;
  final ValueChanged<Profil> surChangement;
  final MiseEnPage mise;

  @override
  Widget build(BuildContext context) {
    final Widget contenu = Column(
      // Flux vertical simple : les deux colonnes font la meme hauteur (3
      // elements de hauteur identique, 2 ecarts egaux) donc elles restent
      // alignees en haut et en bas sans espace entre leurs elements.
      mainAxisAlignment: MainAxisAlignment.start,
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
            hauteur: mise.hauteurBouton,
            police: (21 * mise.k).clamp(15.0, 21.0),
          ),
        ],
      ],
    );

    if (mise.aEmpile) {
      return Padding(padding: mise.margeColonne, child: contenu);
    }

    // Hauteur bornee : le contenu est centre s'il tient, defile sinon.
    return Padding(
      padding: mise.margeColonne,
      child: LayoutBuilder(
        builder: (context, contraintes) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: contraintes.maxHeight),
            child: contenu,
          ),
        ),
      ),
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
          height: hauteur,
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

  @override
  Widget build(BuildContext context) {
    final Widget contenu = Column(
      // Meme hauteur que la colonne des profils, donc meme haut et meme bas.
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        SelectField(
          key: const ValueKey<String>('champ-id'),
          indice: 'Your Id',
          valeur: id,
          elements: ids,
          surChangement: surId,
          mise: mise,
        ),
        SizedBox(height: mise.ecartElement),
        SelectField(
          key: const ValueKey<String>('champ-nom'),
          indice: 'Name',
          valeur: nom,
          elements: noms,
          surChangement: surNom,
          mise: mise,
        ),
        SizedBox(height: mise.ecartElement),
        // Largeur bornee par la colonne : `largeurBouton` plafonne le bouton,
        // mais sur un ecran plus etroit que cette valeur, le bouton prend la
        // largeur disponible au lieu de deborder de la colonne.
        ConstrainedBox(
          key: const ValueKey<String>('bouton-connexion'),
          constraints: BoxConstraints(
            maxWidth: mise.largeurBouton,
            minHeight: mise.hauteurBouton,
            maxHeight: mise.hauteurBouton,
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
      return Padding(padding: mise.margeColonne, child: contenu);
    }

    return Padding(
      padding: mise.margeColonne,
      child: LayoutBuilder(
        builder: (context, contraintes) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: contraintes.maxHeight),
            child: contenu,
          ),
        ),
      ),
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
  final ValueChanged<String?> surChangement;
  final MiseEnPage mise;

  @override
  Widget build(BuildContext context) {
    final TextStyle styleIndice = TextStyle(
      fontSize: (19 * mise.k).clamp(14.0, 19.0),
      color: const Color(0xFF8A8D91),
      decoration: TextDecoration.underline,
    );
    final TextStyle styleValeur = TextStyle(
      fontSize: (19 * mise.k).clamp(14.0, 19.0),
      color: AppColors.ink,
      decoration: TextDecoration.underline,
    );

    return Container(
      height: mise.hauteurBouton,
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
                          child: Text(
                            element,
                            style: TextStyle(
                              fontSize: (19 * mise.k).clamp(14.0, 19.0),
                            ),
                          ),
                      ),
                    ),
                ],
                onChanged: surChangement,
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
