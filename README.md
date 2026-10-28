# Toolbox

Un « iLovePDF » qui tourne entièrement sur ton Mac, plus un éditeur LaTeX, un gestionnaire de cours,
une banque d'annales et un tableau de bord. Aucun document n'est envoyé où que ce soit.

Appli native (Swift, SwiftUI, PDFKit, Vision) et commande terminal `pdftool`, qui partagent le même moteur.

- **100 % local** : PDF, cours, notes et index de recherche restent sur le Mac. L'IA (Annalyse, explications
  LaTeX, formules) tourne avec [Ollama](https://ollama.com), sur la machine.
- **Seules exceptions**, si tu les utilises : la météo (Open-Meteo, sans compte) et la liste de tes dépôts GitHub.

---

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

## Outils PDF

| Section | Outil | Ce qu'il fait |
|---|---|---|
| Pages | **Organiser** | Miniatures : glisser pour réordonner, pivoter, supprimer, extraire, ajouter les pages d'autres PDF |
| | **Fusionner** | Plusieurs PDF → un seul, ordre par glisser-déposer |
| | **Diviser** | Une page par fichier, toutes les N pages, plages (`1-3, 5, 8-`), extraction |
| | **Mise en page** | Rogner les marges (auto ou en mm, sans perte), 2 ou 4 pages par feuille, livret A5 |
| Optimiser | **Compresser** | 3 niveaux, Ghostscript si installé, sinon PDFKit |
| | **OCR** | Rend les scans cherchables et copiables (Vision d'Apple, hors ligne, français + anglais) |
| Modifier | **Numéroter & filigrane** | Numéros de page, en-tête, pied de page, filigrane, avec aperçu en direct |
| | **Sécurité & infos** | Ajouter / retirer un mot de passe, modifier titre, auteur, sujet, mots-clés |
| | **Comparer** | Deux versions d'un PDF : pages appariées même si on en a ajouté ou retiré, superposition (rouge = supprimé, vert = ajouté), côte à côte, différences de texte, rapport PDF |
| | **Signer** | Signature dessinée au trackpad ou importée (fond blanc retiré), posée, déplacée et redimensionnée sur la page, PDF signé (texte toujours sélectionnable) |
| Convertir | **Convertir** | Images → PDF, PDF → PNG/JPEG, PDF → texte, **export RAG** (Markdown ou JSONL, une entrée par page) |
| Automatiser | **Traitement par lots** | OCR → numérotation/filigrane → auteur → compression → renommage, sur tout un dossier |

**Capture d'écran → texte** (⇧⌘T, ⌘K, barre des menus) : tu sélectionnes une zone de l'écran, le texte est lu hors ligne et copié.

---

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
- **Formule depuis une photo** : image ou capture → code LaTeX (modèle de vision Ollama) → aperçu → insertion.
- **Nouveau document** (⇧⌘N) ou projet depuis un modèle (cours, TD, rapport, Beamer), compteur de mots, références indéfinies.

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
              palette ⌘K, barre des menus, raccourcis globaux
  pdftool/    commande terminal
Resources/    Info.plist (types de fichiers, Services, autorisations) + icône
build.sh      compile hors du dossier (Nextcloud), assemble le .app, l'enregistre auprès de macOS
```

- Les vues n'utilisent pas `@State`, une macro absente des Command Line Tools sur les SDK récents :
  chaque outil a un petit `ObservableObject`.
- Ajouter un outil : une fonction dans `PDFCore`, un cas dans l'enum `Tool`, une vue dans `Toolbox`,
  une sous-commande dans `pdftool/main.swift`.
- Ajouter un widget : un cas dans `HomeWidget` (`HomeWidgets.swift`) et sa vue dans `HomeView.widget(_:)`.
