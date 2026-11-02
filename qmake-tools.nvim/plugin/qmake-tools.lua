if vim.g.loaded_qmake_tools then
  return
end
vim.g.loaded_qmake_tools = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("qmake-tools.nvim benötigt Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

local function qt()
  return require("qmake-tools")
end

local cmd = vim.api.nvim_create_user_command

cmd("QMakeGenerate", function() qt().generate() end, { desc = "qmake ausführen und compile_commands.json erzeugen" })
cmd("QMakeBuild", function(o) qt().build(o.args) end, { nargs = "?", desc = "Projekt bauen (optional make-Target)" })
cmd("QMakeRun", function() qt().run() end, { desc = "Programm bauen und starten" })
cmd("QMakeClean", function() qt().clean() end, { desc = "make clean" })
cmd("QMakeRebuild", function() qt().rebuild() end, { desc = "make clean + Build" })
cmd("QMakeStop", function() qt().stop() end, { desc = "Laufenden Vorgang abbrechen" })
cmd("QMakeOpenExecutor", function(o) require("qmake-tools.executor").open(not o.bang) end,
  { bang = true, desc = "Ausgabefenster öffnen und hineinspringen (! = Fokus behalten)" })
cmd("QMakeCloseExecutor", function() require("qmake-tools.executor").close() end, { desc = "Ausgabefenster schließen" })
cmd("QMakeToggleExecutor", function() require("qmake-tools.executor").toggle() end, { desc = "Ausgabefenster ein/aus" })
cmd("QMakeInfo", function() qt().info() end, { desc = "Projektinfo anzeigen" })
cmd("QMakeSelectProject", function() qt().select_project() end, { desc = ".pro-Datei wählen" })
cmd("QMakeSelectTarget", function() qt().select_target() end, { desc = "Startziel wählen" })
-- Vorschläge für die Vervollständigung von :QMakeArgs
local qmake_arg_hints = {
  "CONFIG+=", "CONFIG-=", "DEFINES+=", "INCLUDEPATH+=", "LIBS+=",
  "QMAKE_CXXFLAGS+=", "QMAKE_CFLAGS+=", "QMAKE_LFLAGS+=", "QMAKE_CXX=", "QMAKE_CC=", "QMAKE_LINK=",
  "CONFIG+=c++17", "CONFIG+=c++20", "CONFIG+=sanitizer", "CONFIG+=sanitize_address",
  "CONFIG+=sanitize_undefined", "CONFIG+=force_debug_info", "CONFIG+=separate_debug_info",
  "CONFIG+=ccache", "CONFIG+=warn_on", "CONFIG+=qml_debug", "-spec", "-after",
}

local function complete_qmake_args(arglead, cmdline)
  -- Nach -spec die mkspecs des aktiven Kits anbieten
  if cmdline:match("%-spec%s+%S*$") then
    return vim.tbl_filter(function(s)
      return s:sub(1, #arglead) == arglead
    end, qt().mkspecs())
  end
  return vim.tbl_filter(function(h)
    return h:sub(1, #arglead) == arglead
  end, qmake_arg_hints)
end

--- Vervollständigung für Namen mit Leerzeichen (z. B. "Qt 5.15.2 gcc_64"):
--- vergleicht mit dem ganzen Argument, liefert aber nur den Rest ab arglead
local function complete_names(get)
  return function(arglead, cmdline)
    local typed = cmdline:match("^%S+%s+(.*)$") or ""
    local res = {}
    for _, name in ipairs(get()) do
      if name:sub(1, #typed) == typed then
        table.insert(res, name:sub(#typed - #arglead + 1))
      end
    end
    return res
  end
end

local complete_kits = complete_names(function()
  return qt().kit_names()
end)
local complete_configs = complete_names(function()
  return qt().config_names()
end)

-- Kits
cmd("QMakeKits", function(o) qt().list_kits(o.bang) end, { bang = true, desc = "Kits anzeigen (! = neu suchen)" })
cmd("QMakeSelectKit", function(o) qt().select_kit(o.args) end,
  { nargs = "?", complete = complete_kits, desc = "Kit der aktiven Konfiguration wählen" })
cmd("QMakeKitAdd", function(o)
  local a, open = qt().split_args(o.args)
  if open then
    return vim.notify("qmake-tools: Anführungszeichen nicht geschlossen", vim.log.levels.ERROR)
  end
  qt().kit_add(a[1], a[2], a[3])
end, { nargs = "*", complete = "file", desc = 'Kit registrieren: "Name" /pfad/zu/qmake [spec]' })
cmd("QMakeKitRemove", function(o) qt().kit_remove(o.args) end,
  { nargs = "?", complete = complete_kits, desc = "Registriertes Kit entfernen" })

-- Konfigurationen
cmd("QMakeSelectConfig", function(o) qt().select_config(o.args) end,
  { nargs = "?", complete = complete_configs, desc = "Konfiguration wählen" })
cmd("QMakeConfigNew", function(o) qt().config_new(o.args) end, { nargs = "?", desc = "Neue Konfiguration (Kopie der aktiven)" })
cmd("QMakeConfigRename", function(o) qt().config_rename(o.args) end, { nargs = "?", desc = "Aktive Konfiguration umbenennen" })
cmd("QMakeConfigDelete", function(o) qt().config_delete(o.args) end,
  { nargs = "?", complete = complete_configs, desc = "Konfiguration löschen" })

cmd("QMakeArgs", function(o)
  qt().set_qmake_args(o.args, { clear = o.bang })
end, {
  nargs = "*",
  bang = true,
  complete = complete_qmake_args,
  desc = "Zusätzliche qmake-Argumente setzen (ohne Argumente: bearbeiten, ! = löschen)",
})
cmd("QMakeArgsAdd", function(o)
  qt().set_qmake_args(o.args, { add = true })
end, { nargs = "+", complete = complete_qmake_args, desc = "qmake-Argumente anhängen" })
cmd("QMakeRunArgs", function(o)
  qt().set_run_args(o.args, { clear = o.bang })
end, { nargs = "*", bang = true, desc = "Startargumente setzen (ohne Argumente: bearbeiten, ! = löschen)" })
cmd("QMakeSelectBuildType", function(o) qt().select_build_type(o.args) end, {
  nargs = "?",
  desc = "Build-Typ wählen",
  complete = function()
    return require("qmake-tools.config").options.build_types
  end,
})

-- Standardverhalten auch ohne setup()-Aufruf
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    if not vim.g.qmake_tools_setup_called then
      qt().setup({})
    end
  end,
})
