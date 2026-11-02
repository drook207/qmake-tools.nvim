local config = require("qmake-tools.config")
local kits = require("qmake-tools.kits")

local uv = vim.uv or vim.loop
local M = {}

-- Zustand pro Projekt (Schlüssel: Projekt-Root):
--   { pro = "...", active = "Name", configs = { { name, kit, build_type, qmake_args, run_args, run_target }, ... } }
local state = {}
local state_file = vim.fn.stdpath("data") .. "/qmake-tools.json"
local loaded = false

local function load_state()
  if loaded then
    return
  end
  loaded = true
  local f = io.open(state_file, "r")
  if not f then
    return
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if ok and type(data) == "table" then
    state = data
  end
end

local config_fields = { "name", "kit", "build_type", "qmake_args", "run_args", "run_target" }

local function save_state()
  vim.fn.mkdir(vim.fs.dirname(state_file), "p")
  local out = {}
  for root, s in pairs(state) do
    local configs = {}
    for _, c in ipairs(s.configs or {}) do
      local cc = {}
      for _, k in ipairs(config_fields) do
        cc[k] = c[k]
      end
      table.insert(configs, cc)
    end
    out[root] = { pro = s.pro, active = s.active, configs = configs }
  end
  local f, e = io.open(state_file, "w")
  if not f then
    vim.notify("qmake-tools: Einstellungen nicht gespeichert: " .. tostring(e), vim.log.levels.WARN)
    return
  end
  f:write(vim.json.encode(out))
  f:close()
end

local function join(...)
  return table.concat({ ... }, "/")
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

M.join = join
M.exists = exists

--- Alle .pro-Dateien in einem Verzeichnis
local function pro_files_in(dir)
  local res = {}
  for name, t in vim.fs.dir(dir) do
    if (t == "file" or t == "link") and name:match("%.pro$") then
      table.insert(res, join(dir, name))
    end
  end
  table.sort(res)
  return res
end

--- Projekt-Root suchen: erstes Verzeichnis ab cwd aufwärts, das eine .pro enthält.
--- Bei verschachtelten subdirs-Projekten wird das oberste genommen, solange die
--- Elternverzeichnisse ebenfalls .pro-Dateien enthalten.
function M.find_root(start)
  start = vim.fs.normalize(start or uv.cwd())
  local found
  for dir in vim.fs.parents(start .. "/x") do
    if #pro_files_in(dir) > 0 then
      found = dir
    elseif found then
      break
    end
  end
  return found
end

local function new_config(name, base)
  local kit = base and base.kit or (kits.default() or {}).name
  return {
    name = name,
    kit = kit,
    build_type = base and base.build_type or config.options.default_build_type,
    qmake_args = base and vim.deepcopy(base.qmake_args or {}) or {},
    run_args = base and vim.deepcopy(base.run_args or {}) or {},
  }
end

--- Alte Zustände (vor den Konfigurationen) übernehmen
local function migrate(s)
  if s.configs then
    return
  end
  local c = new_config(config.options.default_config)
  c.build_type = s.build_type or c.build_type
  c.qmake_args = s.qmake_args or {}
  c.run_args = s.run_args or {}
  c.run_target = s.run_target
  s.configs = { c }
  s.active = c.name
  s.build_type, s.qmake_args, s.run_args, s.run_target = nil, nil, nil, nil
end

---@class QMakeProject
---@field root string
---@field pro string|nil
---@field active string
---@field configs table[]

---@return QMakeProject|nil
function M.get(silent)
  load_state()
  local root = M.find_root()
  if not root then
    if not silent then
      vim.notify("qmake-tools: keine .pro-Datei gefunden", vim.log.levels.WARN)
    end
    return nil
  end
  local s = state[root]
  if not s then
    s = {}
    state[root] = s
  end
  migrate(s)
  if #s.configs == 0 then
    table.insert(s.configs, new_config(config.options.default_config))
  end
  s.root = root
  if s.pro and not exists(s.pro) then
    s.pro = nil
  end
  if not s.pro then
    local pros = pro_files_in(root)
    -- Bevorzugt die .pro, die wie das Verzeichnis heißt
    local base = vim.fs.basename(root)
    for _, p in ipairs(pros) do
      if vim.fs.basename(p) == base .. ".pro" then
        s.pro = p
      end
    end
    s.pro = s.pro or (#pros == 1 and pros[1] or nil)
  end
  return s
end

function M.save()
  save_state()
end

function M.pro_candidates(project)
  return pro_files_in(project.root)
end

-- ---------------------------------------------------------------------------
-- Konfigurationen
-- ---------------------------------------------------------------------------

function M.find_config(p, name)
  for i, c in ipairs(p.configs) do
    if c.name == name then
      return c, i
    end
  end
end

--- Aktive Konfiguration
function M.config(p)
  local c = M.find_config(p, p.active)
  if not c then
    c = p.configs[1]
    p.active = c.name
  end
  return c
end

--- Kit der Konfiguration (nil, falls nicht vorhanden)
function M.kit(c)
  return kits.get(c.kit)
end

function M.add_config(p, name, base)
  if M.find_config(p, name) then
    return nil, "Konfiguration existiert bereits: " .. name
  end
  local c = new_config(name, base)
  table.insert(p.configs, c)
  p.active = name
  save_state()
  return c
end

function M.remove_config(p, name)
  if #p.configs <= 1 then
    return false, "die letzte Konfiguration kann nicht gelöscht werden"
  end
  local _, i = M.find_config(p, name)
  if not i then
    return false, "unbekannte Konfiguration: " .. name
  end
  table.remove(p.configs, i)
  if p.active == name then
    p.active = p.configs[1].name
  end
  save_state()
  return true
end

function M.rename_config(p, old, new)
  if M.find_config(p, new) then
    return false, "Konfiguration existiert bereits: " .. new
  end
  local c = M.find_config(p, old)
  if not c then
    return false, "unbekannte Konfiguration: " .. old
  end
  c.name = new
  if p.active == old then
    p.active = new
  end
  save_state()
  return true
end

--- Build-Verzeichnis der (aktiven) Konfiguration
function M.build_dir(p, c)
  c = c or M.config(p)
  local vars = {
    config = kits.slug(c.name),
    kit = kits.slug(c.kit or "kein-kit"),
    build_type = c.build_type,
    build_type_lower = c.build_type:lower(),
  }
  local rel = config.options.build_dir:gsub("%${([%w_]+)}", function(k)
    return vars[k] or ""
  end)
  if kits.is_absolute(rel) then
    return vim.fs.normalize(rel)
  end
  return vim.fs.normalize(join(p.root, rel))
end

function M.jobs()
  if config.options.jobs then
    return config.options.jobs
  end
  local ok, n = pcall(function()
    return uv.available_parallelism()
  end)
  return ok and n or 4
end

-- ---------------------------------------------------------------------------
-- Makefiles
-- ---------------------------------------------------------------------------

--- Liest Variablen aus einem von qmake erzeugten Makefile (mit Fortsetzungszeilen)
local function parse_makefile(path)
  local vars = {}
  local f = io.open(path, "r")
  if not f then
    return vars
  end
  local key, value
  for line in f:lines() do
    line = line:gsub("\r$", "")
    if key then
      value = value .. " " .. vim.trim(line)
    else
      local k, v = line:match("^([A-Z_][A-Z0-9_]*)%s*=%s*(.-)%s*$")
      if k then
        key, value = k, v
      end
    end
    if key then
      -- Fortsetzung am Ende der Rohzeile erkennen, erst danach Kommentare entfernen:
      -- qmake schreibt unter Windows `DESTDIR = debug\ #avoid trailing-slash linebreak`
      local continued = value:sub(-1) == "\\"
      if continued then
        value = value:sub(1, -2)
      end
      value = value:gsub("%s+#.*$", "")
      if not continued then
        if vars[key] == nil then
          vars[key] = vim.trim(value)
        end
        key = nil
      end
    end
  end
  f:close()
  return vars
end

--- $(VAR) in einem Makefile-Wert auflösen
function M.expand(vars, value, depth)
  depth = depth or 0
  if depth > 10 then
    return value
  end
  return (value:gsub("%$%(([%w_]+)%)", function(name)
    return M.expand(vars, vars[name] or vim.env[name] or "", depth + 1)
  end))
end

--- Zerlegt einen Makefile-Wert in Wörter; "..." fasst zusammen. Backslashes
--- bleiben erhalten (Windows-Pfade).
function M.split_words(str)
  local words = {}
  local cur, in_quote, has = {}, false, false
  for ch in str:gmatch(".") do
    if ch == '"' then
      in_quote, has = not in_quote, true
    elseif ch:match("%s") and not in_quote then
      if has or #cur > 0 then
        table.insert(words, table.concat(cur))
        cur, has = {}, false
      end
    else
      table.insert(cur, ch)
    end
  end
  if has or #cur > 0 then
    table.insert(words, table.concat(cur))
  end
  return words
end

--- Pfad aus einem Makefile relativ zu dir auflösen
function M.resolve_path(dir, path)
  path = path:gsub('^"(.*)"$', "%1")
  return vim.fs.normalize(kits.is_absolute(path) and path or join(dir, path))
end

--- Alle Makefiles im Build-Verzeichnis mit ihren Variablen.
--- Unter Windows erzeugt qmake (debug_and_release) neben dem Makefile noch
--- Makefile.Debug und Makefile.Release – davon zählt das zum Build-Typ passende.
---@return { dir: string, file: string, vars: table }[]
function M.makefiles(p, c)
  c = c or M.config(p)
  local variant = c.build_type:lower() == "debug" and "Makefile.Debug" or "Makefile.Release"
  local by_dir = {}
  local found = vim.fs.find(function(name)
    return name == "Makefile" or name == "Makefile.Debug" or name == "Makefile.Release"
  end, { path = M.build_dir(p, c), type = "file", limit = math.huge })
  for _, mk in ipairs(found) do
    mk = vim.fs.normalize(mk)
    local dir, name = vim.fs.dirname(mk), vim.fs.basename(mk)
    local cur = by_dir[dir]
    if name == variant or (name == "Makefile" and not cur) then
      by_dir[dir] = mk
    end
  end
  local res = {}
  for dir, mk in pairs(by_dir) do
    table.insert(res, { dir = dir, file = mk, vars = parse_makefile(mk) })
  end
  table.sort(res, function(a, b)
    return a.file < b.file
  end)
  return res
end

-- ---------------------------------------------------------------------------
-- Startziele
-- ---------------------------------------------------------------------------

local function is_program(path)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" then
    return false
  end
  if kits.is_win then
    return path:lower():match("%.exe$") ~= nil
  end
  -- Bei Cross-Builds ist die Datei evtl. nicht für diesen Rechner ausführbar,
  -- das x-Bit ist aber gesetzt
  return bit.band(st.mode, tonumber("111", 8)) ~= 0
end

--- Shared Library (deren Verzeichnis zur Laufzeit gesucht werden muss)?
local function is_shared_library(target)
  local t = target:lower()
  return t:match("^lib.*%.so") ~= nil or t:match("%.dll$") ~= nil or t:match("%.dylib$") ~= nil
end

local function is_library(target)
  local t = target:lower()
  return is_shared_library(t) or t:match("%.a$") ~= nil or t:match("%.lib$") ~= nil
end

--- Ausgabeverzeichnis eines Makefiles (DESTDIR oder das Makefile-Verzeichnis)
local function out_dir(m)
  local destdir = m.vars.DESTDIR or ""
  if destdir == "" then
    return m.dir
  end
  return M.resolve_path(m.dir, destdir)
end

--- Ausführbare Ziele im Build-Verzeichnis (rekursiv über alle Makefiles,
--- funktioniert damit auch für TEMPLATE = subdirs)
---@return string[] targets, table<string, table> makefile_of
function M.find_targets(p)
  local targets = {}
  local seen = {}
  for _, m in ipairs(M.makefiles(p)) do
    local target = m.vars.TARGET
    if target and target ~= "" and not target:find("$(", 1, true) and not is_library(target) then
      local names = { target }
      if kits.is_win and not target:lower():match("%.exe$") then
        table.insert(names, 1, target .. ".exe")
      end
      local found = false
      for _, name in ipairs(names) do
        for _, dir in ipairs({ out_dir(m), m.dir }) do
          local cand = vim.fs.normalize(join(dir, name))
          if not found and not seen[cand] and is_program(cand) then
            seen[cand] = m
            table.insert(targets, cand)
            found = true
          end
        end
      end
    end
  end
  table.sort(targets)
  return targets, seen
end

--- Bibliotheks-Suchpfade für ein Startziel, wie Qt Creator
--- ("Add build library search path to LD_LIBRARY_PATH"):
---   * alle -L- bzw. /LIBPATH:-Verzeichnisse aus LIBS des Ziels (relative bezogen
---     aufs Build-Verzeichnis)
---   * das Lib-Verzeichnis der Qt-Version (QT_INSTALL_LIBS, unter Windows
---     QT_INSTALL_BINS, weil dort die DLLs liegen)
--- Zusätzlich die Ausgabeverzeichnisse aller im Projekt gebauten Shared Libraries,
--- damit auch `LIBS += $$OUT_PWD/../lib/libfoo.so` ohne -L funktioniert.
---@return string[]
function M.library_paths(p, exe, kit)
  local paths, seen = {}, {}
  local function add(dir)
    dir = vim.fs.normalize(dir)
    if not seen[dir] then
      seen[dir] = true
      table.insert(paths, dir)
    end
  end
  local _, makefile_of = M.find_targets(p)
  local m = makefile_of[exe]
  if m then
    for _, word in ipairs(M.split_words(m.vars.LIBS or "")) do
      local dir = word:match("^%-L(.+)$") or word:match("^[/%-][Ll][Ii][Bb][Pp][Aa][Tt][Hh]:(.+)$")
      if dir and not dir:find("$(", 1, true) then
        add(M.resolve_path(m.dir, dir))
      end
    end
  end
  for _, lm in ipairs(M.makefiles(p)) do
    local target = lm.vars.TARGET
    if target and is_shared_library(target) then
      add(out_dir(lm))
    end
  end
  local qt_libs = kit and kits.query(kit, kits.is_win and "QT_INSTALL_BINS" or "QT_INSTALL_LIBS")
  if qt_libs and qt_libs ~= "" then
    add(qt_libs)
  end
  return paths
end

return M
