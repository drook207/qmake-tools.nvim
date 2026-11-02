# qmake-tools.nvim

qmake-Projekte in Neovim bauen, starten und mit clangd (LSP) nutzen – angelehnt an
[cmake-tools.nvim](https://github.com/Civitasv/cmake-tools.nvim).

- `:QMakeGenerate` führt qmake aus und erzeugt eine `compile_commands.json`
  (per `compiledb` oder eingebautem Generator)
- die Datei wird ins Projekt-Root verlinkt und clangd automatisch neu gestartet
- Build-Ausgabe läuft asynchron in die Quickfix-Liste (Fehler direkt anspringbar mit `:cn`/`:cp`)
- Debug/Release-Builds in getrennten Verzeichnissen, umschaltbar
- `:QMakeRun` baut und startet das Programm in einem Terminal-Split
- funktioniert auch mit `TEMPLATE = subdirs` (mehrere Programme → Auswahl)
- Speichern einer `.pro`/`.pri` aktualisiert die Datenbank automatisch
- Linux, macOS und Windows (MinGW, LLVM-MinGW, MSVC) – siehe [Windows](#windows)

## Voraussetzungen

- Neovim ≥ 0.10
- `qmake` / `qmake6`, `make` (unter Windows: siehe [Windows](#windows))
- optional `compiledb` (`pip install compiledb`) oder `bear` – ohne beide liest der
  eingebaute Generator die Makefiles direkt
- `clangd` als Language Server

Prüfen mit `:checkhealth qmake-tools`.

### Wie qmake gefunden wird

Jede Konfiguration nutzt das qmake ihres Kits. Automatisch erkannt werden:
`$QMAKE`, `qmake`/`qmake-qt5`/`qmake6` im PATH, `~/Qt/<version>/gcc_64/bin` (Online-Installer),
`/opt/Qt/...`, `/usr/lib/qt5/bin`, `/usr/lib/qt6/bin`, Homebrew u. a. Wird nichts davon
gefunden, wird die Shell-Konfiguration (`.bashrc`, `.zshrc`, `.profile`) nach Aliasen und
PATH-Einträgen befragt. Unter Windows: `<Laufwerk>:\Qt\…` auf allen Laufwerken, siehe
[Windows](#windows). Alles Weitere unter [Kits](#kits).

## Installation

**lazy.nvim**

```lua
{
  dir = "~/pfad/zu/qmake-tools.nvim",   -- bzw. "user/qmake-tools.nvim" nach Upload auf GitHub
  ft = { "cpp", "c", "qmake" },
  cmd = { "QMakeGenerate", "QMakeBuild", "QMakeRun", "QMakeSelectBuildType" },
  opts = {},
}
```

**Ohne Plugin-Manager**: Ordner nach
`~/.local/share/nvim/site/pack/plugins/start/qmake-tools.nvim` kopieren.

## Kits und Konfigurationen

Wie in Qt Creator gibt es zwei Ebenen:

- **Kit** = eine Qt-Version samt Toolchain und Umgebung (z. B. „Qt 5.12 Desktop“,
  „Qt 5.15 Raspberry Pi“). Kits gelten global für alle Projekte.
- **Konfiguration** = pro Projekt eine benannte Kombination aus Kit, Build-Typ,
  qmake-Argumenten und Startargumenten. Jede hat ein eigenes Build-Verzeichnis,
  ein Wechsel ist daher sofort möglich, ohne neu zu bauen.

### Kits

Installierte Qt-Versionen werden automatisch erkannt (`~/Qt/<version>/…`,
`/usr/lib/qt5/bin`, PATH, …). Eigene Kits kommen in `setup()`:

```lua
opts = {
  default_kit = "Qt 5.15 Desktop",     -- für neue Konfigurationen
  kits = {
    { name = "Qt 5.15 Desktop", qmake = "~/Qt/5.15.2/gcc_64/bin/qmake" },
    { name = "Qt 5.12 Desktop", qmake = "~/Qt/5.12.12/gcc_64/bin/qmake" },

    -- Cross-Compile mit eigener Qt-Installation und Toolchain im PATH
    { name = "Raspberry Pi 4",
      qmake = "/opt/qt5pi/bin/qmake",
      spec = "devices/linux-rasp-pi4-v3d-g++",          -- optional, sonst Standard-spec der Qt-Installation
      path = { "/opt/cross-pi-gcc/bin" },               -- vorne an PATH
      env = { PKG_CONFIG_SYSROOT_DIR = "/opt/rpi-sysroot" },
      run = false },                                     -- nicht lokal starten

    -- Yocto/Boot2Qt-SDK: Umgebungsskript wird vorher geladen
    { name = "Yocto aarch64",
      qmake = "qmake",                                   -- wird im PATH des Skripts gesucht
      env_script = "/opt/poky/4.0/environment-setup-cortexa72-poky-linux",
      run_prefix = { "qemu-aarch64", "-L", "/opt/poky/4.0/sysroots/cortexa72-poky-linux" } },
  },
}
```

| Feld | Bedeutung |
|---|---|
| `name` | Anzeigename (Pflicht) |
| `qmake` | Pfad zu qmake oder Name im PATH des Kits (Pflicht) |
| `spec` | mkspec, wird als `-spec` übergeben |
| `path` | Verzeichnisse, die vorne an `PATH` gehängt werden |
| `env` | zusätzliche Variablen, `${VAR}` wird ersetzt |
| `env_script` | Shell-Skript, das vorher geladen wird (Yocto, Boot2Qt, …); unter Windows auch `.bat`/`.cmd`, mit Argumenten als Liste |
| `make` | anderes make-Programm (Standard: passend zur Toolchain) |
| `toolchain` | Windows: `false` = Compiler nicht automatisch suchen |
| `vcvarsall` | Windows/MSVC: Pfad zu `vcvarsall.bat` (Standard: per vswhere), `false` = nicht laden |
| `msvc_arch` | Windows/MSVC: Argument für `vcvarsall.bat` (Standard: aus der Qt-Installation, z. B. `x64`) |
| `qmake_args` | zusätzliche qmake-Argumente nur für dieses Kit |
| `run` | `false` = `:QMakeRun` ist gesperrt |
| `run_prefix` | wird beim Starten vorangestellt, z. B. qemu oder ein ssh-Skript |

Kits lassen sich auch ohne Konfigurationsdatei registrieren; sie werden dann in
`stdpath("data")/qmake-tools-kits.json` gespeichert:

```vim
:QMakeKitAdd "Qt 5.9 Legacy" /opt/Qt5.9.9/5.9.9/gcc_64/bin/qmake
:QMakeKitAdd                       " fragt Pfad und Name ab
:QMakeKits                         " alle Kits mit Version, Quelle und Problemen
:QMakeKits!                        " Installationen neu suchen
```

### Konfigurationen

```vim
:QMakeConfigNew pi                 " Kopie der aktiven Konfiguration, danach Kit wählen
:QMakeSelectKit Raspberry Pi 4     " Kit der aktiven Konfiguration ändern
:QMakeSelectConfig                 " zwischen Konfigurationen wechseln
:QMakeConfigRename / :QMakeConfigDelete
```

Build-Typ, qmake-Argumente und Startargumente gehören jeweils zur aktiven
Konfiguration. Beim Wechsel wird die passende `compile_commands.json` verlinkt
und clangd neu gestartet. Neu generiert wird nur, wenn es für die Konfiguration
noch keine gibt.

Das Build-Verzeichnis ist standardmäßig `build/<konfiguration>/<kit>-<buildtyp>`,
z. B. `build/pi/raspberry-pi-4-release`. Anpassbar über `build_dir` mit den Platzhaltern
`${config}`, `${kit}`, `${build_type}` und `${build_type_lower}`.

### Cross-Compiling und clangd

`compile_commands.json` enthält den vollen Pfad zum Cross-Compiler. Damit clangd
dessen System-Header und Sysroot findet, muss es den Compiler abfragen dürfen:

```lua
vim.lsp.config("clangd", {
  cmd = { "clangd", "--query-driver=/opt/cross-pi-gcc/bin/*,/opt/poky/**/bin/*" },
})
```

Ohne `--query-driver` meldet clangd bei Cross-Konfigurationen fehlende Standard-Header.

## Windows

Unter Windows stellt das Plugin die Build-Umgebung so her wie Qt Creator – ohne
„Developer Command Prompt“ und ohne Compiler im PATH:

- **Qt-Installationen** werden auf allen Laufwerken gefunden: `C:\Qt`, `D:\Qt`, …
  (`<Version>\mingw*`, `<Version>\llvm-mingw*`, `<Version>\msvc*`, auch verschachtelte
  Offline-Installationen wie `D:\Qt\5.12.12\5.12.12\mingw73_64`). Android- und
  WebAssembly-Builds werden übersprungen, ARM64-Qt auf x64-Rechnern als Cross-Kit markiert.
- **MinGW / LLVM-MinGW**: der passende Compiler aus `<Qt-Root>\Tools` kommt in den PATH
  (`mingw81_64` → `Tools\mingw810_64`, `mingw73_64` → `Tools\mingw730_64`, Qt 6
  `mingw_64` → neuestes `Tools\mingw*_64`). make ist `mingw32-make`.
- **MSVC**: `vcvarsall.bat` der neuesten Visual-Studio-Installation (per `vswhere`) wird
  mit der Architektur der Qt-Installation geladen (`msvc2019_64` → `x64`). Gebaut wird mit
  `jom` aus Qt Creator (parallel), sonst `nmake`. qmake bekommt `-FC`, damit Fehler mit
  vollständigem Pfad in der Quickfix-Liste landen. Das Laden dauert einige Sekunden und
  passiert einmal pro Sitzung und Architektur.
- Das `bin`-Verzeichnis der Qt-Version steht beim Bauen und Starten im PATH. Zur Laufzeit
  kommen die Verzeichnisse der im Projekt gebauten DLLs dazu (statt `LD_LIBRARY_PATH`).
- Wie in Qt Creator erzeugt qmake `Makefile.Debug`/`Makefile.Release`; Programme liegen
  in `debug\` bzw. `release\` und werden dort gefunden.
- `compile_commands.json` erzeugt der eingebaute Generator (compiledb versteht nur
  GNU make, `bear` gibt es nicht für Windows). Bei MinGW enthält sie den vollen
  Compilerpfad; clangd braucht dann `--query-driver`:

```lua
vim.lsp.config("clangd", {
  cmd = { "clangd", "--query-driver=D:/Qt/Tools/**/bin/*.exe" },
})
```

Ein Kit lässt sich wie gewohnt manuell anlegen – die Toolchain wird trotzdem
automatisch ergänzt. Abweichungen gezielt einstellen:

```lua
kits = {
  -- MinGW außerhalb der Qt-Installation
  { name = "Qt 5.15 MinGW", qmake = "D:/Qt/5.15.2/mingw81_64/bin/qmake.exe", path = { "C:/mingw64/bin" } },
  -- bestimmte Visual-Studio-Version
  { name = "Qt 5.15 MSVC", qmake = "D:/Qt/5.15.2/msvc2019_64/bin/qmake.exe",
    vcvarsall = "C:/Program Files/Microsoft Visual Studio/2019/Professional/VC/Auxiliary/Build/vcvarsall.bat" },
}
```

`:checkhealth qmake-tools` zeigt pro Kit, welcher Compiler und welches make
verwendet werden, `:QMakeInfo` dasselbe für die aktive Konfiguration.

## Befehle

| Befehl | Funktion |
|---|---|
| `:QMakeGenerate` | qmake ausführen, `compile_commands.json` erzeugen und verlinken |
| `:QMakeBuild [target]` | bauen (generiert vorher automatisch, falls nötig) |
| `:QMakeRun` | bauen und Programm im Terminal starten |
| `:QMakeArgs [args]` | zusätzliche qmake-Argumente für dieses Projekt setzen; ohne Argumente bearbeiten; `:QMakeArgs!` löscht |
| `:QMakeArgsAdd args` | qmake-Argumente anhängen |
| `:QMakeRunArgs [args]` | Startargumente setzen; ohne Argumente bearbeiten; `:QMakeRunArgs!` löscht |
| `:QMakeSelectBuildType [Debug\|Release]` | Build-Typ wechseln |
| `:QMakeSelectTarget` | Programm wählen (bei mehreren ausführbaren Dateien) |
| `:QMakeSelectProject` | `.pro`-Datei wählen (bei mehreren im Root) |
| `:QMakeSelectConfig [name]` | Konfiguration wechseln |
| `:QMakeConfigNew [name]` / `:QMakeConfigRename [name]` / `:QMakeConfigDelete [name]` | Konfigurationen verwalten |
| `:QMakeSelectKit [name]` | Kit der aktiven Konfiguration wählen |
| `:QMakeKits[!]` | Kits anzeigen (`!` = neu suchen) |
| `:QMakeKitAdd ["Name" qmake [spec]]` / `:QMakeKitRemove [name]` | Kits registrieren / entfernen |
| `:QMakeClean` / `:QMakeRebuild` | `make clean` / clean + build |
| `:QMakeStop` | laufenden Vorgang abbrechen |
| `:QMakeOpenExecutor[!]` | Ausgabefenster öffnen und hineinspringen (`!` = Fokus behalten) |
| `:QMakeCloseExecutor` / `:QMakeToggleExecutor` | Ausgabefenster schließen / umschalten |
| `:QMakeInfo` | aktuelle Einstellungen anzeigen |

`.pro`-Datei, Konfigurationen und aktive Konfiguration werden pro Projekt gespeichert
(`stdpath("data")/qmake-tools.json`). Zustände älterer Versionen werden automatisch
in eine Konfiguration `default` übernommen.

### qmake-Argumente pro Projekt

```vim
:QMakeArgs DEFINES+=MEIN_FLAG CONFIG+=c++20     " setzen (ersetzt vorhandene)
:QMakeArgsAdd CONFIG+=sanitizer                 " anhängen
:QMakeArgs                                      " aktuelle Argumente im Eingabefeld bearbeiten
:QMakeArgs!                                     " alle löschen
:QMakeArgs -spec linux-clang                    " <Tab> nach -spec listet die mkspecs
```

- Argumente werden wie in der Shell getrennt: `"..."` oder `'...'` fassen Leerzeichen zusammen.
- Sie gelten für die aktive Konfiguration (alle Build-Typen) und kommen im qmake-Aufruf
  nach `qmake_args`, den `qmake_args` des Kits und `build_type_args`, haben also Vorrang.
- Nach jeder Änderung wird automatisch neu generiert (sofern schon ein Build existiert),
  damit clangd die neuen Flags bekommt.
- Den kompletten qmake-Aufruf zeigt `:QMakeInfo`.
- `<Tab>` vervollständigt gängige Einträge wie `CONFIG+=c++20` oder `QMAKE_CXXFLAGS+=`.

## Executor (Ausgabefenster)

qmake, compiledb und make schreiben ihre Ausgabe live in ein eigenes Fenster,
wie der Executor von cmake-tools. Fehler, Warnungen und Abschnitte sind farbig
hervorgehoben, die Statuszeile zeigt den Zustand (⟳ läuft, ✓ fertig, ✗ Fehler).

Im Fenster:

| Taste | Funktion |
|---|---|
| `<CR>` | zur Fehlerstelle unter dem Cursor springen |
| `]e` / `[e` | nächster / vorheriger Fehler |
| `<C-c>` | laufenden Vorgang abbrechen |
| `q` | Fenster schließen |

Das Fenster scrollt mit, solange der Cursor am Ende steht. Scrollst du hoch, um
etwas zu lesen, bleibt die Ansicht stehen. Die Quickfix-Liste wird zusätzlich
immer gefüllt, `:cnext` und `:cprev` funktionieren also weiterhin.

Die Testlauf-Ausgabe von `compiledb` (`make -n`) wird nur bei einem Fehler
gezeigt, sonst erscheint eine Zusammenfassung wie `compile_commands.json: 12 Dateien`.

## Konfiguration (Standardwerte)

```lua
require("qmake-tools").setup({
  kits = {},                       -- siehe Abschnitt Kits
  default_kit = nil,               -- nil = erstes lokales Kit
  detect_kits = true,              -- installierte Qt-Versionen automatisch anbieten
  make_executable = nil,           -- nil = passend zur Toolchain (make, mingw32-make, jom, nmake)
  default_config = "default",      -- Name der ersten Konfiguration
  build_dir = "build/${config}/${kit}-${build_type_lower}",
  build_types = { "Debug", "Release" },
  default_build_type = "Debug",
  qmake_args = {},                 -- z. B. { "-spec", "linux-clang" }
  build_type_args = {
    Debug = { "CONFIG+=debug", "CONFIG+=qml_debug" },
    Release = { "CONFIG+=release" },
  },
  jobs = nil,                      -- nil = Anzahl CPU-Kerne
  compile_commands = "auto",       -- "auto" | "compiledb" | "builtin" | "bear" | false
  link_compile_commands = true,
  restart_clangd = true,
  regenerate_on_save = true,
  build_before_run = true,
  add_library_search_paths = true, -- Build-Libs + Qt-Libs in LD_LIBRARY_PATH bzw. PATH (wie Qt Creator)
  executor = {
    enabled = true,
    open = "always",               -- "always" | "on_error" | "never"
    position = "bottom",           -- "bottom" | "top" | "right" | "left"
    size = 15,                     -- Höhe bzw. Breite
    focus = false,                 -- beim Öffnen hineinspringen
    wrap = false,
    close_on_success = false,      -- nach Erfolg automatisch schließen
    close_on_success_delay = 1500, -- ms
  },
  open_quickfix = "never",         -- "always" | "on_error" | "never"
  errorformat = nil,               -- nil = eingebaut (gcc/clang, MSVC, qmake, make -w)
  terminal_height = 15,
})
```

Weitere Build-Typen sind einfach hinzuzufügen:

```lua
opts = {
  build_types = { "Debug", "Release", "Profile" },
  build_type_args = { Profile = { "CONFIG+=release", "CONFIG+=force_debug_info" } },
}
```

## Tastenbelegung (Beispiel)

```lua
vim.keymap.set("n", "<leader>qg", "<cmd>QMakeGenerate<cr>", { desc = "qmake generate" })
vim.keymap.set("n", "<leader>qb", "<cmd>QMakeBuild<cr>",    { desc = "qmake build" })
vim.keymap.set("n", "<leader>qr", "<cmd>QMakeRun<cr>",      { desc = "qmake run" })
vim.keymap.set("n", "<leader>qt", "<cmd>QMakeSelectBuildType<cr>", { desc = "qmake build type" })
```

## Statuszeile (lualine)

```lua
lualine_x = {
  { function() return require("qmake-tools").statusline() end,
    cond = function() return require("qmake-tools").is_qmake_project() end },
}
```

## clangd einrichten

```lua
-- Neovim 0.11+
vim.lsp.enable("clangd")
```

clangd findet die verlinkte `compile_commands.json` im Projekt-Root. Ohne
`.git`-Verzeichnis im Projekt sollte die Datei vor dem ersten Öffnen einer
Quelldatei einmal mit `:QMakeGenerate` erzeugt werden, damit clangd das Root erkennt.
`compile_commands.json` gehört in die `.gitignore`.

## Hinweise

- qmake läuft mit `-r`, damit bei `subdirs`-Projekten alle Unter-Makefiles sofort
  existieren und `compiledb` ohne vorherigen Build alle Quelldateien findet.
- Von moc erzeugte Dateien (`moc_*.cpp`) erscheinen erst nach dem ersten Build in der
  Datenbank. Das betrifft nur diese generierten Dateien, nicht deine Quellen.
- Mit `compile_commands = "bear"` wird die Datenbank beim echten Build aufgezeichnet
  statt bei `:QMakeGenerate`.
- `compile_commands = "auto"` nimmt `compiledb`, wenn es installiert ist und das Kit
  GNU make nutzt, sonst den eingebauten Generator (`"builtin"`). Der liest CC/CXX,
  Flags, DEFINES, INCPATH und SOURCES aus den von qmake erzeugten Makefiles.
- Das Ende jedes Vorgangs löst `User QMakeToolsDone` aus (`data = { title, ok }`),
  z. B. für eigene Benachrichtigungen.
