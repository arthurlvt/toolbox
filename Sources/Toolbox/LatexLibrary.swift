import SwiftUI
import AppKit

// MARK: - Bibliothèque de symboles et formules LaTeX

/// Un symbole ou une formule prête à coller : aperçu Unicode, code LaTeX, mots-clés pour la recherche.
struct LatexSnippet: Identifiable, Hashable {
    var id: String { latex }
    let preview: String
    let name: String
    let latex: String
    var keywords: String = ""
    /// paquet nécessaire en plus d'amsmath (amssymb, mathtools, stmaryrd…)
    var package: String? = nil
    /// bloc à part (align, cases, matrice…) : inséré sur ses propres lignes, jamais entre $…$
    var block: Bool = false
}

struct LatexSnippetCategory: Identifiable {
    var id: String { name }
    let name: String
    let icon: String
    /// formules longues : affichées en liste plutôt qu'en grille
    let wide: Bool
    let items: [LatexSnippet]
}

enum LatexLibrary {
    private static func s(_ p: String, _ n: String, _ l: String, _ k: String = "", pkg: String? = nil, block: Bool = false) -> LatexSnippet {
        LatexSnippet(preview: p, name: n, latex: l, keywords: k, package: pkg, block: block)
    }

    static let categories: [LatexSnippetCategory] = [
        LatexSnippetCategory(name: "Ensembles", icon: "circle.grid.cross", wide: false, items: [
            s("∅", "Ensemble vide", #"\emptyset"#, "vide empty"),
            s("∅", "Ensemble vide (rond)", #"\varnothing"#, "vide", pkg: "amssymb"),
            s("ℕ", "Entiers naturels", #"\mathbb{N}"#, "N naturels", pkg: "amssymb"),
            s("ℤ", "Entiers relatifs", #"\mathbb{Z}"#, "Z relatifs", pkg: "amssymb"),
            s("ℚ", "Rationnels", #"\mathbb{Q}"#, "Q rationnels", pkg: "amssymb"),
            s("ℝ", "Réels", #"\mathbb{R}"#, "R reels", pkg: "amssymb"),
            s("ℂ", "Complexes", #"\mathbb{C}"#, "C complexes", pkg: "amssymb"),
            s("ℕ*", "Naturels non nuls", #"\mathbb{N}^*"#, "N etoile", pkg: "amssymb"),
            s("ℝ₊", "Réels positifs", #"\mathbb{R}_+"#, "R plus positifs", pkg: "amssymb"),
            s("ℝ*₊", "Réels strictement positifs", #"\mathbb{R}_+^*"#, "R plus etoile", pkg: "amssymb"),
            s("ℝ²", "Plan ℝ²", #"\mathbb{R}^2"#, "R2 plan", pkg: "amssymb"),
            s("ℝⁿ", "Espace ℝⁿ", #"\mathbb{R}^n"#, "Rn", pkg: "amssymb"),
            s("∈", "Appartient", #"\in"#, "appartient element"),
            s("∉", "N'appartient pas", #"\notin"#, "appartient pas"),
            s("∋", "Contient (élément)", #"\ni"#, "contient"),
            s("⊂", "Inclus", #"\subset"#, "inclus sous-ensemble"),
            s("⊆", "Inclus ou égal", #"\subseteq"#, "inclus egal"),
            s("⊊", "Inclus strictement", #"\subsetneq"#, "strict", pkg: "amssymb"),
            s("⊈", "Non inclus", #"\nsubseteq"#, "pas inclus", pkg: "amssymb"),
            s("⊃", "Contient", #"\supset"#, "contient"),
            s("⊇", "Contient ou égal", #"\supseteq"#, "contient egal"),
            s("⊉", "Ne contient pas", #"\nsupseteq"#, "contient pas", pkg: "amssymb"),
            s("∪", "Union", #"\cup"#, "union reunion"),
            s("∩", "Intersection", #"\cap"#, "inter"),
            s("⋃", "Grande union", #"\bigcup_{i \in I} A_i"#, "union indexee famille"),
            s("⋂", "Grande intersection", #"\bigcap_{i \in I} A_i"#, "intersection famille"),
            s("A \\ B", "Privé de", #"A \setminus B"#, "difference prive moins backslash"),
            s("∁A", "Complémentaire", #"\complement_E A"#, "complementaire", pkg: "amssymb"),
            s("Ā", "Complémentaire (barre)", #"\overline{A}"#, "complementaire barre"),
            s("A × B", "Produit cartésien", #"A \times B"#, "produit cartesien couple"),
            s("Δ", "Différence symétrique", #"A \,\Delta\, B"#, "difference symetrique"),
            s("𝒫(E)", "Parties de E", #"\mathcal{P}(E)"#, "parties ensemble des parties"),
            s("|A|", "Cardinal", #"\operatorname{card}(A)"#, "cardinal card nombre"),
            s("{x ∈ E | P(x)}", "Ensemble défini par une propriété", #"\{\, x \in E \mid P(x) \,\}"#, "comprehension accolades tel que"),
            s("{a, b, c}", "Ensemble en extension", #"\{ a, b, c \}"#, "accolades extension"),
            s("[a, b]", "Intervalle fermé", #"[a, b]"#, "intervalle ferme"),
            s("]a, b[", "Intervalle ouvert", #"]a, b["#, "intervalle ouvert"),
            s("[a, +∞[", "Intervalle infini", #"[a, +\infty["#, "intervalle infini"),
            s("⟦1, n⟧", "Intervalle d'entiers", #"[\![ 1, n ]\!]"#, "entiers crochets doubles"),
        ]),
        LatexSnippetCategory(name: "Logique", icon: "function", wide: false, items: [
            s("∀", "Pour tout", #"\forall"#, "quel que soit pour tout"),
            s("∃", "Il existe", #"\exists"#, "existe"),
            s("∃!", "Il existe un unique", #"\exists!"#, "existe unique"),
            s("∄", "Il n'existe pas", #"\nexists"#, "existe pas", pkg: "amssymb"),
            s("¬", "Non", #"\neg"#, "non negation not"),
            s("∧", "Et", #"\wedge"#, "et and"),
            s("∨", "Ou", #"\vee"#, "ou or"),
            s("⊕", "Ou exclusif (XOR)", #"\oplus"#, "xor ou exclusif"),
            s("⊻", "Ou exclusif (XOR, logique)", #"\veebar"#, "xor ou exclusif", pkg: "amssymb"),
            s("↑", "Non-et (NAND)", #"\uparrow"#, "nand sheffer"),
            s("↓", "Non-ou (NOR)", #"\downarrow"#, "nor peirce"),
            s("⇒", "Implique", #"\Rightarrow"#, "implique implication =>"),
            s("⟹", "Implique (long)", #"\implies"#, "implique long"),
            s("⇐", "Est impliqué par", #"\Leftarrow"#, "reciproque <="),
            s("⇔", "Équivalent", #"\Leftrightarrow"#, "equivalent equivalence <=>"),
            s("⟺", "Si et seulement si", #"\iff"#, "ssi equivalent long"),
            s("≡", "Équivalence / identique", #"\equiv"#, "identique congru"),
            s("⊤", "Vrai", #"\top"#, "vrai true"),
            s("⊥", "Faux", #"\bot"#, "faux false"),
            s("∴", "Donc", #"\therefore"#, "donc", pkg: "amssymb"),
            s("∵", "Car", #"\because"#, "car parce que", pkg: "amssymb"),
            s(":=", "Défini par", #"\coloneqq"#, "defini par egal", pkg: "mathtools"),
            s("∀ε>0 ∃N…", "Définition quantifiée", #"\forall \varepsilon > 0,\ \exists N \in \mathbb{N},\ \forall n \geq N,\ "#, "quantificateurs epsilon"),
            s("¬(P ⇒ Q)", "Négation d'une implication", #"\neg(P \Rightarrow Q) \iff (P \wedge \neg Q)"#, "negation implication"),
            s("¬(∀x P)", "Négation de ∀", #"\neg(\forall x,\ P(x)) \iff \exists x,\ \neg P(x)"#, "negation quantificateur"),
            s("De Morgan", "Lois de De Morgan", #"\neg(P \wedge Q) \iff (\neg P \vee \neg Q)"#, "morgan negation et ou"),
        ]),
        LatexSnippetCategory(name: "Applications", icon: "arrow.right", wide: false, items: [
            s("↦", "Associe (x ↦ f(x))", #"\mapsto"#, "mapsto associe |->"),
            s("f : E → F", "Application", #"f \colon E \to F"#, "application fonction"),
            s("x ↦ f(x)", "Définition d'une application", #"f \colon x \mapsto f(x)"#, "fonction definition"),
            s("f:{E→F x↦…", "Application sur deux lignes", #"f \colon \left\{ \begin{array}{rcl} E & \longrightarrow & F \\ x & \longmapsto & f(x) \end{array} \right."#, "application deux lignes", block: false),
            s("∘", "Composée", #"g \circ f"#, "rond composition"),
            s("(g∘f)(x)", "Composée appliquée", #"(g \circ f)(x) = g(f(x))"#, "composition formule"),
            s("f⁻¹", "Réciproque", #"f^{-1}"#, "reciproque inverse bijection"),
            s("f(A)", "Image directe", #"f(A) = \{\, f(x) \mid x \in A \,\}"#, "image directe"),
            s("f⁻¹(B)", "Image réciproque", #"f^{-1}(B) = \{\, x \in E \mid f(x) \in B \,\}"#, "image reciproque"),
            s("Id_E", "Identité", #"\mathrm{Id}_E"#, "identite"),
            s("↪", "Injection", #"\hookrightarrow"#, "injection injective"),
            s("↠", "Surjection", #"\twoheadrightarrow"#, "surjection surjective", pkg: "amssymb"),
            s("inj.", "Définition injective", #"\forall (x, x') \in E^2,\ f(x) = f(x') \Rightarrow x = x'"#, "injective definition"),
            s("surj.", "Définition surjective", #"\forall y \in F,\ \exists x \in E,\ y = f(x)"#, "surjective definition"),
            s("bij.", "Définition bijective", #"\forall y \in F,\ \exists!\, x \in E,\ y = f(x)"#, "bijective definition"),
            s("f|_A", "Restriction", #"f_{|A}"#, "restriction"),
        ]),
        LatexSnippetCategory(name: "Relations", icon: "equal", wide: false, items: [
            s("≤", "Inférieur ou égal", #"\leq"#, "inferieur <="),
            s("≥", "Supérieur ou égal", #"\geq"#, "superieur >="),
            s("⩽", "Inférieur ou égal (français)", #"\leqslant"#, "inferieur", pkg: "amssymb"),
            s("⩾", "Supérieur ou égal (français)", #"\geqslant"#, "superieur", pkg: "amssymb"),
            s("≠", "Différent", #"\neq"#, "different !="),
            s("≈", "Environ", #"\approx"#, "environ approx"),
            s("≃", "Isomorphe / environ", #"\simeq"#, "simeq"),
            s("∼", "Équivalent à", #"\sim"#, "equivalent suite"),
            s("≪", "Très inférieur", #"\ll"#, "negligeable"),
            s("≫", "Très supérieur", #"\gg"#, ""),
            s("∝", "Proportionnel", #"\propto"#, "proportionnel"),
            s("≡ [n]", "Congru modulo", #"a \equiv b \pmod{n}"#, "congru modulo"),
            s("∣", "Divise", #"a \mid b"#, "divise divisible"),
            s("∤", "Ne divise pas", #"a \nmid b"#, "divise pas", pkg: "amssymb"),
            s("±", "Plus ou moins", #"\pm"#, "plus moins"),
            s("·", "Point (produit)", #"\cdot"#, "produit point"),
            s("×", "Fois", #"\times"#, "fois multiplie"),
            s("÷", "Divisé", #"\div"#, "divise"),
        ]),
        LatexSnippetCategory(name: "Analyse", icon: "chart.xyaxis.line", wide: false, items: [
            s("∞", "Infini", #"\infty"#, "infini"),
            s("+∞", "Plus l'infini", #"+\infty"#, "plus infini"),
            s("−∞", "Moins l'infini", #"-\infty"#, "moins infini"),
            s("lim", "Limite", #"\lim_{x \to a} f(x)"#, "limite"),
            s("lim x→+∞", "Limite en +∞", #"\lim_{x \to +\infty} f(x)"#, "limite infini"),
            s("lim x→a⁺", "Limite à droite", #"\lim_{x \to a^+} f(x)"#, "limite droite"),
            s("lim x→a⁻", "Limite à gauche", #"\lim_{x \to a^-} f(x)"#, "limite gauche"),
            s("lim uₙ", "Limite de suite", #"\lim_{n \to +\infty} u_n"#, "limite suite"),
            s("a/b", "Fraction", #"\frac{a}{b}"#, "fraction"),
            s("a/b (grand)", "Fraction en grand", #"\dfrac{a}{b}"#, "fraction grande"),
            s("√x", "Racine carrée", #"\sqrt{x}"#, "racine"),
            s("ⁿ√x", "Racine n-ième", #"\sqrt[n]{x}"#, "racine n"),
            s("xⁿ", "Puissance", #"x^{n}"#, "puissance exposant"),
            s("xᵢ", "Indice", #"x_{i}"#, "indice"),
            s("|x|", "Valeur absolue", #"\lvert x \rvert"#, "valeur absolue"),
            s("‖x‖", "Norme", #"\lVert x \rVert"#, "norme"),
            s("⌊x⌋", "Partie entière", #"\lfloor x \rfloor"#, "partie entiere floor"),
            s("⌈x⌉", "Partie entière sup.", #"\lceil x \rceil"#, "plafond ceil"),
            s("f′(x)", "Dérivée", #"f'(x)"#, "derivee prime"),
            s("f″(x)", "Dérivée seconde", #"f''(x)"#, "derivee seconde"),
            s("f⁽ⁿ⁾", "Dérivée n-ième", #"f^{(n)}"#, "derivee n"),
            s("df/dx", "Dérivée (Leibniz)", #"\frac{\mathrm{d}f}{\mathrm{d}x}"#, "derivee leibniz"),
            s("∂f/∂x", "Dérivée partielle", #"\frac{\partial f}{\partial x}"#, "partielle"),
            s("∫", "Intégrale", #"\int_{a}^{b} f(x) \, \mathrm{d}x"#, "integrale"),
            s("∑", "Somme", #"\sum_{k=1}^{n} u_k"#, "somme sigma"),
            s("∏", "Produit", #"\prod_{k=1}^{n} u_k"#, "produit pi"),
            s("n!", "Factorielle", #"n!"#, "factorielle"),
            s("(n k)", "Coefficient binomial", #"\binom{n}{k}"#, "binome combinaison"),
            s("sup", "Borne supérieure", #"\sup_{x \in A} f(x)"#, "sup borne superieure"),
            s("inf", "Borne inférieure", #"\inf_{x \in A} f(x)"#, "inf borne inferieure"),
            s("max", "Maximum", #"\max(a, b)"#, "max"),
            s("o(x)", "Petit o", #"o(x^n)"#, "negligeable petit o"),
            s("O(x)", "Grand O", #"O(x^n)"#, "grand o domine"),
            s("eˣ", "Exponentielle", #"\mathrm{e}^{x}"#, "exponentielle exp"),
            s("ln", "Logarithme", #"\ln(x)"#, "ln log"),
            s("cos sin tan", "Trigonométrie", #"\cos(x), \sin(x), \tan(x)"#, "trigo"),
            s("uₙ₊₁", "Terme suivant", #"u_{n+1}"#, "suite recurrence"),
            s("(uₙ)", "Suite", #"(u_n)_{n \in \mathbb{N}}"#, "suite", pkg: "amssymb"),
        ]),
        LatexSnippetCategory(name: "Formules", icon: "sum", wide: true, items: [
            s("ε-limite", "Définition de la limite (suite)", #"\forall \varepsilon > 0,\ \exists N \in \mathbb{N},\ \forall n \geq N,\ |u_n - \ell| < \varepsilon"#, "definition limite suite epsilon", pkg: "amssymb"),
            s("ε-δ", "Définition de la limite (fonction)", #"\forall \varepsilon > 0,\ \exists \delta > 0,\ \forall x \in D,\ |x - a| < \delta \Rightarrow |f(x) - \ell| < \varepsilon"#, "definition limite fonction epsilon delta continuite"),
            s("lim → +∞", "Tend vers +∞ (fonction)", #"\forall A > 0,\ \exists B > 0,\ \forall x \in D,\ x > B \Rightarrow f(x) > A"#, "definition limite infinie"),
            s("sin x / x", "Limite usuelle sin", #"\lim_{x \to 0} \frac{\sin x}{x} = 1"#, "limite usuelle sinus"),
            s("(eˣ−1)/x", "Limite usuelle exp", #"\lim_{x \to 0} \frac{\mathrm{e}^{x} - 1}{x} = 1"#, "limite usuelle exponentielle"),
            s("ln(1+x)/x", "Limite usuelle ln", #"\lim_{x \to 0} \frac{\ln(1 + x)}{x} = 1"#, "limite usuelle logarithme"),
            s("croissances", "Croissances comparées", #"\lim_{x \to +\infty} \frac{\mathrm{e}^{x}}{x^n} = +\infty \qquad \lim_{x \to +\infty} \frac{\ln x}{x} = 0"#, "croissances comparees"),
            s("taux", "Taux d'accroissement", #"f'(a) = \lim_{h \to 0} \frac{f(a + h) - f(a)}{h}"#, "nombre derive taux accroissement"),
            s("(uv)′", "Dérivée d'un produit", #"(uv)' = u'v + uv'"#, "derivee produit"),
            s("(u/v)′", "Dérivée d'un quotient", #"\left(\frac{u}{v}\right)' = \frac{u'v - uv'}{v^2}"#, "derivee quotient"),
            s("(g∘f)′", "Dérivée d'une composée", #"(g \circ f)' = f' \times (g' \circ f)"#, "derivee composee"),
            s("(uⁿ)′", "Dérivée d'une puissance", #"(u^n)' = n\,u'\,u^{n-1}"#, "derivee puissance"),
            s("(eᵘ)′ (ln u)′", "Dérivées exp et ln", #"(\mathrm{e}^{u})' = u'\,\mathrm{e}^{u} \qquad (\ln u)' = \frac{u'}{u}"#, "derivee exp ln"),
            s("y = f′(a)(x−a)+f(a)", "Tangente", #"y = f'(a)(x - a) + f(a)"#, "tangente"),
            s("TVI", "Théorème des valeurs intermédiaires", #"f \text{ continue sur } [a, b],\ f(a) f(b) < 0 \Rightarrow \exists c \in \,]a, b[,\ f(c) = 0"#, "tvi valeurs intermediaires"),
            s("TAF", "Accroissements finis", #"\exists c \in \,]a, b[,\quad f(b) - f(a) = f'(c)(b - a)"#, "taf accroissements finis rolle"),
            s("|x+y| ≤ |x|+|y|", "Inégalité triangulaire", #"|x + y| \leq |x| + |y|"#, "inegalite triangulaire"),
            s("||x|−|y||", "Inégalité triangulaire inverse", #"\big||x| - |y|\big| \leq |x - y|"#, "inegalite triangulaire inverse"),
            s("E(x) ≤ x < E(x)+1", "Partie entière", #"E(x) \leq x < E(x) + 1"#, "partie entiere encadrement"),
            s("Archimède", "Propriété d'Archimède", #"\forall x \in \mathbb{R},\ \exists n \in \mathbb{N},\ n > x"#, "archimede", pkg: "amssymb"),
            s("∑k", "Somme des entiers", #"\sum_{k=1}^{n} k = \frac{n(n+1)}{2}"#, "somme arithmetique entiers"),
            s("∑qᵏ", "Somme géométrique", #"\sum_{k=0}^{n} q^k = \frac{1 - q^{n+1}}{1 - q} \quad (q \neq 1)"#, "somme geometrique"),
            s("(a+b)ⁿ", "Binôme de Newton", #"(a + b)^n = \sum_{k=0}^{n} \binom{n}{k} a^k b^{n-k}"#, "binome newton"),
            s("cos²+sin²", "Identité trigonométrique", #"\cos^2 x + \sin^2 x = 1"#, "trigo cos sin"),
            s("eᵃ⁺ᵇ ln(ab)", "Exp et ln", #"\mathrm{e}^{a+b} = \mathrm{e}^{a}\,\mathrm{e}^{b} \qquad \ln(ab) = \ln a + \ln b"#, "exponentielle logarithme proprietes"),
            s("Δ = b²−4ac", "Second degré", #"\Delta = b^2 - 4ac, \qquad x_{1,2} = \frac{-b \pm \sqrt{\Delta}}{2a}"#, "discriminant second degre trinome"),
            s("DL eˣ", "Développement limité de eˣ", #"\mathrm{e}^{x} = 1 + x + \frac{x^2}{2} + \cdots + \frac{x^n}{n!} + o(x^n)"#, "dl exponentielle taylor"),
            s("DL ln(1+x)", "Développement limité de ln(1+x)", #"\ln(1 + x) = x - \frac{x^2}{2} + \frac{x^3}{3} + \cdots + (-1)^{n-1}\frac{x^n}{n} + o(x^n)"#, "dl logarithme"),
            s("DL sin cos", "Développements de sin et cos", #"\sin x = x - \frac{x^3}{6} + o(x^3) \qquad \cos x = 1 - \frac{x^2}{2} + o(x^2)"#, "dl sinus cosinus"),
            s("|A∪B|", "Cardinal d'une union", #"\operatorname{card}(A \cup B) = \operatorname{card}(A) + \operatorname{card}(B) - \operatorname{card}(A \cap B)"#, "cardinal union"),
        ]),
        LatexSnippetCategory(name: "Structures", icon: "square.grid.3x3", wide: true, items: [
            s("{ cas", "Fonction par morceaux", #"f(x) = \begin{cases} a & \text{si } x < 0, \\ b & \text{si } x \geq 0. \end{cases}"#, "cases accolade morceaux systeme"),
            s("{ système", "Système d'équations", "\\[\n\\left\\{\n\\begin{aligned}\n  x + y &= 1 \\\\\n  x - y &= 0\n\\end{aligned}\n\\right.\n\\]", "systeme equations", block: true),
            s("align*", "Calcul aligné sur =", "\\begin{align*}\n  f(x) &= \\dots \\\\\n       &= \\dots\n\\end{align*}", "align calcul etapes", block: true),
            s("equation", "Équation numérotée", "\\begin{equation}\n  \\label{eq:}\n  f(x) = \n\\end{equation}", "equation numerotee label", block: true),
            s("\\[ \\]", "Formule centrée", "\\[\n  f(x) = \n\\]", "display centre", block: true),
            s("(a b; c d)", "Matrice 2×2", #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#, "matrice"),
            s("(3×3)", "Matrice 3×3", "\\[\n\\begin{pmatrix}\n  a_{11} & a_{12} & a_{13} \\\\\n  a_{21} & a_{22} & a_{23} \\\\\n  a_{31} & a_{32} & a_{33}\n\\end{pmatrix}\n\\]", "matrice 3", block: true),
            s("|a b; c d|", "Déterminant", #"\begin{vmatrix} a & b \\ c & d \end{vmatrix}"#, "determinant"),
            s("▭", "Résultat encadré", #"\boxed{x = 1}"#, "cadre encadre resultat"),
            s("texte", "Texte dans une formule", #"\text{ si }"#, "texte mot"),
            s("⇕ tableau", "Tableau de variations simple", "\\[\n\\begin{array}{c|ccccc}\n  x & -\\infty & & a & & +\\infty \\\\ \\hline\n  f'(x) & & - & 0 & + & \\\\ \\hline\n  f(x) & & \\searrow & f(a) & \\nearrow &\n\\end{array}\n\\]", "tableau variations signe", block: true),
            s("table vérité", "Table de vérité", "\\begin{tabular}{|c|c|c|}\n  \\hline\n  $P$ & $Q$ & $P \\Rightarrow Q$ \\\\ \\hline\n  V & V & V \\\\\n  V & F & F \\\\\n  F & V & V \\\\\n  F & F & V \\\\ \\hline\n\\end{tabular}", "table verite logique", block: true),
            s("récurrence", "Démonstration par récurrence", "\\textbf{Initialisation :} pour $n = 0$, \\dots\n\n\\textbf{Hérédité :} supposons $P(n)$ vraie pour un $n \\in \\mathbb{N}$ fixé. Montrons $P(n+1)$. \\dots\n\n\\textbf{Conclusion :} par récurrence, $\\forall n \\in \\mathbb{N},\\ P(n)$.", "recurrence demonstration", pkg: "amssymb", block: true),
        ]),
        LatexSnippetCategory(name: "Grec", icon: "textformat", wide: false, items: [
            s("α", "alpha", #"\alpha"#), s("β", "bêta", #"\beta"#), s("γ", "gamma", #"\gamma"#), s("δ", "delta", #"\delta"#),
            s("ε", "epsilon", #"\varepsilon"#), s("ϵ", "epsilon (droit)", #"\epsilon"#), s("ζ", "zêta", #"\zeta"#), s("η", "êta", #"\eta"#),
            s("θ", "thêta", #"\theta"#), s("ι", "iota", #"\iota"#), s("κ", "kappa", #"\kappa"#), s("λ", "lambda", #"\lambda"#),
            s("μ", "mu", #"\mu"#), s("ν", "nu", #"\nu"#), s("ξ", "xi", #"\xi"#), s("π", "pi", #"\pi"#),
            s("ρ", "rhô", #"\rho"#), s("σ", "sigma", #"\sigma"#), s("τ", "tau", #"\tau"#), s("φ", "phi", #"\varphi"#),
            s("χ", "khi", #"\chi"#), s("ψ", "psi", #"\psi"#), s("ω", "oméga", #"\omega"#),
            s("Γ", "Gamma", #"\Gamma"#), s("Δ", "Delta", #"\Delta"#), s("Θ", "Thêta", #"\Theta"#), s("Λ", "Lambda", #"\Lambda"#),
            s("Π", "Pi", #"\Pi"#), s("Σ", "Sigma", #"\Sigma"#), s("Φ", "Phi", #"\Phi"#), s("Ψ", "Psi", #"\Psi"#), s("Ω", "Oméga", #"\Omega"#),
        ]),
        LatexSnippetCategory(name: "Flèches", icon: "arrow.left.arrow.right", wide: false, items: [
            s("→", "Vers", #"\to"#, "fleche tend vers ->"),
            s("←", "Gauche", #"\leftarrow"#, "fleche gauche <-"),
            s("↔", "Double", #"\leftrightarrow"#, "fleche double"),
            s("⟶", "Longue", #"\longrightarrow"#, "fleche longue"),
            s("⟼", "Associe (long)", #"\longmapsto"#, "mapsto long"),
            s("↗", "Croissante", #"\nearrow"#, "croissant monte"),
            s("↘", "Décroissante", #"\searrow"#, "decroissant descend"),
            s("⇑", "Haut (double)", #"\Uparrow"#, ""),
            s("⇓", "Bas (double)", #"\Downarrow"#, ""),
            s("→ˣ", "Flèche avec texte", #"\xrightarrow{\text{texte}}"#, "fleche texte dessus"),
            s("⇀", "Converge faiblement", #"\rightharpoonup"#, "harpon"),
        ]),
        LatexSnippetCategory(name: "Info", icon: "chevron.left.forwardslash.chevron.right", wide: false, items: [
            s("O(n log n)", "Complexité", #"O(n \log n)"#, "complexite"),
            s("⌊log₂ n⌋", "Logarithme binaire", #"\lfloor \log_2 n \rfloor"#, "log2 binaire"),
            s("mod", "Modulo", #"a \bmod n"#, "modulo reste"),
            s("1011₂", "Nombre en base 2", #"(1011)_2"#, "binaire base"),
            s("A ⊕ B", "XOR binaire", #"A \oplus B"#, "xor"),
            s("Ā", "Non logique (barre)", #"\overline{A}"#, "non barre booleen"),
            s("A·B", "Et (booléen)", #"A \cdot B"#, "et booleen"),
            s("A+B", "Ou (booléen)", #"A + B"#, "ou booleen"),
            s("code", "Code dans le texte", #"\texttt{code}"#, "texttt monospace"),
            s("⟨x, y⟩", "Couple / produit scalaire", #"\langle x, y \rangle"#, "chevrons produit scalaire"),
            s("…", "Points de suspension", #"\dots"#, "points suspension"),
            s("⋯", "Points centrés", #"\cdots"#, "points centres"),
            s("⋮", "Points verticaux", #"\vdots"#, "vertical"),
        ]),
    ]

    static var all: [LatexSnippet] { categories.flatMap { $0.items } }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    static func search(_ q: String) -> [LatexSnippet] {
        let words = fold(q).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        return all.filter { sn in
            let hay = fold(sn.name + " " + sn.keywords + " " + sn.latex) + " " + sn.preview
            return words.allSatisfy { hay.contains($0) } && seen.insert(sn.latex).inserted
        }
    }
}

// MARK: - État du panneau

final class LatexLibraryState: ObservableObject {
    static let shared = LatexLibraryState()
    private let d = UserDefaults.standard

    @Published var show = false
    @Published var query = ""
    @Published var category = UserDefaults.standard.string(forKey: "latexlib.cat") ?? "Ensembles" {
        didSet { d.set(category, forKey: "latexlib.cat") }
    }
    /// entourer de $…$ à l'insertion (pratique quand on écrit du texte)
    @Published var dollars = UserDefaults.standard.bool(forKey: "latexlib.dollars") {
        didSet { d.set(dollars, forKey: "latexlib.dollars") }
    }
    @Published var recents: [String] = UserDefaults.standard.stringArray(forKey: "latexlib.recents") ?? []
    @Published var missingPackage: String?

    static let recentName = "Récents"

    var recentItems: [LatexSnippet] {
        let all = LatexLibrary.all
        return recents.compactMap { r in all.first { $0.latex == r } }
    }

    var visible: [LatexSnippet] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return LatexLibrary.search(query) }
        if category == Self.recentName { return recentItems }
        return LatexLibrary.categories.first { $0.name == category }?.items ?? []
    }

    var wide: Bool {
        if !query.isEmpty || category == Self.recentName { return visible.contains { $0.latex.count > 24 } }
        return LatexLibrary.categories.first { $0.name == category }?.wide ?? false
    }

    func text(for sn: LatexSnippet) -> String {
        if sn.block { return "\n" + sn.latex + "\n" }
        return dollars ? "$" + sn.latex + "$" : (sn.latex.hasPrefix("\\") && sn.latex.allSatisfy { $0.isLetter || $0 == "\\" } ? sn.latex + " " : sn.latex)
    }

    func used(_ sn: LatexSnippet) {
        recents.removeAll { $0 == sn.latex }
        recents.insert(sn.latex, at: 0)
        if recents.count > 24 { recents.removeLast(recents.count - 24) }
        d.set(recents, forKey: "latexlib.recents")
    }

    /// Insère au curseur dans l'éditeur (ou copie si aucun document n'est ouvert).
    func insert(_ sn: LatexSnippet, into model: LatexModel) {
        used(sn)
        guard model.texURL != nil else { copy(sn); return }
        model.send(.insert(text(for: sn)))
        if let p = sn.package, !Self.hasPackage(p, in: model.source) { missingPackage = p } else { missingPackage = nil }
    }

    func copy(_ sn: LatexSnippet) {
        used(sn)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dollars && !sn.block ? "$" + sn.latex + "$" : sn.latex, forType: .string)
        ToastCenter.shared.show("Copié : \(sn.latex.count > 40 ? String(sn.latex.prefix(40)) + "…" : sn.latex)")
    }

    static func hasPackage(_ p: String, in source: String) -> Bool {
        // \usepackage{amssymb} ou \usepackage[...]{amsmath,amssymb}, ou un paquet qui le charge déjà
        let implied: [String: [String]] = ["amssymb": ["amssymb", "amsfonts"], "mathtools": ["mathtools"], "amsmath": ["amsmath", "mathtools"]]
        let names = implied[p] ?? [p]
        let pattern = #"\\(usepackage|RequirePackage)(\[[^\]]*\])?\{([^}]*)\}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return true }
        let ns = source as NSString
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let list = ns.substring(with: m.range(at: 3)).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if list.contains(where: { names.contains($0) }) { return true }
        }
        // classe maison (annales.cls…) : on ne sait pas, on ne dit rien
        return source.range(of: #"\\documentclass(\[[^\]]*\])?\{(article|report|book|beamer|extarticle|scrartcl|scrreprt)\}"#,
                            options: .regularExpression) == nil
    }

    /// Ajoute \usepackage{p} juste après \documentclass.
    func addPackage(_ p: String, to model: LatexModel) {
        let lines = model.source.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("\\documentclass") }) else { return }
        model.send(.replaceLines(from: i + 1, to: i + 1, with: lines[i] + "\n\\usepackage{\(p)}"))
        missingPackage = nil
        ToastCenter.shared.show("\\usepackage{\(p)} ajouté")
    }
}

// MARK: - Vue

struct LatexLibraryView: View {
    @ObservedObject var model: LatexModel
    @ObservedObject var st = LatexLibraryState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Symboles & formules").font(.headline)
                Spacer()
                Toggle("$…$", isOn: $st.dollars)
                    .toggleStyle(.checkbox)
                    .help("Entourer de $…$ à l'insertion (pour écrire dans le texte, hors formule)")
            }
            TextField("Rechercher : union, xor, limite, dérivée…", text: $st.query)
                .textFieldStyle(.roundedBorder)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(LatexLibraryState.recentName, icon: "clock")
                    ForEach(LatexLibrary.categories) { c in chip(c.name, icon: c.icon) }
                }
            }
            if let p = st.missingPackage, model.texURL != nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    Text("Ce symbole a besoin de \\usepackage{\(p)}").font(.caption)
                    Spacer()
                    Button("Ajouter") { st.addPackage(p, to: model) }.controlSize(.small)
                    Button { st.missingPackage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).controlSize(.small)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            ScrollView {
                let items = st.visible
                if items.isEmpty {
                    Text(st.category == LatexLibraryState.recentName && st.query.isEmpty
                         ? "Les symboles que tu utilises apparaîtront ici." : "Rien trouvé.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 20)
                } else if st.wide {
                    VStack(spacing: 4) { ForEach(items) { row($0) } }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], spacing: 6) {
                        ForEach(items) { cell($0) }
                    }
                }
            }
            Text(model.texURL == nil ? "Clic : copier le code LaTeX." : "Clic : insérer au curseur · clic droit : copier.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 440, height: 520)
    }

    private func chip(_ name: String, icon: String) -> some View {
        let on = st.query.isEmpty && st.category == name
        return Button { st.query = ""; st.category = name } label: {
            Label(name, systemImage: icon)
                .font(.caption.weight(on ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private func cell(_ sn: LatexSnippet) -> some View {
        Button { st.insert(sn, into: model) } label: {
            VStack(spacing: 3) {
                Text(sn.preview)
                    .font(.system(size: sn.preview.count <= 2 ? 22 : 13, design: .serif))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(height: 28)
                Text(sn.latex)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sn.name + " — " + sn.latex + (sn.package.map { "  (paquet \($0))" } ?? ""))
        .contextMenu { menu(sn) }
    }

    private func row(_ sn: LatexSnippet) -> some View {
        Button { st.insert(sn, into: model) } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(sn.preview)
                    .font(.system(size: 13, design: .serif))
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sn.name).font(.callout.weight(.medium))
                    Text(sn.latex).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sn.latex + (sn.package.map { "\n(paquet \($0))" } ?? ""))
        .contextMenu { menu(sn) }
    }

    @ViewBuilder
    private func menu(_ sn: LatexSnippet) -> some View {
        Button("Copier le code") { st.copy(sn) }
        if model.texURL != nil { Button("Insérer au curseur") { st.insert(sn, into: model) } }
    }
}
