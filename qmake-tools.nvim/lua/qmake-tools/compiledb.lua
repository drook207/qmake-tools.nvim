-- Eingebauter Generator für compile_commands.json: liest die von qmake erzeugten
-- Makefiles (CC/CXX, CFLAGS/CXXFLAGS, DEFINES, INCPATH, SOURCES) direkt aus.
-- Braucht kein compiledb und funktioniert auch mit nmake/jom (MSVC), weil kein
-- `make -n` ausgewertet werden muss.
local kits = require("qmake-tools.kits")
local project = require("qmake-tools.project")

local M = {}

local c_ext = { c = true }
local cxx_ext = { cpp = true, cc = true, cxx = true, ["c++"] = true, mm = true, m = true }

--- Einträge für ein Makefile
local function entries_for(m, kit, compilers)
  local vars = m.vars
  local res = {}
  local sources = project.split_words(project.expand(vars, vars.SOURCES or ""))
  if #sources == 0 then
    return res
  end
  local function flags(compiler_var, flags_var)
    local name = project.expand(vars, vars[compiler_var] or "")
    local words = project.split_words(name)
    if #words == 0 then
      return nil
    end
    -- Compiler mit absolutem Pfad, damit clangd per --query-driver die
    -- System-Header findet (bei MSVC: cl.exe aus der vcvarsall-Umgebung)
    local exe = words[1]
    if not compilers[exe] then
      compilers[exe] = kits.which(kit, exe) or exe
    end
    words[1] = compilers[exe]
    vim.list_extend(words, project.split_words(project.expand(vars, vars[flags_var] or "")))
    -- DEFINES steckt meist schon in CFLAGS/CXXFLAGS; INCPATH nie
    local f = vars[flags_var] or ""
    if not f:find("$(DEFINES)", 1, true) then
      vim.list_extend(words, project.split_words(project.expand(vars, vars.DEFINES or "")))
    end
    vim.list_extend(words, project.split_words(project.expand(vars, vars.INCPATH or "")))
    return words
  end
  local c_args = flags("CC", "CFLAGS")
  local cxx_args = flags("CXX", "CXXFLAGS")
  for _, src in ipairs(sources) do
    local ext = (src:match("%.([^./\\]+)$") or ""):lower()
    local base = c_ext[ext] and c_args or (cxx_ext[ext] and cxx_args)
    if base then
      local file = project.resolve_path(m.dir, src)
      local args = vim.deepcopy(base)
      vim.list_extend(args, { "-c", file })
      table.insert(res, { directory = m.dir, file = file, arguments = args })
    end
  end
  return res
end

--- compile_commands.json im Build-Verzeichnis schreiben
---@return boolean ok, string[] lines
function M.generate(p, kit, out)
  local seen, all, compilers = {}, {}, {}
  for _, m in ipairs(project.makefiles(p)) do
    for _, e in ipairs(entries_for(m, kit, compilers)) do
      if not seen[e.file] then
        seen[e.file] = true
        table.insert(all, e)
      end
    end
  end
  local f, err = io.open(out, "w")
  if not f then
    return false, { "compile_commands.json nicht geschrieben: " .. tostring(err) }
  end
  f:write(vim.json.encode(all))
  f:close()
  local n = #all
  if n == 0 then
    return true, { "WARNING: compile_commands.json ist leer – keine Quelldateien in den Makefiles gefunden" }
  end
  return true, { ("compile_commands.json: %d %s (eingebaut)"):format(n, n == 1 and "Datei" or "Dateien") }
end

return M
