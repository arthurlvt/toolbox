# Toolbox

Un « iLovePDF » qui tourne entièrement sur ton Mac : aucun fichier n'est envoyé où que ce soit.
Appli native (Swift + SwiftUI + PDFKit + Vision) et commande terminal `pdftool`, qui partagent le même moteur.

## Outils

| Section | Outil | Ce qu'il fait |
|---|---|---|
| Pages | **Organiser** | Miniatures : glisser pour réordonner, pivoter, supprimer, extraire, ajouter les pages d'autres PDF |
| | **Fusionner** | Plusieurs PDF → un seul, ordre par glisser-déposer |
| | **Diviser** | Une page par fichier, toutes les N pages, plages (`1-3, 5, 8-`), extraction |
| | **Mise en page** | Rogner les marges (auto ou en mm, sans perte), 2 ou 4 pages par feuille, livret A5 |
| Optimiser | **Compresser** | 3 niveaux, Ghostscript si installé, sinon PDFKit |
| | **OCR** | Rend les scans cherchables et copiables (moteur Vision d'Apple, hors ligne, français + anglais) |
| Modifier | **Numéroter & filigrane** | Numéros de page, en-tête, pied de page, filigrane, avec aperçu en direct |
| | **Sécurité & infos** | Ajouter / retirer un mot de passe, modifier titre, auteur, sujet, mots-clés |
| Convertir | **Convertir** | Images → PDF, PDF → PNG/JPEG, PDF → texte, **export RAG** (Markdown ou JSONL, une entrée par page avec source et numéro) |
| Automatiser | **Traitement par lots** | OCR → numérotation/filigrane → auteur → compression → renommage, sur tout un dossier |
| Annales | **Annalyse** | Dépôt de n'importe quel fichier (PDF, scan, photo de travers, Word…) → lecture/OCR, identification (fac, niveau, matière, année, session), doublons, découpage en un PDF par sujet, **retranscription en LaTeX avec `annales.cls` par une IA locale (Ollama)**, contrôle de crédibilité, compilation avec auto-réparation, tags par exercice, fiche de provenance, rangement + base SQLite, relecture/validation et recherche |
| LaTeX | **LaTeX** | Compilation latexmk, aperçu en direct, erreurs cliquables, recompilation auto, nettoyage, **SyncTeX** (⌘-clic dans le PDF → ligne dans VS Code, et l'inverse), **modèles de projet** (cours, TD, rapport, Beamer), **compteur de mots** et références indéfinies |

**Depuis le Finder :**
- glisser un fichier sur l'icône du Dock, ou clic droit → Ouvrir avec → Toolbox ;
- clic droit sur des PDF → **Services** → *Toolbox : Compresser / Fusionner / Rendre cherchable (OCR) / Ouvrir*.
  Si les services n'apparaissent pas : Réglages Système → Clavier → Raccourcis clavier → Services → Fichiers et dossiers, et coche-les.

## Annalyse (banque d'annales)

Prérequis : [Ollama](https://ollama.com) et un modèle, par exemple :

```bash
ollama pull qwen2.5vl:7b      # lit les images des pages (formules, schémas)
```

Dans Toolbox → Annalyse → Réglages : choisis le dossier **Annalyse** (celui qui contient `config/` et `latex/`)
et le dossier de la **banque**. Les fichiers de config (`matieres.yaml`, `notions.yaml`, `etablissements.yaml`)
et le modèle `latex/modele_annale.tex` sont lus tels quels : on les modifie sans toucher au code.

Structure de la banque : `originaux/`, `ranges/<fac>/<niveau>/<matière>/`, `a_verifier/`, `rejets/`, `doublons/`,
`registre.json`, `annalyse.db` (même schéma que la version Python, plus le `.tex` et le PDF propre).

En terminal : `pdftool annales depot.pdf photo.heic --annalyse ~/…/Annalyse --model qwen2.5vl:7b`

## Installation

Prérequis : macOS 13 ou plus récent, et les outils de développement Apple (`xcode-select --install`). Xcode complet n'est pas nécessaire.

```bash
./build.sh
```

L'appli s'installe dans `~/Applications/Toolbox.app` et la commande dans `~/.local/bin/pdftool`.

Optionnel, mais recommandé :

```bash
brew install ghostscript              # compression bien plus efficace
brew install --cask mactex-no-gui     # LaTeX (inclut latexmk, synctex, texcount)
```

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

## Développement

```bash
swift build                 # compile
swift run Toolbox           # lance l'appli sans créer le .app
swift run pdftool --help
```

```
Sources/
  PDFCore/    moteur partagé : pages, dessin, compression, OCR, mise en page, lots, LaTeX
  Toolbox/    appli SwiftUI (une vue par outil)
  pdftool/    commande terminal
Resources/    Info.plist (types de fichiers, Services) + icône
build.sh      compile, assemble le .app, l'enregistre auprès de macOS
```

Les vues n'utilisent pas `@State` (macro absente des Command Line Tools sur les SDK récents) : chaque outil a un petit `ObservableObject`.
Ajouter un outil = une fonction dans `PDFCore`, un cas dans l'enum `Tool`, une vue dans `Toolbox`, une sous-commande dans `pdftool/main.swift`.
