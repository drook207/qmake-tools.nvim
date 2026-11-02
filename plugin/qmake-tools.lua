if vim.g.loaded_qmake_tools then
  return
end
vim.g.loaded_qmake_tools = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("qmake-tools.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

local function qt()
  return require("qmake-tools")
end

local cmd = vim.api.nvim_create_user_command

cmd("QMakeGenerate", function() qt().generate() end, { desc = "Run qmake and generate compile_commands.json" })
cmd("QMakeBuild", function(o) qt().build(o.args) end, { nargs = "?", desc = "Build the project (optional make target)" })
cmd("QMakeRun", function() qt().run() end, { desc = "Build and run the program" })
cmd("QMakeClean", function() qt().clean() end, { desc = "make clean" })
cmd("QMakeRebuild", function() qt().rebuild() end, { desc = "make clean + build" })
cmd("QMakeStop", function() qt().stop() end, { desc = "Cancel the running operation" })
cmd("QMakeOpenExecutor", function(o) require("qmake-tools.executor").open(not o.bang) end,
  { bang = true, desc = "Open the output window and jump into it (! = keep focus)" })
cmd("QMakeCloseExecutor", function() require("qmake-tools.executor").close() end, { desc = "Close the output window" })
cmd("QMakeToggleExecutor", function() require("qmake-tools.executor").toggle() end, { desc = "Toggle the output window" })
cmd("QMakeInfo", function() qt().info() end, { desc = "Show project info" })
cmd("QMakeSelectProject", function() qt().select_project() end, { desc = "Select the .pro file" })
cmd("QMakeSelectTarget", function() qt().select_target() end, { desc = "Select the run target" })
-- Suggestions for :QMakeArgs completion
local qmake_arg_hints = {
  "CONFIG+=", "CONFIG-=", "DEFINES+=", "INCLUDEPATH+=", "LIBS+=",
  "QMAKE_CXXFLAGS+=", "QMAKE_CFLAGS+=", "QMAKE_LFLAGS+=", "QMAKE_CXX=", "QMAKE_CC=", "QMAKE_LINK=",
  "CONFIG+=c++17", "CONFIG+=c++20", "CONFIG+=sanitizer", "CONFIG+=sanitize_address",
  "CONFIG+=sanitize_undefined", "CONFIG+=force_debug_info", "CONFIG+=separate_debug_info",
  "CONFIG+=ccache", "CONFIG+=warn_on", "CONFIG+=qml_debug", "-spec", "-after",
}

local function complete_qmake_args(arglead, cmdline)
  -- After -spec, offer the mkspecs of the active kit
  if cmdline:match("%-spec%s+%S*$") then
    return vim.tbl_filter(function(s)
      return s:sub(1, #arglead) == arglead
    end, qt().mkspecs())
  end
  return vim.tbl_filter(function(h)
    return h:sub(1, #arglead) == arglead
  end, qmake_arg_hints)
end

--- Completion for names with spaces (e.g. "Qt 5.15.2 gcc_64"):
--- compares against the whole argument but returns only the rest from arglead
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
cmd("QMakeKits", function(o) qt().list_kits(o.bang) end, { bang = true, desc = "Show kits (! = rescan)" })
cmd("QMakeSelectKit", function(o) qt().select_kit(o.args) end,
  { nargs = "?", complete = complete_kits, desc = "Select the kit for the active configuration" })
cmd("QMakeKitAdd", function(o)
  local a, open = qt().split_args(o.args)
  if open then
    return vim.notify("qmake-tools: unterminated quote", vim.log.levels.ERROR)
  end
  qt().kit_add(a[1], a[2], a[3])
end, { nargs = "*", complete = "file", desc = 'Register a kit: "Name" /path/to/qmake [spec]' })
cmd("QMakeKitRemove", function(o) qt().kit_remove(o.args) end,
  { nargs = "?", complete = complete_kits, desc = "Remove a registered kit" })

-- Configurations
cmd("QMakeSelectConfig", function(o) qt().select_config(o.args) end,
  { nargs = "?", complete = complete_configs, desc = "Select a configuration" })
cmd("QMakeConfigNew", function(o) qt().config_new(o.args) end, { nargs = "?", desc = "New configuration (copy of the active one)" })
cmd("QMakeConfigRename", function(o) qt().config_rename(o.args) end, { nargs = "?", desc = "Rename the active configuration" })
cmd("QMakeConfigDelete", function(o) qt().config_delete(o.args) end,
  { nargs = "?", complete = complete_configs, desc = "Delete a configuration" })

cmd("QMakeArgs", function(o)
  qt().set_qmake_args(o.args, { clear = o.bang })
end, {
  nargs = "*",
  bang = true,
  complete = complete_qmake_args,
  desc = "Set additional qmake arguments (without arguments: edit, ! = clear)",
})
cmd("QMakeArgsAdd", function(o)
  qt().set_qmake_args(o.args, { add = true })
end, { nargs = "+", complete = complete_qmake_args, desc = "Append qmake arguments" })
cmd("QMakeRunArgs", function(o)
  qt().set_run_args(o.args, { clear = o.bang })
end, { nargs = "*", bang = true, desc = "Set run arguments (without arguments: edit, ! = clear)" })
cmd("QMakeSelectBuildType", function(o) qt().select_build_type(o.args) end, {
  nargs = "?",
  desc = "Select the build type",
  complete = function()
    return require("qmake-tools.config").options.build_types
  end,
})

-- Default behavior even without calling setup()
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    if not vim.g.qmake_tools_setup_called then
      qt().setup({})
    end
  end,
})
