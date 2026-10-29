🇬🇧 [English](CONTRIBUTING.md) | 🇫🇷 Français

# Contribuer à Toolbox

Merci de ton intérêt ! Toolbox est une appli macOS en Swift / SwiftUI, sous licence GPL-3.0. Toute contribution
(code, idée, bug, traduction, maquette de diplôme…) est publiée sous cette même licence.

## Compiler

Prérequis : macOS 13 ou plus récent et les outils de ligne de commande Apple (`xcode-select --install`).
Xcode complet n'est pas nécessaire.

```bash
./build.sh               # compile, lance les tests, installe dans ~/Applications et relance l'appli
./build.sh --no-install  # compile et teste seulement (résultat dans ./build)
swift run Toolbox        # lancer sans créer le .app
```

## Tests

`build.sh` lance `Toolbox --selftest` après chaque compilation. Les tests sont dans
`Sources/Toolbox/SelfTest.swift` : ajoute un `check("…", condition)` pour tout calcul ou toute lecture de texte que
tu modifies (moyennes, planning, LaTeX, archives…). Une PR doit garder tous les tests au vert.

## Organisation du code

```
Sources/PDFCore/   moteur sans interface (PDF, OCR, LaTeX, Annalyse, archives…) : partagé avec pdftool
Sources/Toolbox/   l'appli SwiftUI : une vue et un petit ObservableObject par outil
Sources/pdftool/   la commande terminal
```

Quelques règles du projet :
- **Pas de `@State`** dans les vues (macro absente des Command Line Tools sur les SDK récents) : l'état vit dans un
  `ObservableObject` (souvent `static let shared`).
- **100 % local** : aucune donnée de l'utilisateur ne part sur internet. Les seules connexions réseau acceptées sont
  explicites et facultatives (météo, GitHub, téléchargement d'outils).
- **Français** dans l'interface et les commentaires, phrases courtes, tutoiement.
- Une fonctionnalité liée à un matériel ou à une situation précise doit être **optionnelle** : masquée via
  `AppProfile` (`Profile.swift`) si l'utilisateur n'en a pas besoin.

## Recettes

- **Ajouter un outil** : une fonction dans `PDFCore`, un cas dans l'enum `Tool` (`ToolboxApp.swift` : titre, icône,
  couleur, section, vue), éventuellement une sous-commande dans `pdftool/main.swift`.
- **Ajouter un widget** : un cas dans `HomeWidget` (`HomeWidgets.swift`) et sa vue dans `HomeView.widget(_:)`.
- **Ajouter un casque** : `Headphone.swift` contient la lecture du casque Nothing (canal RFCOMM). Pour une autre
  marque, garde la même interface (`HeadphoneStore.Reading` : nom, pourcentage, charge, gauche / droite / boîtier) et
  repère l'appareil par son nom Bluetooth.
- **Ajouter une maquette de diplôme** : sur le modèle de `GradesStore.l1InfoAvignon()` (UE, matières, codes,
  crédits = coefficients), puis une entrée dans le menu *Année*.
- **Montrer un endroit dans la visite guidée** : `.tourTarget("id")` sur la vue, puis une étape dans
  `TourStore.buildSteps()` ou `TourStore.miniSteps(_:)` (`Tour.swift`).

## Proposer une modification

1. Fais un fork, puis une branche (`git checkout -b ma-fonction`).
2. Compile avec `./build.sh` : les tests doivent passer.
3. Mets à jour le `README.md` si ta modification se voit dans l'appli.
4. Ouvre une Pull Request en expliquant ce qui change et comment le tester (une capture d'écran aide beaucoup).
