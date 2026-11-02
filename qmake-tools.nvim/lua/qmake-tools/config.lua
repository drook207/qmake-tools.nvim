---@class QMakeToolsConfig
local defaults = {
  -- Kits (Qt-Versionen / Toolchains). Siehe README, z. B.:
  --   kits = {
  --     { name = "Qt 5.12 Desktop", qmake = "~/Qt/5.12.12/gcc_64/bin/qmake" },
  --     { name = "RPi", qmake = "/opt/qt5pi/bin/qmake", spec = "devices/linux-rasp-pi4-v3d-g++",
  --       path = { "/opt/cross/bin" }, run = false },
  --   }
  kits = {},
  -- Name des Kits für neue Konfigurationen (nil = erstes Kit)
  default_kit = nil,
  -- Installierte Qt-Versionen automatisch als Kits anbieten
  detect_kits = true,
  -- Veraltet, wird zum Kit "Standard": fester Pfad zu qmake
  qmake_executable = nil,
  -- make-Programm für alle Kits (nil = passend zur Toolchain: make, unter Windows
  -- mingw32-make bzw. jom/nmake für MSVC)
  make_executable = nil,
  -- Name der ersten Konfiguration eines Projekts
  default_config = "default",
  -- Build-Verzeichnis relativ zum Projekt-Root (oder absolut).
  -- Platzhalter: ${config}, ${kit}, ${build_type}, ${build_type_lower}
  build_dir = "build/${config}/${kit}-${build_type_lower}",
  build_types = { "Debug", "Release" },
  default_build_type = "Debug",
  -- Zusätzliche qmake-Argumente pro Build-Typ und für alle
  qmake_args = {},
  build_type_args = {
    Debug = { "CONFIG+=debug", "CONFIG+=qml_debug" },
    Release = { "CONFIG+=release" },
  },
  -- Parallele Jobs für make (nil = Anzahl CPU-Kerne)
  jobs = nil,
  -- "auto" | "compiledb" | "builtin" | "bear" | false
  --   compiledb: wertet `make -n` aus, sehr schnell, kein Build nötig (nur GNU make)
  --   builtin:   liest die von qmake erzeugten Makefiles direkt, ohne Zusatzprogramm;
  --              funktioniert auch mit nmake/jom (MSVC)
  --   bear:      zeichnet beim echten Build auf (genauer, aber erst nach dem Build)
  --   auto:      compiledb, falls installiert und GNU make, sonst builtin
  compile_commands = "auto",
  -- compile_commands.json ins Projekt-Root verlinken (für clangd)
  link_compile_commands = true,
  -- Nach Generate automatisch clangd neu starten
  restart_clangd = true,
  -- Beim Speichern von .pro/.pri automatisch neu generieren
  regenerate_on_save = true,
  -- Vor :QMakeRun automatisch bauen
  build_before_run = true,
  -- Wie Qt Creator ("Add build library search path to LD_LIBRARY_PATH"):
  -- -L-Verzeichnisse aus LIBS, im Projekt gebaute Shared Libraries und das
  -- Qt-Lib-Verzeichnis beim Start vorne an LD_LIBRARY_PATH anfügen
  -- (unter Windows an PATH, dort sucht Windows die DLLs)
  add_library_search_paths = true,
  -- Executor-Fenster mit der Live-Ausgabe von qmake/compiledb/make
  executor = {
    enabled = true,
    open = "always",          -- "always" | "on_error" | "never" (dann nur per :QMakeOpenExecutor)
    position = "bottom",      -- "bottom" | "top" | "right" | "left"
    size = 15,                -- Höhe bzw. Breite bei right/left
    focus = false,            -- beim Öffnen hineinspringen
    wrap = false,
    close_on_success = false, -- nach erfolgreichem Lauf automatisch schließen
    close_on_success_delay = 1500,
  },
  -- Quickfix-Fenster: "always" | "on_error" | "never"
  -- Die Quickfix-Liste wird immer gefüllt (:cnext/:cprev funktionieren),
  -- nur das Fenster bleibt zu, weil der Executor die Ausgabe schon zeigt.
  open_quickfix = "never",
  -- errorformat für die Quickfix-Liste (nil = eingebaut: gcc/clang, MSVC, qmake,
  -- Verzeichniswechsel von make/mingw32-make)
  errorformat = nil,
  -- Höhe des Terminal-Splits für :QMakeRun
  terminal_height = 15,
}

local M = { options = vim.deepcopy(defaults) }

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

return M
