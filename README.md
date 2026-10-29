# Toolbox

Un « iLovePDF » qui tourne entièrement sur ton Mac, plus un éditeur LaTeX, un gestionnaire de cours,
une banque d'annales et un tableau de bord. Aucun document n'est envoyé où que ce soit.

Appli native (Swift, SwiftUI, PDFKit, Vision) et commande terminal `pdftool`, qui partagent le même moteur.

- **100 % local** : PDF, cours, notes et index de recherche restent sur le Mac. L'IA (Annalyse, explications
  LaTeX, formules) tourne avec [Ollama](https://ollama.com), sur la machine.
- **Seules exceptions**, si tu les utilises : la météo (Open-Meteo, sans compte) et la liste de tes dépôts GitHub.

---

## Premier lancement

La Feuille pose quelques questions (relançables dans Réglages → Général) :
- **ton prénom** ;
- **étudiant ?** Si oui : dossier de cours et, en option, la maquette L1 Informatique (CERI) dans Notes & ECTS.
  Si non : Mes cours, Révisions, Notes & ECTS et leurs widgets sont masqués ;
- **tu travailles ? où ?** Si oui : ton nom tel qu'il apparaît sur le planning, le nom du calendrier dédié
  (« Macdo » pour un McDonald's) qui est créé tout de suite. Si non : Planning et ses widgets sont masqués ;
- **tes appareils** : iPhone (widgets Scriptable, batterie de l'iPhone) et casque Nothing (détecté s'il est
  appairé). Sans eux, les pages, lignes et réglages correspondants disparaissent ;
- **les outils à installer** : Homebrew, LaTeX (BasicTeX + les paquets des modèles), Ghostscript, Ollama et un
  modèle IA choisi selon la RAM du Mac (3B jusqu'à 12 Go, 7B au-delà). Ce qui est déjà là est coché « Installé », la
  place nécessaire est comparée à l'espace libre, et l'installation se fait dans le Terminal (mot de passe tapé
  là-bas, jamais dans Toolbox) ;
- tes apps favorites et deux permissions (Calendrier, Notes).

Tout se rechange ensuite dans **Réglages → Général → Mon profil / Outils à installer**.

## Accueil

La page d'ouverture : une mascotte animée (la Feuille) et des widgets à disposer comme on veut.

| Widget | Ce qu'il fait |
|---|---|
| **Actions rapides** | Nouveau document LaTeX, capture → texte, signer, fusionner, compresser, comparer, déposer une annale |
| **Mes apps** | Lanceur d'apps (VS Code Insiders, iTerm2, Discord… par défaut), point vert si l'app est ouverte, **⌃⌥1 … ⌃⌥9** depuis n'importe où |
| **Mes cours** | Le cours en ce moment (d'après le calendrier), une tuile par matière, les derniers fichiers ouverts |
| **Projets VS Code** | Dossiers épinglés et derniers dossiers de VS Code Insiders : un clic les ouvre |
| **Aujourd'hui** | Événements du jour de l'app Calendrier |
| **Pense-bête** | Crée une note dans l'app Notes en un clic, affiche une note épinglée façon post-it, ajoute des lignes à la note épinglée |
| **Météo** | Température, ciel, ressenti, vent et les 8 prochaines heures. N'apparaît qu'avec une connexion internet |
| **Notes & ECTS** | Moyenne de l'année, anneau des crédits acquis, note qu'il te faut sur ce qui reste pour valider chaque semestre |
| **Planning** | Prochain shift, heures de la semaine (et du contrat), alerte si un shift tombe sur un cours ou un CC |
| **Mon Mac** | Batterie (jauge, temps restant ou de charge, santé et cycles, alerte à 20 / 10 / 5 %), processeur, mémoire, disque libre, température, depuis quand le Mac est allumé |
| **Comptes à rebours** | Jours restants avant tes CC, partiels, examens (repérés dans le calendrier ou ajoutés à la main) |
| **Presse-papiers** | Les 20 derniers textes copiés, recopiés d'un clic. Rien sur le disque, mots de passe ignorés |
| **Dossier surveillé** | Tout PDF déposé dans un dossier choisi est compressé et/ou passé à l'OCR (résultat dans « Traités par Toolbox ») |
| **GitHub** | Tes dépôts récents (privés compris avec `gh`) : ouvrir sur GitHub, cloner, ouvrir dans VS Code Insiders |
| **Fichiers récents**, **Tous les outils** | Ce que tu as ouvert dans Toolbox, et un accès à chaque outil |

**Disposer les widgets :**
- La **poignée** en haut de chaque widget sert à le déplacer : il se soulève, les autres s'écartent pour lui laisser la place.
- **Personnaliser** permet d'ajouter ou de retirer des widgets (avec une liste à cocher) et de les passer en demi-largeur ou pleine largeur.

**La mascotte** met des lunettes de soleil s'il fait beau, sort un parapluie sous la pluie et un bonnet sous la neige.
Elle dort la nuit, saute quand on clique dessus et fait la fête quand une compilation LaTeX repasse sans erreur.

---

## Mes cours

Lit ton dossier de cours (ex. `uapv-cours/cours`) et le présente **par matière**, sans rien déplacer ni renommer.

**Organisation de l'affichage**
- **Matières détectées automatiquement** : un dossier qui contient `cours/`, `TDs/`, `TPs/` ou `CCs/` est une matière.
  Ses voisins aussi (ex. `POO/c`, `POO/cpp`). Les matières sont rangées par domaine (Maths, Programmation…).
- **Séances regroupées** : « TD 4 » réunit `TD4-Bascules.pdf`, `TD4-Instructions.pdf`, `TD4.py`…
  Les numéros sont reconnus sous toutes leurs formes (`TD3`, `TP_2`, `chap4`, `5-Logique`, `CC1`, un dossier `1/`…).
- Un sous-dossier qui ne contient que des documents (`cours/2027/`, `CCs/CC1/`) est **déplié**.
  Un dossier de code (`TPs/TP3/`) reste un bloc, ouvert dans VS Code Insiders.
- S'il y a plusieurs dossiers d'années (`cours/2026`, `cours/2027`), seule l'année la plus récente est affichée,
  sauf pour les CC et annales.
- Les fichiers de compilation et les caches (`.o`, `.dtbo`, `__pycache__`…) sont masqués.

**Ouvrir et chercher**
- **Aperçu intégré** (Coup d'œil). Double-clic : le PDF s'ouvre dans Aperçu, le code et les dossiers de TP dans
  VS Code Insiders, le `.tex` dans l'éditeur LaTeX de Toolbox.
- **Recherche sur les noms et dans le contenu** : texte des PDF, des fichiers texte et du code, photos lues par OCR.
  Le PDF s'ouvre à la bonne page, le mot surligné. L'index est local (`~/Library/Application Support/Toolbox/IndexCours.json`).
- **⌥Espace depuis n'importe quelle app** : mini-fenêtre de recherche dans tes cours.

**Travailler**
- **Nouveau** : le TP ou TD suivant (dossier créé et ouvert dans VS Code Insiders), la **note du jour**
  (`notes/AAAA-MM-JJ.md` ou `.tex`), les **photos du tableau** (rangées dans `notes/photos JJ.MM.AAAA/`, rendues cherchables).
- **▶ dernier TD/TP** rouvre ce sur quoi tu travaillais.
- **Avancement** : chaque séance a une pastille *À revoir*, *Fait* ou *Compris*. Chaque matière a une barre de progression.
- **Corrigés cachés** : les fichiers « correction », « corrigé » ou « solution » sont masqués derrière un bouton,
  pour ne pas tomber dessus avant d'avoir cherché.
- **Masquer** un fichier ou une séance par clic droit (rien n'est supprimé).
- **Glisser des fichiers** sur une matière les copie dans le bon sous-dossier d'après leur nom.

**Calendrier et Annalyse**
- **Cours en ce moment** : bannière et notification au début du cours, avec les boutons *Ouvrir le dernier TD/TP*,
  *Nouveau TP* et *Voir la matière*. Ajoute des alias à une matière (clic droit → Renommer, couleur, alias)
  si ton emploi du temps ne l'appelle pas pareil.
- **S'entraîner** compose un sujet avec les annales de la matière (Annalyse).

---

## Ma journée

- **Check du matin** (Réglages → Général) : chaque matin à l'heure choisie (7 h 30 par défaut), une notification
  résume la journée : cours du jour (calendrier), shift, prochain CC et avancement, et ce qu'il faut recharger
  (Mac si la journée est longue, casque, iPhone). Mac en veille à l'heure dite : il arrive au réveil. Option : aussi sur
  l'iPhone via un rappel.
  **Réveil programmé** (même réglage) : le Mac se réveille 5 min avant le check (`pmset repeat`, mot de passe demandé),
  du lundi au vendredi ou tous les jours.
- **Veille** : juste avant de dormir, le Mac envoie un dernier état (« 💤 en veille depuis 23:12 » sur l'iPhone) ;
  au réveil, tout est relu et renvoyé (batterie, casque).
- **Widget iPhone « Ma journée »** (Scriptable, grand ou moyen) : cours (le soir, ceux de demain), shift avec pauses,
  prochain CC avec barre d'avancement, et la batterie du Mac, du casque et de l'iPhone. Données : `ToolboxDay.json`.

## Casque (page « Casque »)

- Batterie (gauche / droite / boîtier pour des écouteurs), réduction de bruit, égaliseur, renfort des basses, faible
  latence, faire sonner, firmware, et un bouton « Rechercher le casque ».
- **Mode cours** (page Casque, barre des menus, ⌘K) : active un mode de concentration sur le Mac, donc sur l'iPhone
  (« Partager entre les appareils »), et déconnecte le casque (ou transparence / réduction coupée). Automatique au
  début et à la fin des cours si tu veux. La concentration passe par deux raccourcis de l'app Raccourcis
  (« Toolbox Concentration On / Off », action « Définir la concentration »).
- **Mode automatique** : transparence pendant un cours (repéré dans le calendrier comme dans Mes cours), mode habituel
  le reste du temps, faible latence quand un jeu est au premier plan.

## Révisions

- **Tes CC viennent du calendrier** : le calendrier « CCs/Soutenance » (ou tout calendrier nommé CC, Examens,
  Partiels…, réglable) est lu automatiquement. Chaque CC à venir reçoit sa **checklist**, rattachée à la bonne matière
  d'après son titre (nom, nom du dossier ou alias de la matière).
- **Checklist prête** : relire chaque chapitre, refaire chaque TD, revoir les TP, faire les annales de CC, s'entraîner
  avec Annalyse, faire une fiche. Chaque ligne a ses **fichiers en un clic** (le corrigé à part, en grisé).
  Ajoute tes propres tâches, glisse un fichier pour l'ajouter, retire une section entière.
- **Le prochain CC est épinglé** en haut : J-x, avancement, rythme (« environ 2 tâches par jour pour finir à temps »)
  et **avertissement en rouge** si tu es en retard (moins de 7 jours et moins de la moitié faite).
- Cocher une séance la marque *Fait* dans Mes cours. Un CC déplacé ou renommé dans le calendrier suit tout seul.
- Partout : widget **Prochain CC** sur l'accueil, bandeau sur la page de la matière, entrée dans ⌘K.
- Un CC absent du calendrier : *Nouvelle révision*.

## Notes & ECTS

- **Années → semestres → UE → matières (EC) → épreuves**, comme sur la maquette : chaque UE a son code, son nom et
  ses crédits ECTS, chaque matière son code, son coefficient et ses épreuves (CC1, CC2…). Une UE peut aussi rester
  simple (épreuves directement). « Importer mes matières » crée une UE par matière de *Mes cours*.
- **Maquette L1 Informatique (CERI)** en un clic (menu *Année*) : les 3 UE de chaque semestre avec leurs matières et
  leurs codes, plus UE d'ouverture, sport, PIX et renforcement **hors moyenne**. Il reste à saisir les ECTS et
  coefficients. Elle règle aussi : pas de rattrapage, compensation entre UE et entre S1 et S2.
- **UE hors moyenne** (ouverture, sport, PIX…) : notées à part, sans peser sur la moyenne ni être compensées.
- **Moyennes** de chaque UE, de chaque semestre (pondérées par les ECTS) et de l'année, provisoires tant que tout
  n'est pas noté.
- **La note qu'il te faut** sur les épreuves restantes pour valider l'UE, le semestre et l'année.
  Si ce n'est plus atteignable, il te le dit et compte sur la compensation.
- **Crédits acquis** : UE ≥ 10, ou compensée si le semestre (ou l'année) est validé. Règles réglables : compensation
  semestrielle et annuelle, note plancher, rattrapage ou pas (colonne *Ratt.* masquée s'il n'y en a pas).
- **Simulation** : tape des notes imaginaires (en violet) pour voir ce que ça donnerait.
- **Nouvelle année** : même maquette, avec les UE validées reportées (*Acquise l'an dernier*) pour un redoublement.

## Calculatrice

Trois modes en haut de la page :
- **Graphique** : tout ce qui suit.
- **Scientifique** : comme la calculatrice du Mac en mode scientifique. Pavé complet (x², xʸ, eˣ, 10ˣ, √, ∛, ʸ√x, ln,
  log, x!, sin/cos/tan et leurs réciproques avec *2nde*, sinh…, π, e, EE, Rand, mémoire mc/m+/m−/mr), degrés ou
  radians, résultat en direct pendant la frappe, parenthèses fermées toutes seules, historique cliquable, `ans`.
- **Programmeur** : bases HEX / DEC / OCT / BIN affichées ensemble (un clic change la base de saisie), 8 à 64 bits,
  signé (complément à 2) ou non, AND, OR, XOR, NOR, NOT, décalages, rotations, inversion des octets, modulo, bits
  cliquables, caractère Unicode correspondant, saisie au clavier (chiffres, A–F, & | ^ ~ < >).


- **Calculs** comme sur papier : `2x`, `sin x`, `x²`, `√x`, `|x|`, `3!`, `ln(2)·3`, `ans`. Le résultat donne aussi
  sa forme exacte quand il la devine (`1/3`, `3π/4`, `√2/2`).
- **Fonctions** : `f(x) = …` les trace, `f(2)` et `f'(1)` les évaluent. Une lettre inconnue (`a`, `k`…) devient un
  **paramètre avec un curseur**.
- **Graphe** : molette pour zoomer, glisser pour déplacer, pincer sur le trackpad, lecture des valeurs au pointeur,
  repère standard ou orthonormé, cadrage automatique.
- **Conversion en LaTeX** : bouton *TeX* sur chaque fonction (`\frac`, `\sqrt`, `\mathrm{e}^{…}`, `\sin^{2}`…),
  copie entre `$…$` ou insertion directe dans le document LaTeX ouvert. Le graphe s'exporte en **TikZ/pgfplots**
  ou en image, le tableau de valeurs en `tabular`.
- **Valeurs** : tableau pour plusieurs fonctions, départ et pas réglables.
- **Limites** : estimation en un point ou en ±∞, à gauche et à droite, avec le tableau des valeurs qui s'en approchent.
- **Étude** : dérivée **exacte** (symbolique, simplifiée), tangente au point cliqué, annulations, extremums et
  points d'inflexion dans la fenêtre.
- La palette **⌘K** calcule aussi directement (`2^10` → Entrée copie le résultat).

Les limites et les points remarquables sont des estimations numériques : elles donnent le résultat, la copie doit
toujours le justifier.

## Planning

- **Importer** une photo, une capture d'écran (zone à sélectionner), un PDF ou du texte collé.
  Le texte est lu sur le Mac (OCR Vision), puis les créneaux sont reconnus : `Lundi 03/11 9h-14h30`, `mar. 4 nov 11:00-15:30`,
  coupures (`9h-12h 18h-22h`), fermetures après minuit (`18h → 1h`), plannings en colonnes (un jour par colonne).
- **Plannings d'équipe** : ne garde que la ligne avec ton prénom.
- Avant d'ajouter : chaque créneau est **modifiable** (jour, heures, pause), le texte lu peut être corrigé puis relu.
- **Calendrier** : les shifts y sont ajoutés (calendrier, titre et rappel au choix).
- **Heures** : présence moins la pause non payée (règle réglable), total de la semaine et du mois, comparaison avec
  les heures du contrat, récap du mois à copier pour vérifier la fiche de paie.
- **Alertes** : un shift qui chevauche un cours, ou qui tombe le jour d'un CC ou d'un partiel, est signalé.
- **Widget iPhone** (app gratuite Scriptable) : prochain shift, compte à rebours, pauses, heures de la semaine,
  sur l'écran d'accueil ou l'écran verrouillé. Toolbox écrit `Toolbox.json` dans iCloud à chaque changement du planning ;
  Réglages du Planning → *Installer les widgets dans Scriptable* dépose les scripts tout seuls.
- **Scripts iPhone = lanceurs** : le script installé dans Scriptable ne fait que charger
  `iCloud Drive/Toolbox/code/<nom>.js`, que Toolbox met à jour. Plus rien à recopier après une mise à jour.
- **Widget iPhone « Mon Mac »** : batterie, temps restant, processeur, mémoire, disque, santé de la batterie,
  envoyés chaque minute (`ToolboxMac.json`). « Mac en veille ? » si rien n'est arrivé depuis 10 min.
- **Casque Nothing / CMF** : batterie lue directement sur le casque (canal Bluetooth privé de Nothing X, protocole
  documenté par le projet libre BudsLink) toutes les 5 minutes et à chaque connexion au Mac. Affichée dans « Mon Mac »
  (Mac et iPhone), avec la dernière valeur connue quand il est déconnecté, et un rappel quand il passe sous le seuil.
  **Panneau de contrôle** (clic sur la ligne du casque) : réduction de bruit (faible, moyenne, forte, adaptative),
  transparence, égaliseur, renfort des basses (5 niveaux), faible latence, faire sonner le casque, firmware.
  Aussi dans ⌘K (« Casque : transparence »…) et dans la barre des menus.
- **Batterie de l'iPhone sur le Mac** : les widgets Scriptable envoient la batterie du téléphone (`ToolboxPhone.json`) ;
  elle s'affiche dans « Mes appareils », avec une notification sur le Mac sous le seuil. Réglages et scripts :
  Accueil → Personnaliser → *Widgets sur l'iPhone*.
- **Alerte batterie sur l'iPhone** : sous 20 % (réglable dans Réglages → Général), Toolbox crée un rappel
  « 🔋 Recharge ton Mac » dans l'app Rappels, qui sonne sur l'iPhone et se coche tout seul quand le Mac est branché.

---

## Outils PDF

| Section | Outil | Ce qu'il fait |
|---|---|---|
| Pages | **Organiser** | Miniatures : glisser pour réordonner, pivoter, supprimer, extraire, ajouter les pages d'autres PDF |
| | **Fusionner** | Plusieurs PDF → un seul, ordre par glisser-déposer |
| | **Diviser** | Une page par fichier, toutes les N pages, plages (`1-3, 5, 8-`), extraction |
| | **Mise en page** | Rogner les marges (auto ou en mm, sans perte), 2 ou 4 pages par feuille, livret A5 |
| Optimiser | **Compresser & archiver** | PDF : 3 niveaux, Ghostscript si installé, sinon PDFKit. **Archives** : créer un .zip, .tar.gz, .tar.bz2, .tar.xz ou .7z (fichiers et dossiers, 3 niveaux, mot de passe en zip ou 7z AES, sans fichiers parasites, sans fichiers LaTeX, mode « prêt à rendre » pour un TP sans .git ni binaires) ; **extraire** en voyant le contenu avant, tout ou une sélection, avec mot de passe |
| | **OCR** | Rend les scans cherchables et copiables (Vision d'Apple, hors ligne, français + anglais) |
| Modifier | **Numéroter & filigrane** | Numéros de page, en-tête, pied de page, filigrane, avec aperçu en direct |
| | **Sécurité & infos** | Ajouter / retirer un mot de passe, modifier titre, auteur, sujet, mots-clés |
| | **Comparer** | Deux versions d'un PDF : pages appariées même si on en a ajouté ou retiré, superposition (rouge = supprimé, vert = ajouté), côte à côte, différences de texte, rapport PDF |
| | **Signer** | Signature dessinée au trackpad ou importée (fond blanc retiré), posée, déplacée et redimensionnée sur la page, PDF signé (texte toujours sélectionnable) |
| Convertir | **Convertir** | Images → PDF, PDF → PNG/JPEG, PDF → texte, **export RAG** (Markdown ou JSONL, une entrée par page) |
| Automatiser | **Traitement par lots** | OCR → numérotation/filigrane → auteur → compression → renommage, sur tout un dossier |

**Capture d'écran → texte** (⇧⌘T, ⌘K, barre des menus) : tu sélectionnes une zone de l'écran, le texte est lu hors ligne et copié.

---

## IA locale (Ollama)

Toolbox **démarre Ollama tout seul** au lancement s'il ne tourne pas (Réglages → Général → IA locale) : il ouvre l'app
Ollama si elle est installée, sinon lance `ollama serve` en arrière-plan (et l'arrête en quittant). Le serveur seul ne
prend presque pas de mémoire : un modèle n'est chargé qu'au moment d'une demande. Modèle conseillé sur un MacBook Air :
`ollama pull qwen2.5-coder:7b`.

## LaTeX

Un petit Overleaf hors ligne : le code à gauche, le PDF à droite.

**Éditer**
- Coloration, numéros de ligne, **fermeture automatique** de `{ [ $`, `\begin{…}` qui ajoute son `\end{…}`.
- **Complétion** des commandes, des environnements, des `\ref{}` (tes `\label`), des `\cite{}` (clés `.bib`) et des images.
- **Plan** cliquable (sections, exercices), **onglets** pour les fichiers `\input` / `\include`.
- **Glisser une image** : copiée dans `images/` et bloc `figure` ajouté. **Coller un tableau** depuis Excel ou Numbers : `tabular`.

**Compiler**
- Compilation **⌘B** (latexmk, pdflatex, xelatex ou lualatex). Enregistrement auto, recompilation pendant la frappe (« Auto »).
- **Erreurs cliquables** et bouton **✨ Expliquer** : l'IA locale explique l'erreur et propose les lignes corrigées, à appliquer en un clic.
- **SyncTeX** dans les deux sens : ⌘-clic dans le PDF, ou « Curseur → PDF » (⌘L).

**Le reste**
- **Historique** : une version gardée à chaque compilation, comparaison et restauration.
- **Mes documents** (⇧⌘O, bouton dans la barre, ⌘K, ou la liste sous « Nouveau document » quand rien n'est ouvert) :
  tous les documents créés avec Toolbox, ceux de `Documents/Toolbox LaTeX` et les `.tex` ouverts récemment, avec recherche
  et filtre par type. Double-clic ou ✎ pour rouvrir et modifier, 🗑 pour **mettre à la corbeille** (après confirmation) :
  tout le dossier s'il ne contient que ce document, sinon seulement le `.tex` et ses fichiers de compilation
  (un sujet PDF ou tes autres fichiers restent). Récupérable depuis la Corbeille.
- **Symboles & formules** (⇧⌘M, bouton √x ou ⌘K) : plus de 230 symboles et formules prêts à coller, avec recherche
  (« union », « xor », « dérivée produit »…) : ensembles (ℕ ℤ ℚ ℝ ℂ ∅ ∈ ∉ ⊆ ⊈ ∪ ∩ ∖ 𝒫(E)…), logique (∀ ∃ ¬ ∧ ∨ ⊕ ⇒ ⇔, De Morgan…),
  applications (↦, composée, image directe/réciproque, injective…), relations, analyse (lim, ∫, ∑, ⌊x⌋, o, O…),
  formules (ε-δ, limites usuelles, dérivées, TVI, TAF, binôme, DL…), structures (cas, système, align, matrices,
  tableau de variations, table de vérité, récurrence), lettres grecques, flèches, info. Clic = insertion au curseur
  (ou entre `$…$`), clic droit = copier ; les derniers utilisés restent dans « Récents ». Si un symbole demande
  `amssymb` ou `mathtools` et que le document ne le charge pas, un bouton l'ajoute.
- **Formule depuis une photo** : image ou capture → code LaTeX (modèle de vision Ollama) → aperçu → insertion.
- **Nouveau document** (⇧⌘N, ⌘K ou l'accueil) : Toolbox demande le type, **TD, TP, Cours, Test hebdo, Rapport ou Autre**, et crée un
  modèle pré-rempli dans le style des modèles d'Annalyse (`annales.cls`, cahier de projet), autonome (pas de classe à copier) :
  - *TD* : en-tête « TD n – thème », objectif, exercices et questions numérotés tout seuls, corrections masquables (`\corrigefalse`) ;
  - *TP* : encadré « À rendre », compilation, réponses encadrées, code coloré dans le langage choisi (C, C++, Python, Java…) ;
  - *Cours* : page de titre, sommaire, encadrés définition / théorème / propriété / méthode / exemple / attention ;
  - *Test hebdo* : le « Test de connaissances » de la semaine en gros caractères (14 pt), I / Restituer et II / Calculer,
    blancs pour répondre, « Note : / 5 » ; nombre de questions, barème et semaine réglables, version corrigée en un interrupteur ;
  - *Autre* + une description (« une fiche de révision recto-verso sur les suites en deux colonnes… ») : l'**IA locale**
    (Ollama) rédige un modèle sur mesure dans le même style ; Toolbox le compile et lui renvoie les erreurs
    (3 essais au plus) avant de l'ouvrir ;
  - *Rapport* : page de titre façon cahier de projet, encadrés objectif / livrable, tableau ; *Autre* : document simple.
  La matière vient de « Mes cours » (celle du cours en cours par défaut), le numéro suivant est proposé, et le fichier est
  rangé dans le bon dossier (`Analyse 1/TDs/TD4/TD4.tex`) ou dans `Documents/Toolbox LaTeX`.
- Projet depuis un ancien modèle (Beamer…), compteur de mots, références indéfinies.

---

## Annalyse (banque d'annales)

Dépôt de n'importe quel fichier (PDF, scan, photo de travers, Word…). Toolbox enchaîne :
1. lecture et OCR ;
2. identification (fac, niveau, matière, année, session) et repérage des doublons ;
3. découpage en un PDF par sujet ;
4. **retranscription en LaTeX avec `annales.cls` par l'IA locale**, avec contrôle de fidélité et de crédibilité ;
5. compilation avec auto-réparation, puis tags par exercice ;
6. rangement, avec base SQLite, relecture, recherche et statistiques des notions qui tombent.

- **Composer un sujet d'entraînement** : choisis des exercices dans la banque (⊕) ou tire-les au hasard par matière et notions.
  Le sujet est assemblé dans la classe annales, avec la provenance de chaque exercice, et ouvert dans l'éditeur LaTeX.
- **Ménage** : supprimer un sujet (clic droit) ou vider la banque (mise à la corbeille).

Prérequis : Ollama et un modèle qui lit les images.

```bash
ollama pull qwen2.5vl:7b
```

Dans Annalyse → Réglages :
- choisis le dossier **Annalyse** (celui qui contient `config/` et `latex/`) et le dossier de la **banque** ;
- `matieres.yaml`, `notions.yaml`, `etablissements.yaml` et `latex/modele_annale.tex` se modifient sans toucher au code.

En terminal : `pdftool annales depot.pdf photo.heic --annalyse ~/…/Annalyse --model qwen2.5vl:7b`

---

## Partout dans le Mac

| Raccourci | Où | Ce qu'il fait |
|---|---|---|
| **⌘K** | dans Toolbox | Palette : outils, actions, matières, séances (« td 3 struct »), projets, apps, fichiers récents, « Créer la note … » |
| **⌥Espace** | partout | Recherche dans tes cours (noms et contenu) |
| **⌃⌥1 … ⌃⌥9** | partout | Lance les apps du widget « Mes apps » |
| **⇧⌘T** | dans Toolbox | Capture d'écran → texte |
| **⌘,** | dans Toolbox | Réglages (raccourcis, notifications) |

**Barre des menus** (icône clé et tournevis) : pense-bête, capture → texte, déposer un PDF à compresser,
presse-papiers et apps. Fermer la fenêtre laisse Toolbox dans la barre des menus. Pour quitter : ⌘Q.

**Depuis le Finder :**
- glisser un fichier sur l'icône du Dock, ou clic droit → Ouvrir avec → Toolbox ;
- clic droit sur des PDF → **Services** → *Toolbox : Compresser / Fusionner / Rendre cherchable (OCR) / Ouvrir*.
  S'ils n'apparaissent pas : Réglages Système → Clavier → Raccourcis clavier → Services, et coche-les.

**Autorisations demandées au premier usage** (Réglages Système → Confidentialité et sécurité) :

| Autorisation | Pour quoi |
|---|---|
| Calendriers | Aujourd'hui, comptes à rebours, cours en ce moment |
| Automatisation → Notes | Pense-bête |
| Enregistrement de l'écran | Capture → texte |
| Notifications | Début de cours |

---

## Installation

Prérequis : macOS 13 ou plus récent et les outils de développement Apple (`xcode-select --install`).
Xcode complet n'est pas nécessaire.

```bash
./build.sh
```

- L'appli s'installe dans `~/Applications/Toolbox.app`, la commande dans `~/.local/bin/pdftool`.
- Ajoute `export PATH="$HOME/.local/bin:$PATH"` à `~/.zshrc` pour utiliser `pdftool` partout.

Optionnel, mais recommandé :

```bash
brew install ghostscript              # compression bien plus efficace
brew install --cask mactex-no-gui     # LaTeX (latexmk, synctex, texcount)
brew install gh && gh auth login      # dépôts GitHub privés dans le widget GitHub
```

---

## Commande terminal

```bash
# Pages
pdftool merge cours.pdf chap1.pdf chap2.pdf
pdftool split td.pdf --every 2
pdftool extract poly.pdf "1-3, 10" resume.pdf
pdftool delete scan.pdf "2, 5-6"
pdftool rotate scan.pdf 90 --pages "3"
pdftool crop slides.pdf --auto
pdftool nup slides.pdf 4
pdftool booklet poly.pdf

# Optimiser / modifier
pdftool compress *.pdf --level strong
pdftool ocr annale-2019.pdf
pdftool number td.pdf --header "Analyse 1 — TD 3" --skip-first
pdftool watermark copie.pdf "BROUILLON"
pdftool protect notes.pdf motdepasse
pdftool meta cours.pdf --author "Arthur" --keywords "analyse, suites"

# Convertir
pdftool img2pdf copie.pdf IMG_01.jpg IMG_02.jpg
pdftool pdf2img slides.pdf --dpi 300 --pages "4-6"
pdftool text article.pdf
pdftool rag cours/*.pdf --format jsonl

# Par lots
pdftool batch annales-traitées annales/*.pdf --ocr --compress balanced --rename "annale_{n}"

# LaTeX
pdftool new "Analyse 1 — Suites" --template cours
pdftool tex main.tex --watch
pdftool words main.tex
pdftool clean main.tex
```

Plages de pages : `1-3, 5, 8-` (`8-` = jusqu'à la fin, `-3` = depuis le début).

---

## Où sont les données

| Quoi | Où |
|---|---|
| Réglages, disposition de l'accueil, avancement des cours | préférences de l'app (`defaults read fr.arthur.toolbox`) |
| Historique LaTeX | `~/Library/Application Support/Toolbox/Historique/` |
| Signatures | `~/Library/Application Support/Toolbox/Signatures/` |
| Index de recherche des cours | `~/Library/Application Support/Toolbox/IndexCours.json` |
| Notes et crédits | `~/Library/Application Support/Toolbox/Notes.json` |
| Planning | `~/Library/Application Support/Toolbox/Planning.json` |
| Révisions | `~/Library/Application Support/Toolbox/Revisions.json` |
| Nouveaux documents LaTeX | `~/Documents/Toolbox LaTeX/` |
| Banque d'annales | le dossier choisi dans Annalyse → Réglages |

Rien n'est écrit dans ton dossier de cours, sauf ce que tu crées toi-même (nouveau TD/TP, notes, photos, fichiers déposés).

---

## Développement

```bash
swift build                 # compile
swift run Toolbox           # lance l'appli sans créer le .app
swift run pdftool --help
```

```
Sources/
  PDFCore/    moteur partagé : pages, dessin, compression, OCR, comparaison, signature, LaTeX,
              Annalyse (Annales/), bibliothèque et index des cours, GitHub, VS Code
  Toolbox/    appli SwiftUI : une vue par outil, accueil et widgets, Mes cours, éditeur LaTeX,
              notes et ECTS, calculatrice (MathEngine.swift), planning, palette ⌘K, barre des menus
  pdftool/    commande terminal
Resources/    Info.plist (types de fichiers, Services, autorisations) + icône
build.sh      compile hors du dossier (Nextcloud), assemble le .app, l'enregistre auprès de macOS
```

- **Tests** : `build.sh` lance `Toolbox --selftest` après chaque compilation (calculatrice, limites, notes et ECTS,
  lecture du planning et pauses, CRC du casque). Code dans `SelfTest.swift` ; à relancer à la main :
  `~/Applications/Toolbox.app/Contents/MacOS/Toolbox --selftest`.
- Les vues n'utilisent pas `@State`, une macro absente des Command Line Tools sur les SDK récents :
  chaque outil a un petit `ObservableObject`.
- Ajouter un outil : une fonction dans `PDFCore`, un cas dans l'enum `Tool`, une vue dans `Toolbox`,
  une sous-commande dans `pdftool/main.swift`.
- Ajouter un widget : un cas dans `HomeWidget` (`HomeWidgets.swift`) et sa vue dans `HomeView.widget(_:)`.
