🇬🇧 English | 🇫🇷 [Français](README.fr.md)

# Toolbox

Toolbox is a piece of software that brings together a set of tools I used every day. The problem was this: sometimes I wanted to use those tools, but without an internet connection it wasn't possible. On top of that, having to jump from one place to another every time I needed a different tool wasted a lot of time. That led me to build this app, where no document ever leaves the computer and everything runs 100% locally.

My original idea was to publish a repo for each mini-project in this app, but that would quickly have become a mess, so I gathered everything into a single repo, just like the app does.

**Unfortunately, this app is only available on macOS for now, but it may be extended to other operating systems someday if I find the motivation.**

> **Note:** the app's interface is currently in **French**. Translating it is on the [roadmap](#roadmap) and help
> is very welcome. In this README, interface labels are given in English with the French label in parentheses
> when it helps you find them.

A native app (Swift, SwiftUI, PDFKit, Vision) plus a `pdftool` terminal command, both sharing the same engine.

**Free software under the [GPL-3.0](LICENSE) license**: contributions are welcome (see
[Contributing](#contributing)).

### What works on any Mac, and what is optional

The core of Toolbox needs nothing special: PDF tools, OCR, LaTeX, My courses, grades and ECTS, calculators,
archives, disk cleanup, local AI. Some **integrations are optional** and designed for specific hardware. The first
launch asks what you have and hides what you don't need:

| Integration | What it needs | Otherwise |
|---|---|---|
| Phone widgets (next shift, My Mac, My day), phone battery | an **iPhone** with [Scriptable](https://scriptable.app) and iCloud Drive | hidden; Android: [to do](#roadmap) |
| Headphone battery, noise cancellation, equalizer, Class mode with headphones | **Nothing / CMF** headphones or earbuds | hidden; other brands: [to do](#roadmap) |
| Work schedule imported from a photo | a schedule laid out as a table (tested with a McDonald's one) | the Planning page can be hidden |
| Degree curriculum in Grades & ECTS | L1 Computer Science at CERI (Avignon, France) provided as an example | create your teaching units by hand, or add your curriculum |

---

## First launch

The Leaf (the mascot) asks a few questions (you can run them again in Settings → General):
- **your first name**;
- **student?** If yes: courses folder and, optionally, the L1 Computer Science (CERI) curriculum in Grades & ECTS.
  If no: My courses, Revisions, Grades & ECTS and their widgets are hidden;
- **do you work? where?** If yes: your name as it appears on the schedule, and the name of the dedicated calendar
  (“Macdo” for a McDonald's), which is created right away. If no: Planning and its widgets are hidden;
- **your devices**: iPhone (Scriptable widgets, iPhone battery) and Nothing headphones (detected if paired).
  Without them, the matching pages, rows and settings disappear;
- **tools to install**: Homebrew, LaTeX (BasicTeX + the packages used by the templates), Ghostscript, 7-Zip,
  GitHub CLI, Ollama and an AI model picked according to the Mac's RAM (3B up to 12 GB, 7B above). The **GitHub
  account** is then connected with one button: the one-time code is shown (and copied), the GitHub page opens, nothing
  to type in Terminal. What is already there is ticked “Installed”, the space required is compared with the free
  space, and installation happens in Terminal (password typed there, never in Toolbox);
- your favourite apps and two permissions (Calendar, Notes).

Everything can be changed later in **Settings → General → My profile / Tools to install**.

## Guided tour

Right after setup (and later via ⌘K → “Visite guidée” or Settings → General), the Leaf shows you around the app with
**its magnifying glass**: the screen dims except for the area being presented, the magnifier lands on it and **really
zooms in** (a capture of the window), and a bubble explains. Sidebar, home and Customize, ⌘K, My courses, Revisions,
Grades & ECTS, Planning, LaTeX (new document, symbols), calculators, archives, headphones: only what matches your
profile. Return / click to move on, ← to go back, Esc to stop.

**Mini tours per tool**: the first time you open My courses, Revisions, Grades & ECTS, Planning, LaTeX, the
Calculator, Compress & archive or Headphones, the Leaf points out 2 to 4 key spots on the page. Run them again with
⌘K → “Visite de cet outil”; turn them off (and reset them) in Settings → General.

## Home

The start page: an animated mascot (the Leaf) and widgets you can arrange however you like.

| Widget | What it does |
|---|---|
| **Quick actions** | New LaTeX document, screenshot → text, sign, merge, compress, compare, drop in a past exam |
| **My apps** | App launcher (VS Code Insiders, iTerm2, Discord… by default), green dot if the app is open, **⌃⌥1 … ⌃⌥9** from anywhere |
| **My courses** | The class happening right now (from the calendar), one tile per subject, recently opened files |
| **VS Code projects** | Pinned and recent VS Code Insiders folders: one click opens them |
| **Today** | Today's events from the Calendar app |
| **Sticky notes** | Creates a note in the Notes app in one click, shows a pinned note as a post-it, adds lines to the pinned note |
| **Weather** | Temperature, sky, feels-like, wind and the next 8 hours. Only appears with an internet connection |
| **Grades & ECTS** | Year average, ring of earned credits, the grade you need on what's left to pass each semester |
| **Planning** | Next shift, hours this week (and per contract), alert if a shift overlaps a class or a test |
| **My Mac** | Battery (gauge, time remaining or to full, health and cycles, alerts at 20 / 10 / 5 %), CPU, memory, free disk, temperature, uptime |
| **Countdowns** | Days left before your tests, midterms, exams (found in the calendar or added by hand) |
| **Clipboard** | The last 20 copied texts, copied again in one click. Nothing written to disk, passwords ignored |
| **Watched folder** | Any PDF dropped into a chosen folder is compressed and/or OCR'd (result in “Traités par Toolbox”) |
| **GitHub** | Your recent repositories (private ones too with `gh`): open on GitHub, clone, open in VS Code Insiders |
| **Recent files**, **All tools** | What you opened in Toolbox, and a shortcut to every tool |

**Arranging widgets:**
- The **handle** at the top of each widget moves it: it lifts up and the others make room for it.
- **Customize** adds or removes widgets (with a checklist) and switches them between half and full width.

**The mascot** puts on sunglasses when it's sunny, takes out an umbrella in the rain and a beanie in the snow.
It sleeps at night, jumps when you click it and celebrates when a LaTeX build passes again without errors.

---

## My courses

Reads your courses folder (e.g. `uapv-cours/cours`) and presents it **by subject**, without moving or renaming
anything.

**How it is organized**
- **Subjects detected automatically**: a folder containing `cours/`, `TDs/`, `TPs/` or `CCs/` is a subject.
  So are its siblings (e.g. `POO/c`, `POO/cpp`). Subjects are grouped by field (Maths, Programming…).
- **Sessions grouped together**: “TD 4” gathers `TD4-Bascules.pdf`, `TD4-Instructions.pdf`, `TD4.py`…
  Numbers are recognized in all their forms (`TD3`, `TP_2`, `chap4`, `5-Logique`, `CC1`, a `1/` folder…).
  (In French universities, *TD* = tutorial, *TP* = lab session, *CC* = continuous-assessment test.)
- A subfolder containing only documents (`cours/2027/`, `CCs/CC1/`) is **expanded**.
  A code folder (`TPs/TP3/`) stays as one block and opens in VS Code Insiders.
- If there are several year folders (`cours/2026`, `cours/2027`), only the most recent year is shown,
  except for tests and past exams.
- Build files and caches (`.o`, `.dtbo`, `__pycache__`…) are hidden.

**Opening and searching**
- **Built-in preview** (Quick Look). Double-click: PDFs open in Preview, code and lab folders in VS Code Insiders,
  `.tex` files in Toolbox's LaTeX editor.
- **Search in names and contents**: PDF text, text files and code, photos read by OCR.
  The PDF opens at the right page with the word highlighted. The index is local
  (`~/Library/Application Support/Toolbox/IndexCours.json`).
- **⌥Space from any app**: a small search window over your courses.

**Working**
- **New**: the next lab or tutorial (folder created and opened in VS Code Insiders), **today's note**
  (`notes/YYYY-MM-DD.md` or `.tex`), **photos of the board** (stored in `notes/photos DD.MM.YYYY/`, made searchable).
- **▶ last TD/TP** reopens what you were working on.
- **Progress**: each session has a *To review*, *Done* or *Understood* badge. Each subject has a progress bar.
- **Hidden answer keys**: files named “correction”, “corrigé” or “solution” are hidden behind a button,
  so you don't stumble on them before trying.
- **Hide** a file or a session with a right-click (nothing is deleted).
- **Dragging files** onto a subject copies them into the right subfolder based on their names.

**Calendar and Annalyse**
- **Class right now**: banner and notification when a class starts, with *Open last TD/TP*, *New TP* and
  *View subject* buttons. Add aliases to a subject (right-click → Rename, colour, aliases)
  if your timetable calls it something else.
- **Practice** builds an exam from the subject's past papers (Annalyse).

---

## My day

- **Morning check** (Settings → General): every morning at the chosen time (7:30 by default), a notification
  sums up the day: today's classes (calendar), shift, next test and progress, and what needs charging
  (the Mac if the day is long, headphones, iPhone). If the Mac is asleep at that time, it arrives on wake. Option: also on
  the iPhone through a reminder.
  **Scheduled wake** (same setting): the Mac wakes up 5 min before the check (`pmset repeat`, password requested),
  Monday to Friday or every day.
- **Sleep**: just before going to sleep, the Mac sends a last status (“💤 asleep since 23:12” on the iPhone);
  on wake, everything is read again and sent (battery, headphones).
- **“My day” iPhone widget** (Scriptable, large or medium): classes (in the evening, tomorrow's), shift with breaks,
  next test with a progress bar, and the battery of the Mac, headphones and iPhone. Data: `ToolboxDay.json`.

## Headphones (“Casque” page)

- Battery (left / right / case for earbuds), noise cancellation, equalizer, bass boost, low
  latency, ring, firmware, and a “Find headphones” button.
- **Class mode** (Headphones page, menu bar, ⌘K): turns on a Focus mode on the Mac, and therefore on the iPhone
  (“Share across devices”), and disconnects the headphones (or transparency / noise cancellation off). Automatic at
  the start and end of classes if you want. Focus is set through two Shortcuts
  (“Toolbox Concentration On / Off”, action “Set Focus”).
- **Automatic mode**: transparency during a class (found in the calendar, as in My courses), your usual mode
  the rest of the time, low latency when a game is in the foreground.

## Revisions

- **Your tests come from the calendar**: the “CCs/Soutenance” calendar (or any calendar named CC, Exams,
  Midterms…, configurable) is read automatically. Each upcoming test gets its **checklist**, linked to the right subject
  based on its title (name, folder name or subject alias).
- **Ready-made checklist**: reread each chapter, redo each tutorial, review the labs, do past tests, practice
  with Annalyse, write a summary sheet. Each line has its **files one click away** (the answer key separately, greyed out).
  Add your own tasks, drop a file to add it, remove a whole section.
- **The next test is pinned** at the top: D-x, progress, pace (“about 2 tasks a day to finish on time”)
  and a **red warning** if you're behind (less than 7 days and less than half done).
- Ticking a session marks it *Done* in My courses. A test moved or renamed in the calendar follows on its own.
- Everywhere: **Next test** widget on Home, banner on the subject page, entry in ⌘K.
- A test missing from the calendar: *New revision*.

## Grades & ECTS

- **Years → semesters → teaching units (UE) → subjects (EC) → assessments**, as in the curriculum: each UE has its
  code, name and ECTS credits, each subject its code, coefficient and assessments (CC1, CC2…). A UE can also stay
  simple (assessments directly). “Import my subjects” creates one UE per subject from *My courses*.
- **L1 Computer Science (CERI) curriculum** in one click (*Year* menu): the 3 UEs of each semester with their subjects and
  codes, plus the elective UE, sport, PIX and support classes **outside the average**. It also sets: no resits,
  compensation between UEs and between S1 and S2.
- **UEs outside the average** (elective, sport, PIX…): graded separately, without weighing on the average or being
  compensated; “obt.” (or “validé”) is enough as a grade.
- **Credits per subject** (CERI rule, turned on by the curriculum): if the UE is not passed, each subject at 10
  or more keeps its credits (green “5 ECTS” badge). L1 curriculum: coefficients = credits (UEs of 11, 13 and 4 ECTS
  in S1; 11, 8 and 9 in S2), sport and PIX at 2 ECTS. Reloading the curriculum updates credits and coefficients without
  erasing your grades.
- **Averages** for each UE, each semester (weighted by ECTS) and the year, provisional until everything
  is graded.
- **The grade you need** on the remaining assessments to pass the UE, the semester and the year.
  If it's no longer reachable, it tells you and counts on compensation.
- **Earned credits**: UE ≥ 10, or compensated if the semester (or year) is passed. Configurable rules: semester
  and yearly compensation, minimum grade, resits or not (*Ratt.* column hidden if there are none).
- **Simulation**: type imaginary grades (in purple) to see what would happen.
- **New year**: same curriculum, with passed UEs carried over (*Acquired last year*) when repeating a year.

## Calculator

Three modes at the top of the page:
- **Graphing**: everything below.
- **Scientific**: like the Mac Calculator in scientific mode. Full keypad (x², xʸ, eˣ, 10ˣ, √, ∛, ʸ√x, ln,
  log, x!, sin/cos/tan and their inverses with *2nd*, sinh…, π, e, EE, Rand, memory mc/m+/m−/mr), degrees or
  radians, live result while typing, parentheses closed automatically, clickable history, `ans`.
- **Programmer**: HEX / DEC / OCT / BIN shown together (a click changes the input base), 8 to 64 bits,
  signed (two's complement) or unsigned, AND, OR, XOR, NOR, NOT, shifts, rotations, byte swap, modulo, clickable
  bits, matching Unicode character, keyboard input (digits, A–F, & | ^ ~ < >).

Graphing mode:
- **Calculations** as on paper: `2x`, `sin x`, `x²`, `√x`, `|x|`, `3!`, `ln(2)·3`, `ans`. The result also gives
  its exact form when it can guess it (`1/3`, `3π/4`, `√2/2`).
- **Functions**: `f(x) = …` plots them, `f(2)` and `f'(1)` evaluate them. An unknown letter (`a`, `k`…) becomes a
  **parameter with a slider**.
- **Graph**: scroll wheel to zoom, drag to pan, pinch on the trackpad, values read under the pointer,
  standard or orthonormal axes, automatic framing.
- **Conversion to LaTeX**: *TeX* button on each function (`\frac`, `\sqrt`, `\mathrm{e}^{…}`, `\sin^{2}`…),
  copied between `$…$` or inserted directly into the open LaTeX document. The graph exports to **TikZ/pgfplots**
  or as an image, the table of values as a `tabular`.
- **Values**: table for several functions, configurable start and step.
- **Limits**: estimate at a point or at ±∞, from the left and right, with the table of values approaching it.
- **Study**: **exact** derivative (symbolic, simplified), tangent at the clicked point, zeros, extrema and
  inflection points within the window.
- The **⌘K** palette also calculates directly (`2^10` → Return copies the result).

Limits and notable points are numerical estimates: they give the result, but your written work still has
to justify it.

## Planning

- **Import** a photo, a screenshot (area to select), a PDF or pasted text.
  The text is read on the Mac (Vision OCR), then shifts are recognized: `Lundi 03/11 9h-14h30`, `mar. 4 nov 11:00-15:30`,
  split shifts (`9h-12h 18h-22h`), closings after midnight (`18h → 1h`), column schedules (one day per column).
  (Recognition is tuned for French-formatted schedules.)
- **Team schedules**: only keeps the row with your first name.
- Before adding: each shift is **editable** (day, hours, break), the read text can be corrected and read again.
- **Calendar**: shifts are added to it (calendar, title and alert of your choice).
- **Hours**: time on site minus the unpaid break (configurable rule), totals for the week and month, comparison with
  contract hours, monthly summary to copy for checking your payslip.
- **Alerts**: a shift overlapping a class, or falling on the day of a test or exam, is flagged.
- **iPhone widget** (free Scriptable app): next shift, countdown, breaks, hours this week,
  on the home screen or lock screen. Toolbox writes `Toolbox.json` to iCloud whenever the schedule changes;
  Planning settings → *Install the widgets in Scriptable* drops the scripts in place.
- **iPhone scripts = launchers**: the script installed in Scriptable only loads
  `iCloud Drive/Toolbox/code/<name>.js`, which Toolbox keeps up to date. Nothing to copy again after an update.
- **“My Mac” iPhone widget**: battery, time remaining, CPU, memory, disk, battery health,
  sent every minute (`ToolboxMac.json`). “Mac asleep?” if nothing has arrived for 10 min.
- **Nothing / CMF headphones**: battery read directly from the headphones (Nothing X's private Bluetooth channel, protocol
  documented by the open-source BudsLink project) every 5 minutes and each time they connect to the Mac. Shown in “My Mac”
  (Mac and iPhone), with the last known value when disconnected, and a reminder when it drops below the threshold.
  **Control panel** (click the headphones row): noise cancellation (low, medium, high, adaptive),
  transparency, equalizer, bass boost (5 levels), low latency, ring the headphones, firmware.
  Also in ⌘K (“Casque : transparence”…) and in the menu bar.
- **iPhone battery on the Mac**: the Scriptable widgets send the phone's battery (`ToolboxPhone.json`);
  it is shown in “My devices”, with a notification on the Mac below the threshold. Settings and scripts:
  Home → Customize → *Widgets on the iPhone*.
- **Battery alert on the iPhone**: below 20 % (configurable in Settings → General), Toolbox creates a
  “🔋 Recharge ton Mac” reminder in the Reminders app, which rings on the iPhone and ticks itself off when the Mac is plugged in.

---

## PDF tools

| Section | Tool | What it does |
|---|---|---|
| Pages | **Organize** | Thumbnails: drag to reorder, rotate, delete, extract, add pages from other PDFs |
| | **Merge** | Several PDFs → one, order by drag and drop |
| | **Split** | One page per file, every N pages, ranges (`1-3, 5, 8-`), extraction |
| | **Layout** | Crop margins (auto or in mm, lossless), 2 or 4 pages per sheet, A5 booklet |
| | **Convert** | Images → PDF, PDF → PNG/JPEG, PDF → text, **RAG export** (Markdown or JSONL, one entry per page) |
| | **Numbering & watermark** | Page numbers, header, footer, watermark, with live preview |
| | **Security & info** | Add / remove a password, edit title, author, subject, keywords |
| | **Compare** | Two versions of a PDF: pages matched even if some were added or removed, overlay (red = removed, green = added), side by side, text differences, PDF report |
| | **Sign** | Signature drawn on the trackpad or imported (white background removed), placed, moved and resized on the page, signed PDF (text still selectable) |
| Optimize | **Compress & archive** | PDF: 3 levels, Ghostscript if installed, otherwise PDFKit. **Archives**: create a .zip, .tar.gz, .tar.bz2, .tar.xz or .7z (files and folders, 3 levels, password with zip or 7z AES, no junk files, no LaTeX build files, “ready to hand in” mode for a lab without .git or binaries); **extract** with a preview of the contents, everything or a selection, with password |
| | **OCR** | Makes scans searchable and copyable (Apple Vision, offline, French + English) |
| | **Batch processing** | OCR → numbering/watermark → author → compression → renaming, on a whole folder |
| | **Clean up the Mac** | Caches, build files, LaTeX auxiliary files, trash, old downloads, large files, duplicates, AI models (see below) |

**Screenshot → text** (⇧⌘T, ⌘K, menu bar): select an area of the screen, the text is read offline and copied.

---

## Clean up the Mac

An analysis of what takes up space, sorted by category, with the size of each and a disk bar
(showing in green what the selection will free):
- **safe**, ticked by default and deleted directly because they rebuild themselves: app caches, development
  caches (Xcode DerivedData, Homebrew, npm, pip, Swift, Toolbox build), project build folders
  (`node_modules`, `.build`, `__pycache__`, `venv`, CMake `build`…), LaTeX auxiliary files
  (`.aux`, `.log`, `.synctex.gz`… only next to a `.tex`);
- **to check**, moved to the trash: downloads not opened for 60 days, files over 300 MB,
  duplicate PDFs (exact same content, the oldest is kept);
- the **trash** (emptied permanently) and **Ollama models** (removed with `ollama rm`).
Each item has its checkbox, a preview of its folder and a button to show it in Finder. Nothing goes without
confirmation, and the result tells you how many GB were freed.

## Updating Toolbox

Settings → General → *Update* (or ⌘K → “Mettre à jour Toolbox”): `git pull` (if there are no
uncommitted changes), `./build.sh --no-install` with a live log and the tests, then a small script
replaces the app in `~/Applications`, updates `pdftool` and relaunches Toolbox. At launch, the app quietly checks
whether there is anything new on GitHub or whether the code has changed since the last build, and tells you.
The code folder is recorded by `build.sh` (otherwise: *Choose…* button). Install log:
`~/Library/Logs/Toolbox-update.log`.

## Local AI (Ollama)

Toolbox **starts Ollama on its own** at launch if it isn't running (Settings → General → Local AI): it opens the
Ollama app if installed, otherwise runs `ollama serve` in the background (and stops it on quit). The server alone
uses almost no memory: a model is only loaded when a request is made. Recommended model on a MacBook Air:
`ollama pull qwen2.5-coder:7b`.

## LaTeX

A small offline Overleaf: code on the left, PDF on the right.

**Editing**
- Syntax highlighting, line numbers, **auto-closing** of `{ [ $`, `\begin{…}` that adds its `\end{…}`.
- **Completion** for commands, environments, `\ref{}` (your `\label`s), `\cite{}` (`.bib` keys) and images.
- Clickable **outline** (sections, exercises), **tabs** for `\input` / `\include` files.
- **Drop an image**: copied into `images/` and a `figure` block added. **Paste a table** from Excel or Numbers: `tabular`.

**Building**
- Build with **⌘B** (latexmk, pdflatex, xelatex or lualatex). Autosave, rebuild while typing (“Auto”).
- **Clickable errors** and an **✨ Explain** button: the local AI explains the error and suggests corrected lines, applied in one click.
- **SyncTeX** both ways: ⌘-click in the PDF, or “Cursor → PDF” (⌘L).

**Everything else**
- **History**: a version kept at each build, comparison and restore.
- **My documents** (⇧⌘O, toolbar button, ⌘K, or the list under “New document” when nothing is open):
  every document created with Toolbox, those in `Documents/Toolbox LaTeX` and recently opened `.tex` files, with search
  and a filter by type. Double-click or ✎ to reopen and edit, 🗑 to **move to the trash** (after confirmation):
  the whole folder if it only contains that document, otherwise just the `.tex` and its build files
  (a PDF assignment or your other files stay). Recoverable from the Trash.
- **Symbols & formulas** (⇧⌘M, √x button or ⌘K): more than 230 symbols and formulas ready to paste, with search
  (“union”, “xor”, “dérivée produit”…): sets (ℕ ℤ ℚ ℝ ℂ ∅ ∈ ∉ ⊆ ⊈ ∪ ∩ ∖ 𝒫(E)…), logic (∀ ∃ ¬ ∧ ∨ ⊕ ⇒ ⇔, De Morgan…),
  maps (↦, composition, image / preimage, injective…), relations, analysis (lim, ∫, ∑, ⌊x⌋, o, O…),
  formulas (ε-δ, standard limits, derivatives, IVT, MVT, binomial theorem, Taylor expansions…), structures (cases, systems,
  align, matrices, variation tables, truth tables, induction), Greek letters, arrows, computer science. Click = insert at
  the cursor (or between `$…$`), right-click = copy; the most recent ones stay under “Recent”. If a symbol needs
  `amssymb` or `mathtools` and the document doesn't load it, a button adds it.
- **Formula from a photo**: image or screenshot → LaTeX code (Ollama vision model) → preview → insertion.
- **New document** (⇧⌘N, ⌘K or Home): Toolbox asks for the type, **TD, TP, Course, Weekly test, Report or Other**,
  and creates a pre-filled template in the style of the Annalyse templates (`annales.cls`, project notebook),
  self-contained (no class file to copy):
  - *TD* (tutorial): “TD n – topic” header, objective, automatically numbered exercises and questions, hideable
    answers (`\corrigefalse`);
  - *TP* (lab): “To hand in” box, build instructions, boxed answers, syntax-highlighted code in the chosen language
    (C, C++, Python, Java…);
  - *Course*: title page, table of contents, definition / theorem / property / method / example / warning boxes;
  - *Weekly test*: that week's “Test de connaissances” in large type (14 pt), I / Recall and II / Compute,
    blank space for answers, “Note : / 5”; number of questions, marking scheme and week configurable, answer version
    with one switch;
  - *Other* + a description (“a two-sided, two-column revision sheet on sequences…”): the **local AI**
    (Ollama) writes a custom template in the same style; Toolbox builds it and sends the errors back to it
    (3 attempts at most) before opening it;
  - *Report*: project-notebook title page, objective / deliverable boxes, table.
  The subject comes from “My courses” (the current class by default), the next number is suggested, and the file is
  stored in the right folder (`Analyse 1/TDs/TD4/TD4.tex`) or in `Documents/Toolbox LaTeX`.
- Project from an older template (Beamer…), word count, undefined references.

---

## Annalyse (past-exam bank)

Drop any file (PDF, scan, crooked photo, Word…). Toolbox chains:
1. reading and OCR;
2. identification (university, level, subject, year, session) and duplicate detection;
3. splitting into one PDF per exam;
4. **transcription to LaTeX with `annales.cls` by the local AI**, with fidelity and plausibility checks;
5. compilation with self-repair, then tags per exercise;
6. filing, with an SQLite database, review, search and statistics on which topics come up.

- **Build a practice exam**: pick exercises from the bank (⊕) or draw them at random by subject and topic.
  The exam is assembled in the annales class, with the source of each exercise, and opened in the LaTeX editor.
- **Cleanup**: delete an exam (right-click) or empty the bank (moved to the trash).

Requirements: Ollama and a model that can read images.

```bash
ollama pull qwen2.5vl:7b
```

In Annalyse → Settings:
- choose the **Annalyse** folder (the one containing `config/` and `latex/`) and the **bank** folder;
- `matieres.yaml`, `notions.yaml`, `etablissements.yaml` and `latex/modele_annale.tex` can be edited without touching the code.

In the terminal: `pdftool annales depot.pdf photo.heic --annalyse ~/…/Annalyse --model qwen2.5vl:7b`

---

## Everywhere on the Mac

| Shortcut | Where | What it does |
|---|---|---|
| **⌘K** | in Toolbox | Palette: tools, actions, subjects, sessions (“td 3 struct”), projects, apps, recent files, “Create the note …” |
| **⌥Space** | everywhere | Search your courses (names and contents) |
| **⌃⌥1 … ⌃⌥9** | everywhere | Launch the apps from the “My apps” widget |
| **⇧⌘T** | in Toolbox | Screenshot → text |
| **⌘,** | in Toolbox | Settings (shortcuts, notifications) |

**Menu bar** (wrench-and-screwdriver icon): sticky notes, screenshot → text, drop a PDF to compress,
clipboard and apps. Closing the window keeps Toolbox in the menu bar. To quit: ⌘Q.

**From Finder:**
- drag a file onto the Dock icon, or right-click → Open With → Toolbox;
- right-click on PDFs → **Services** → *Toolbox : Compresser / Fusionner / Rendre cherchable (OCR) / Ouvrir*
  (compress / merge / make searchable / open). If they don't appear: System Settings → Keyboard → Keyboard Shortcuts →
  Services, and tick them.

---

## Installation

### From source

Requirements: macOS 13 or later and Apple's command line tools (`xcode-select --install`).
Full Xcode is not needed.

```bash
./build.sh
```

- The app is installed in `~/Applications/Toolbox.app`, the command in `~/.local/bin/pdftool`.
- Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc` to use `pdftool` everywhere.

### From a .dmg (for another Mac)

```bash
./build.sh && ./make-dmg.sh       # creates build/Toolbox-<version>.dmg
```

The .dmg contains the app and a shortcut to Applications: drag one onto the other. The app is not signed
with an Apple developer account: the first time, **right-click Toolbox → Open** (or System Settings →
Privacy & Security → “Open Anyway”). Avoiding this requires a *Developer ID* certificate and Apple
notarization (`notarytool`).

### Dependencies

| Tool | What Toolbox uses it for | Required | How to get it |
|---|---|---|---|
| macOS 13 (Ventura) or later | — | yes | — |
| Apple command line tools: `swift`, `clang`, `git` | building Toolbox, built-in updates | yes, to build | `xcode-select --install` |
| [Homebrew](https://brew.sh) | installing the tools below | no | setup or Settings → *Tools to install* |
| Ghostscript (`gs`) | much more effective PDF compression (otherwise PDFKit) | no | setup (`brew install ghostscript`) |
| BasicTeX + packages (`pdflatex`, `xelatex`, `latexmk`, `synctex`, `texcount`, `tcolorbox`…) | LaTeX editor, templates, symbols, Annalyse | no (LaTeX tab) | setup (`brew install --cask basictex` + `tlmgr`) |
| [Ollama](https://ollama.com) + a model (`qwen2.5-coder:3b`, or `:7b` with 16 GB of RAM) | local AI: LaTeX errors, formula from a photo, custom templates, Annalyse | no | setup (`brew install ollama`, `ollama pull …`) |
| 7-Zip (`7zz`) | create and open .7z, open protected .rar | no | setup (`brew install sevenzip`) |
| GitHub CLI (`gh`) + login | private repositories in the GitHub widget, clone without a password | no | setup, then **Sign in** in the app (one-time code, no Terminal) |
| VS Code Insiders (or VS Code) | open tutorials/labs, projects, errors at the right line | no | [code.visualstudio.com/insiders](https://code.visualstudio.com/insiders) |
| On the iPhone: [Scriptable](https://scriptable.app) | Next shift, My Mac, My day widgets | no | App Store |
| Shortcuts (Mac): “Toolbox Concentration On / Off” | Class mode (Focus on the Mac and iPhone) | no | create once (explained on the Headphones page) |

Tools already in macOS and used as is: `hdiutil` (the .dmg), `zip` / `unzip` / `tar` (archives),
`shortcuts` (Class mode), `pmset` (scheduled wake), `osascript` (Notes, administrator password),
`lsregister` (“Open With”), Vision (OCR) and PDFKit.

### Additional tools

The **first launch** (and Settings → General → *Tools to install*) detects what's missing and installs it in
Terminal in one click. By hand:

```bash
brew install ghostscript              # much more effective PDF compression
brew install --cask basictex          # lightweight LaTeX (or mactex-no-gui, complete but ~5 GB)
sudo tlmgr install latexmk tcolorbox pgf environ trimspaces needspace comment lastpage titlesec enumitem \
     csquotes babel-french fancyhdr booktabs lm helvetic texcount   # packages used by the templates
brew install ollama                   # local AI
ollama pull qwen2.5-coder:3b          # lightweight model (7b with 16 GB of RAM or more)
brew install sevenzip                 # .7z and .rar archives
brew install gh && gh auth login      # private GitHub repositories (or “Sign in” in the app)
```

## Permissions requested

All are optional: macOS asks for them the first time the feature is used, and the app works
without them (the feature concerned is simply disabled). Manage them in System Settings → Privacy &
Security.

| Permission | What for | When it is requested |
|---|---|---|
| **Calendars** (full access) | today's events, “class right now”, upcoming tests (Revisions, countdowns), work calendar and schedule shifts | setup, or first opening of Home / Planning |
| **Reminders** | “Recharge your Mac” alert that rings on the iPhone, evening reminder (Mac and headphones to charge) | when you turn these alerts on |
| **Notifications** | class start, low iPhone battery, morning check | on the first notification |
| **Bluetooth** | Nothing headphones battery and settings, Class mode (disconnecting the headphones) | first headphones read |
| **Automation → Notes** (Apple Events) | sticky notes, pinned note on Home | setup, or first sticky note |
| **Screen Recording** | “Screenshot → text”, schedule import from a screenshot | first capture |
| **Desktop, Documents, Downloads folders** | courses and LaTeX documents, *Clean up the Mac* (old downloads, large files) | when these folders are first read |
| **Administrator password** (once) | scheduled Mac wake for the morning check (`pmset`) | when you turn on wake |
| **Password in Terminal** | installing tools (Homebrew, LaTeX packages): typed in Terminal, never seen by Toolbox | when you click “Install” |
| **GitHub sign-in** (one-time code) | private repositories: github.com/login/device opens, you paste the code | when you click “Sign in” |

No system permission for: iCloud Drive (`Toolbox/` folder shared with the iPhone), Ollama (on the machine,
`127.0.0.1`), weather (Open-Meteo, no account), Finder Services and ⌥Space.

---

## Terminal command

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

# Optimize / edit
pdftool compress *.pdf --level strong
pdftool ocr annale-2019.pdf
pdftool number td.pdf --header "Analyse 1 — TD 3" --skip-first
pdftool watermark copie.pdf "DRAFT"
pdftool protect notes.pdf mypassword
pdftool meta cours.pdf --author "Arthur" --keywords "analysis, sequences"

# Convert
pdftool img2pdf copie.pdf IMG_01.jpg IMG_02.jpg
pdftool pdf2img slides.pdf --dpi 300 --pages "4-6"
pdftool text article.pdf
pdftool rag cours/*.pdf --format jsonl

# Batch
pdftool batch processed-exams annales/*.pdf --ocr --compress balanced --rename "annale_{n}"

# LaTeX
pdftool new "Analyse 1 — Suites" --template cours
pdftool tex main.tex --watch
pdftool words main.tex
pdftool clean main.tex
```

Page ranges: `1-3, 5, 8-` (`8-` = to the end, `-3` = from the start).

---

## Where the data lives

| What | Where |
|---|---|
| Settings, Home layout, course progress | app preferences (`defaults read fr.arthur.toolbox`) |
| LaTeX history | `~/Library/Application Support/Toolbox/Historique/` |
| Signatures | `~/Library/Application Support/Toolbox/Signatures/` |
| Course search index | `~/Library/Application Support/Toolbox/IndexCours.json` |
| Grades and credits | `~/Library/Application Support/Toolbox/Notes.json` |
| Planning | `~/Library/Application Support/Toolbox/Planning.json` |
| Revisions | `~/Library/Application Support/Toolbox/Revisions.json` |
| New LaTeX documents | `~/Documents/Toolbox LaTeX/` (or the subject's folder: `TDs/TD4/`, `Tests/`…) |
| “My documents” list, profile, tours seen | app preferences |
| Calculator (functions, history) | app preferences |
| Data shared with the iPhone | iCloud Drive → `Toolbox/` (ToolboxMac.json, ToolboxDay.json, Scriptable scripts) |
| Past-exam bank | the folder chosen in Annalyse → Settings |

Nothing is written into your courses folder, except what you create yourself (new TD/TP, notes, photos, dropped files).

---

## Development

```bash
swift build                 # build
swift run Toolbox           # run the app without creating the .app
swift run pdftool --help
```

```
Sources/
  PDFCore/    shared engine: pages, drawing, compression, OCR, comparison, signature, LaTeX,
              Annalyse (Annales/), course library and index, GitHub, VS Code
  Toolbox/    SwiftUI app: one view per tool, Home and widgets, My courses, LaTeX editor,
              grades and ECTS, calculators (MathEngine.swift, ClassicCalc.swift), planning, headphones, archives
              (ArchiveTool.swift), LaTeX templates (LatexDocTypes.swift), symbol library
              (LatexLibrary.swift), local AI (OllamaService.swift, LatexAIDoc.swift), profile and tools to install
              (Profile.swift), guided tour (Tour.swift), ⌘K palette, menu bar,
              disk cleanup (Cleanup.swift), built-in updates (Updater.swift), GitHub sign-in (GitHubLogin.swift)
  pdftool/    terminal command
Resources/    Info.plist (file types, Services, permissions) + icon
build.sh      builds outside the folder (Nextcloud), assembles the .app, registers it with macOS
make-dmg.sh   makes the .dmg from build/Toolbox.app
```

- **Tests**: `build.sh` runs `Toolbox --selftest` after each build: calculators (graphing,
  scientific, programmer), limits, grades and ECTS (including a full S1 example), schedule parsing and breaks,
  headphones CRC, LaTeX templates, symbol library, AI answer extraction, document deletion,
  archives, guided-tour placement. Code in `SelfTest.swift`; run it by hand with
  `~/Applications/Toolbox.app/Contents/MacOS/Toolbox --selftest`.
- Views don't use `@State`, a macro missing from the Command Line Tools on recent SDKs:
  each tool has a small `ObservableObject`.
- Add a tool: a function in `PDFCore`, a case in the `Tool` enum, a view in `Toolbox`,
  a subcommand in `pdftool/main.swift`.
- Add a widget: a case in `HomeWidget` (`HomeWidgets.swift`) and its view in `HomeView.widget(_:)`.
- Show something in the guided tour: `.tourTarget("id")` on the view, then a step in
  `TourStore.buildSteps()` or `TourStore.miniSteps(_:)` (`Tour.swift`).
- Hide a tool depending on the profile: `AppProfile.shows(_:)` / `allows(_:)` (`Profile.swift`).

---

## Roadmap

Areas where help would be valuable:
- **Interface translation**: everything is in French for now. English first, other languages welcome.
- **Android**: an equivalent of the iPhone widgets (Scriptable only exists on iOS). Idea: a JSON file served by
  Nextcloud / WebDAV or a small local server, read by a widget app such as KWGT.
- **Other headphones**: the generic battery of Bluetooth devices known to macOS (AirPods, Beats, Sony, Bose…), then
  advanced settings brand by brand (the Nothing headphones code is in `Headphone.swift`).
- **Other degree curricula** for Grades & ECTS (`GradesStore.l1InfoAvignon()` serves as a model).
- **Other work schedules** than a McDonald's one (`ShiftParser` in `PlanningView.swift`).
- **Linux / Windows** someday: `PDFCore` and `pdftool` are the most portable parts, the SwiftUI interface is not.

## Contributing

Everything is explained in [CONTRIBUTING.md](CONTRIBUTING.md): building, running the tests, adding a tool, a widget
or a headphone model. Ideas and bugs go in *Issues* (templates are ready).

## License and credits

Toolbox is distributed under the **GNU GPL v3.0**: you may use, study, modify and redistribute it, provided
that modified versions stay under the same license and their source code is available.
Full text: [LICENSE](LICENSE).

- Bluetooth protocol for Nothing / CMF headphones: documented by the open-source project
  [BudsLink](https://github.com/maniacx/BudsLink) (GPL-3.0).
- Local AI: [Ollama](https://ollama.com). Weather: [Open-Meteo](https://open-meteo.com).
- LaTeX: [TeX Live](https://tug.org/texlive/) / BasicTeX. Compression: [Ghostscript](https://ghostscript.com) (AGPL),
  called as an external program, not bundled.
