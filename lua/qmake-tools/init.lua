local config = require("qmake-tools.config")
local project = require("qmake-tools.project")
local kits = require("qmake-tools.kits")
local runner = require("qmake-tools.runner")
local compiledb = require("qmake-tools.compiledb")

local uv = vim.uv or vim.loop
local M = {}

local function err(msg)
  vim.notify("qmake-tools: " .. msg, vim.log.levels.ERROR)
end

local function info(msg)
  vim.notify("qmake-tools: " .. msg)
end

-- ---------------------------------------------------------------------------
-- Split / join arguments
-- ---------------------------------------------------------------------------

--- Splits a line like the shell: spaces separate, "..." and '...'
--- group, \ escapes the next character.
function M.split_args(str)
  local args, cur, quote, has = {}, {}, nil, false
  local i, n = 1, #str
  while i <= n do
    local c = str:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      elseif c == "\\" and quote == '"' and i < n then
        i = i + 1
        table.insert(cur, str:sub(i, i))
      else
        table.insert(cur, c)
      end
    elseif c == '"' or c == "'" then
      quote, has = c, true
    elseif c == "\\" and i < n then
      i = i + 1
      table.insert(cur, str:sub(i, i))
      has = true
    elseif c:match("%s") then
      if has or #cur > 0 then
        table.insert(args, table.concat(cur))
        cur, has = {}, false
      end
    else
      table.insert(cur, c)
    end
    i = i + 1
  end
  if has or #cur > 0 then
    table.insert(args, table.concat(cur))
  end
  return args, quote ~= nil
end

--- Counterpart to split_args, for display and the input field
function M.join_args(args)
  local out = {}
  for _, a in ipairs(args or {}) do
    if a == "" or a:find("[%s\"'\\]") then
      a = '"' .. a:gsub("[\"\\]", "\\%0") .. '"'
    end
    table.insert(out, a)
  end
  return table.concat(out, " ")
end

-- ---------------------------------------------------------------------------
-- Resolve project / configuration / kit
-- ---------------------------------------------------------------------------

local function no_kit_message()
  return "no Qt kit found.\n"
    .. "Register a kit with  :QMakeKitAdd <Name> <path/to/qmake>\n"
    .. "or in setup():  kits = { { name = \"Qt 5.15\", qmake = \"/path/to/qmake\" } }"
end

--- Calls cb(p, c) once a .pro file has been determined
local function with_project(cb)
  local p = project.get()
  if not p then
    return
  end
  if p.pro then
    return cb(p, project.config(p))
  end
  vim.ui.select(project.pro_candidates(p), {
    prompt = "Which .pro file?",
    format_item = function(item)
      return vim.fs.basename(item)
    end,
  }, function(choice)
    if choice then
      p.pro = choice
      project.save()
      cb(p, project.config(p))
    end
  end)
end

local function kit_label(kit)
  local v = kits.version(kit)
  if v and not kit.name:find(v, 1, true) then
    return ("%s (Qt %s)"):format(kit.name, v)
  end
  return kit.name
end

local function select_kit_ui(prompt, cb)
  local all = kits.all()
  if #all == 0 then
    return err(no_kit_message())
  end
  vim.ui.select(all, {
    prompt = prompt,
    format_item = function(k)
      return ("%s  [%s]  %s"):format(kit_label(k), k.source, vim.fn.fnamemodify(kits.qmake(k) or k.qmake or "?", ":~"))
    end,
  }, function(k)
    if k then
      cb(k)
    end
  end)
end

--- Calls cb(p, c, kit, env); asks for a kit if none is (still) valid
local function with_kit(cb)
  with_project(function(p, c)
    local function go(kit)
      local ok, env = pcall(kits.env, kit)
      if not ok then
        return err(("Kit \"%s\": %s"):format(kit.name, tostring(env):gsub("^.-:%d+: ", "")))
      end
      cb(p, c, kit, env)
    end
    local kit = project.kit(c)
    if kit then
      return go(kit)
    end
    if #kits.all() == 0 then
      return err(no_kit_message())
    end
    local msg = c.kit and ("Kit \"%s\" no longer exists – please choose another"):format(c.kit)
      or "Select the kit for this configuration"
    select_kit_ui(msg, function(k)
      c.kit = k.name
      project.save()
      go(k)
    end)
  end)
end

local function title(action, c, kit)
  return ("%s [%s · %s · %s]"):format(action, c.name, kit and kit.name or c.kit or "?", c.build_type)
end

local function make_cmd(kit, extra)
  local make = kits.make(kit)
  local cmd = { kits.which(kit, make) or make }
  local flavor = kits.make_flavor(make)
  if flavor == "gnu" then
    -- -w: print directory changes so relative paths in errors can be resolved
    vim.list_extend(cmd, { "-w", "-j" .. project.jobs() })
  elseif flavor == "jom" then
    vim.list_extend(cmd, { "/NOLOGO", "/J", tostring(project.jobs()) })
  else
    -- nmake cannot build in parallel
    table.insert(cmd, "/NOLOGO")
  end
  vim.list_extend(cmd, extra or {})
  return cmd
end

local function qmake_cmd(p, c, kit)
  local qmake = kits.qmake(kit)
  if not qmake then
    return nil
  end
  -- -r: with TEMPLATE = subdirs, create all sub-Makefiles immediately,
  -- otherwise `compiledb -n` finds no compiler invocations before the first build
  local cmd = { qmake, "-r", p.pro }
  if kit.spec then
    vim.list_extend(cmd, { "-spec", kit.spec })
  end
  vim.list_extend(cmd, config.options.qmake_args)
  vim.list_extend(cmd, kit.qmake_args or {})
  vim.list_extend(cmd, config.options.build_type_args[c.build_type] or {})
  if kits.is_win and kits.toolchain_type(kit) == "msvc" then
    -- -FC: full paths in compiler messages. nmake/jom do not report
    -- directory changes, so relative paths would not be resolvable in the quickfix list.
    vim.list_extend(cmd, { "QMAKE_CFLAGS+=-FC", "QMAKE_CXXFLAGS+=-FC" })
  end
  -- Arguments from :QMakeArgs last so they take precedence
  vim.list_extend(cmd, c.qmake_args or {})
  return cmd
end

--- How compile_commands.json is generated: "compiledb" | "builtin" | "bear" | false
local function compile_commands_mode(kit)
  local mode = config.options.compile_commands
  if mode ~= "auto" and mode ~= "compiledb" then
    return mode
  end
  -- compiledb evaluates `make -n` and only understands GNU make
  local gnu = kits.make_flavor(kits.make(kit)) == "gnu"
  if gnu and (mode == "compiledb" or vim.fn.executable("compiledb") == 1) then
    return "compiledb"
  end
  return "builtin"
end

local function compiledb_step(p, bdir, kit, env)
  local out = project.join(bdir, "compile_commands.json")
  if compile_commands_mode(kit) == "builtin" then
    return {
      label = "compile_commands (builtin)",
      cwd = bdir,
      fn = function()
        return compiledb.generate(p, kit, out)
      end,
    }
  end
  return {
    label = "compile_commands",
    cwd = bdir,
    env = env,
    quiet = true,
    summary = function()
      local f = io.open(out, "r")
      if not f then
        return { "compile_commands.json was not generated" }
      end
      local data = vim.json.decode(f:read("*a"))
      f:close()
      local n = #data
      if n == 0 then
        return { "WARNING: compile_commands.json is empty – no compiler invocations found" }
      end
      return { ("compile_commands.json: %d %s"):format(n, n == 1 and "file" or "files") }
    end,
    -- --full-path: absolute compiler path so clangd can find the right
    -- system headers for cross compilers via --query-driver
    cmd = { "compiledb", "-n", "-f", "--full-path", "-o", out, "make", "-c", kits.make(kit) },
  }
end

-- ---------------------------------------------------------------------------
-- compile_commands.json / clangd
-- ---------------------------------------------------------------------------

--- Link the compile_commands.json of the active configuration into the project root
function M.link_compile_commands(p)
  p = p or project.get(true)
  if not p or not config.options.link_compile_commands then
    return
  end
  local src = project.join(project.build_dir(p), "compile_commands.json")
  local dst = project.join(p.root, "compile_commands.json")
  if not project.exists(src) then
    return
  end
  local st = uv.fs_lstat(dst)
  if st then
    if st.type == "link" and uv.fs_readlink(dst) == src then
      return
    end
    uv.fs_unlink(dst)
  end
  if not uv.fs_symlink(src, dst) then
    -- e.g. Windows without symlink permissions
    uv.fs_copyfile(src, dst)
  end
end

--- Restart clangd so the new database is loaded reliably
function M.restart_clangd()
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  local clients = get({ name = "clangd" })
  if #clients == 0 then
    return
  end
  if vim.fn.exists(":LspRestart") == 2 then
    vim.cmd("LspRestart clangd")
    return
  end
  -- Without nvim-lspconfig (vim.lsp.enable): stop and reattach via FileType
  local bufs = {}
  for _, cl in ipairs(clients) do
    vim.list_extend(bufs, vim.tbl_keys(cl.attached_buffers or {}))
    pcall(function()
      cl:stop()
    end)
  end
  vim.defer_fn(function()
    for _, b in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        vim.api.nvim_exec_autocmds("FileType", { buffer = b })
      end
    end
  end, 500)
end

local function after_compile_commands(p)
  M.link_compile_commands(p)
  if config.options.restart_clangd then
    M.restart_clangd()
  end
end

--- After switching configuration, kit, or build type: link the existing
--- database or regenerate it
local function activate(p)
  if project.exists(project.join(project.build_dir(p), "compile_commands.json")) then
    after_compile_commands(p)
  else
    M.generate()
  end
end

-- ---------------------------------------------------------------------------
-- Generate / Build / Clean / Run
-- ---------------------------------------------------------------------------

--- Run qmake and generate compile_commands.json
function M.generate(on_done)
  with_kit(function(p, c, kit, env)
    local qcmd = qmake_cmd(p, c, kit)
    if not qcmd then
      return err(("Kit \"%s\": qmake not found (%s)"):format(kit.name, tostring(kit.qmake)))
    end
    local bdir = project.build_dir(p)
    local steps = { { label = "qmake", cwd = bdir, env = env, cmd = qcmd } }
    local mode = compile_commands_mode(kit)
    if mode == "compiledb" or mode == "builtin" then
      table.insert(steps, compiledb_step(p, bdir, kit, env))
    end
    runner.run(steps, title("Generate", c, kit), function(ok)
      if ok then
        after_compile_commands(p)
      end
      if on_done then
        on_done(ok)
      end
    end)
  end)
end

local function ensure_generated(p, cb)
  if project.exists(project.join(project.build_dir(p), "Makefile")) then
    return cb(true)
  end
  M.generate(cb)
end

--- Build the project (optionally a single make target)
function M.build(target, on_done)
  with_kit(function(p, c, kit, env)
    ensure_generated(p, function(ok)
      if not ok then
        return on_done and on_done(false)
      end
      local bdir = project.build_dir(p)
      local cmd = make_cmd(kit, target and target ~= "" and { target } or nil)
      if config.options.compile_commands == "bear" then
        local out = project.join(bdir, "compile_commands.json")
        cmd = vim.list_extend({ "bear", "--append", "--output", out, "--" }, cmd)
      end
      runner.run({ { label = "make", cwd = bdir, env = env, cmd = cmd } }, title("Build", c, kit), function(res)
        if res and config.options.compile_commands == "bear" then
          after_compile_commands(p)
        end
        if on_done then
          on_done(res)
        end
      end)
    end)
  end)
end

function M.clean()
  with_kit(function(p, c, kit, env)
    local bdir = project.build_dir(p)
    if not project.exists(project.join(bdir, "Makefile")) then
      return info("nothing to clean")
    end
    runner.run({ { label = "make clean", cwd = bdir, env = env, cmd = make_cmd(kit, { "clean" }) } }, title("Clean", c, kit))
  end)
end

function M.rebuild()
  with_kit(function(p, c, kit, env)
    local bdir = project.build_dir(p)
    local steps = {}
    if project.exists(project.join(bdir, "Makefile")) then
      table.insert(steps, { label = "make clean", cwd = bdir, env = env, cmd = make_cmd(kit, { "clean" }) })
    end
    runner.run(steps, title("Clean", c, kit), function(ok)
      if ok then
        M.build()
      end
    end)
  end)
end

local function pick_target(p, c, cb)
  local targets = project.find_targets(p)
  if #targets == 0 then
    return err("no executable found in the build directory")
  end
  if c.run_target and vim.tbl_contains(targets, c.run_target) then
    return cb(c.run_target)
  end
  if #targets == 1 then
    c.run_target = targets[1]
    return cb(targets[1])
  end
  local bdir = project.build_dir(p)
  vim.ui.select(targets, {
    prompt = "Which program should be started?",
    format_item = function(t)
      return t:sub(#bdir + 2)
    end,
  }, function(choice)
    if choice then
      c.run_target = choice
      project.save()
      cb(choice)
    end
  end)
end

local function open_terminal(cmd, cwd, env, name)
  vim.cmd("botright " .. config.options.terminal_height .. "new")
  local opts = { cwd = cwd }
  if env and next(env) then
    opts.env = env
  end
  if vim.fn.has("nvim-0.11") == 1 then
    opts.term = true
    vim.fn.jobstart(cmd, opts)
  else
    vim.fn.termopen(cmd, opts)
  end
  pcall(vim.api.nvim_buf_set_name, 0, "qmake-run://" .. name)
  vim.cmd("startinsert")
end

--- Runtime environment: kit environment plus library search paths prepended
--- to LD_LIBRARY_PATH (on Windows to PATH, where Windows looks for DLLs)
local function run_env(p, kit, env, exe)
  env = vim.deepcopy(env)
  if config.options.add_library_search_paths then
    local var = kits.is_win and "PATH" or "LD_LIBRARY_PATH"
    kits.prepend_path(env, var, project.library_paths(p, exe, kit))
  end
  return env
end

--- Run the selected program (builds first if enabled)
function M.run()
  with_kit(function(p, c, kit, env)
    if kit.run == false and not kit.run_prefix then
      return err(("Kit \"%s\" is a cross kit – local run is disabled (set run_prefix, e.g. for qemu)")
        :format(kit.name))
    end
    local function go()
      pick_target(p, c, function(exe)
        local cmd = vim.deepcopy(kit.run_prefix or {})
        table.insert(cmd, exe)
        vim.list_extend(cmd, c.run_args or {})
        open_terminal(cmd, vim.fs.dirname(exe), run_env(p, kit, env, exe), vim.fs.basename(exe))
      end)
    end
    if config.options.build_before_run then
      M.build(nil, function(ok)
        if ok then
          go()
        end
      end)
    else
      go()
    end
  end)
end

-- ---------------------------------------------------------------------------
-- Selection
-- ---------------------------------------------------------------------------

function M.select_build_type(choice)
  with_project(function(p, c)
    local function apply(bt)
      if not bt then
        return
      end
      c.build_type = bt
      c.run_target = nil
      project.save()
      info(("Build type %s (configuration %s)"):format(bt, c.name))
      activate(p)
    end
    if choice and choice ~= "" then
      return apply(choice)
    end
    vim.ui.select(config.options.build_types, { prompt = "Build type" }, apply)
  end)
end

function M.select_project()
  local p = project.get()
  if not p then
    return
  end
  vim.ui.select(project.pro_candidates(p), {
    prompt = "Select .pro file",
    format_item = function(item)
      return vim.fs.basename(item)
    end,
  }, function(choice)
    if choice then
      p.pro = choice
      for _, c in ipairs(p.configs) do
        c.run_target = nil
      end
      project.save()
      M.generate()
    end
  end)
end

function M.select_target()
  with_project(function(p, c)
    c.run_target = nil
    pick_target(p, c, function(t)
      info("Target " .. vim.fs.basename(t))
    end)
  end)
end

--- Select the kit of the active configuration
function M.select_kit(name)
  with_project(function(p, c)
    local function apply(kit)
      c.kit = kit.name
      c.run_target = nil
      project.save()
      info(("Kit %s (configuration %s)"):format(kit_label(kit), c.name))
      activate(p)
    end
    if name and name ~= "" then
      local kit = kits.get(name)
      if not kit then
        return err("unknown kit: " .. name)
      end
      return apply(kit)
    end
    select_kit_ui("Kit for \"" .. c.name .. "\"", apply)
  end)
end

-- ---------------------------------------------------------------------------
-- Configurations
-- ---------------------------------------------------------------------------

function M.config_names()
  local p = project.get(true)
  if not p then
    return {}
  end
  return vim.tbl_map(function(c)
    return c.name
  end, p.configs)
end

function M.select_config(name)
  local p = project.get()
  if not p then
    return
  end
  local function apply(n)
    if not n then
      return
    end
    if not project.find_config(p, n) then
      return err("unknown configuration: " .. n)
    end
    p.active = n
    project.save()
    local c = project.config(p)
    info(("Configuration %s (%s · %s)"):format(n, c.kit or "no kit", c.build_type))
    activate(p)
  end
  if name and name ~= "" then
    return apply(name)
  end
  vim.ui.select(p.configs, {
    prompt = "Configuration",
    format_item = function(c)
      return ("%s%s  [%s · %s]"):format(c.name == p.active and "● " or "  ", c.name, c.kit or "no kit", c.build_type)
    end,
  }, function(c)
    apply(c and c.name)
  end)
end

--- Create a new configuration as a copy of the active one; then choose a kit
function M.config_new(name)
  local p = project.get()
  if not p then
    return
  end
  local function create(n)
    n = n and vim.trim(n)
    if not n or n == "" then
      return
    end
    local c, e = project.add_config(p, n, project.config(p))
    if not c then
      return err(e)
    end
    info(("Configuration %s created (copy, kit %s)"):format(n, c.kit or "?"))
    -- Immediately ask for the kit, which is usually the reason for a new configuration
    select_kit_ui("Kit for \"" .. n .. "\" (Esc = keep)", function(kit)
      c.kit = kit.name
      project.save()
      info(("Kit %s for %s"):format(kit_label(kit), n))
      activate(p)
    end)
  end
  if name and name ~= "" then
    return create(name)
  end
  vim.ui.input({ prompt = "Name of the new configuration: " }, create)
end

function M.config_rename(new_name)
  local p = project.get()
  if not p then
    return
  end
  local old = p.active
  local function apply(n)
    n = n and vim.trim(n)
    if not n or n == "" or n == old then
      return
    end
    local ok, e = project.rename_config(p, old, n)
    if not ok then
      return err(e)
    end
    info(("Configuration %s → %s (build directory changes, regenerate if needed)"):format(old, n))
    activate(p)
  end
  if new_name and new_name ~= "" then
    return apply(new_name)
  end
  vim.ui.input({ prompt = "New name: ", default = old }, apply)
end

function M.config_delete(name)
  local p = project.get()
  if not p then
    return
  end
  local function apply(n)
    if not n then
      return
    end
    local was_active = n == p.active
    local ok, e = project.remove_config(p, n)
    if not ok then
      return err(e)
    end
    info(("Configuration %s deleted (build directory is kept)"):format(n))
    if was_active then
      activate(p)
    end
  end
  if name and name ~= "" then
    return apply(name)
  end
  vim.ui.select(M.config_names(), { prompt = "Delete configuration" }, apply)
end

-- ---------------------------------------------------------------------------
-- Manage kits
-- ---------------------------------------------------------------------------

function M.kit_names()
  return vim.tbl_map(function(k)
    return k.name
  end, kits.all())
end

--- Register a kit: :QMakeKitAdd <Name> <qmake> [spec]
function M.kit_add(name, qmake, spec)
  local function finish(n, q)
    q = vim.fs.normalize(vim.fn.expand(q))
    if vim.fn.executable(q) ~= 1 then
      return err("not executable: " .. q)
    end
    local kit = { name = n, qmake = q, spec = (spec and spec ~= "") and spec or nil }
    kits.register(kit)
    local v = kits.version(kit)
    info(("Kit \"%s\" registered%s"):format(n, v and (" (Qt " .. v .. ")") or ""))
  end
  if name and qmake then
    return finish(name, qmake)
  end
  vim.ui.input({ prompt = "Path to qmake: ", completion = "file", default = qmake or "" }, function(q)
    if not q or q == "" then
      return
    end
    local probe = kits.version({ qmake = vim.fn.expand(q) })
    local suggestion = name or (probe and ("Qt " .. probe) or "")
    vim.ui.input({ prompt = "Kit name: ", default = suggestion }, function(n)
      if n and vim.trim(n) ~= "" then
        finish(vim.trim(n), q)
      end
    end)
  end)
end

function M.kit_remove(name)
  local function apply(n)
    if not n then
      return
    end
    if kits.unregister(n) then
      info(("Kit \"%s\" removed"):format(n))
    else
      err(("\"%s\" is not a kit registered with :QMakeKitAdd (remove kits from setup() there)"):format(n))
    end
  end
  if name and name ~= "" then
    return apply(name)
  end
  local reg = vim.tbl_filter(function(k)
    return k.source == "registered"
  end, kits.all())
  if #reg == 0 then
    return info("no registered kits")
  end
  vim.ui.select(vim.tbl_map(function(k)
    return k.name
  end, reg), { prompt = "Remove kit" }, apply)
end

--- Show all kits; force = rescan
function M.list_kits(force)
  if force then
    kits.detect(true)
  end
  local all = kits.all()
  if #all == 0 then
    return err(no_kit_message())
  end
  local p = project.get(true)
  local active = p and project.config(p).kit
  local lines = {}
  for _, k in ipairs(all) do
    local problems = kits.check(k)
    table.insert(lines, ("%s %s  [%s]%s"):format(
      k.name == active and "●" or " ",
      kit_label(k),
      k.source,
      #problems > 0 and ("  ⚠ " .. table.concat(problems, "; ")) or ""
    ))
    table.insert(lines, "    qmake: " .. vim.fn.fnamemodify(kits.qmake(k) or k.qmake or "?", ":~"))
    if k.spec then
      table.insert(lines, "    spec:  " .. k.spec)
    end
    if k.env_script then
      table.insert(lines, "    env:   " .. k.env_script)
    end
    if k.run == false or k.run_prefix then
      table.insert(lines, "    run:   " .. (k.run_prefix and M.join_args(k.run_prefix) or "disabled"))
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "qmake-tools: Kits" })
end

--- mkspecs of the active kit (for -spec completion)
function M.mkspecs()
  local p = project.get(true)
  local kit = p and project.kit(project.config(p)) or kits.default()
  if not kit then
    return {}
  end
  local dir = kits.query(kit, "QT_HOST_DATA")
  if not dir then
    return {}
  end
  local specs = {}
  local function scan(base, prefix)
    for name, t in vim.fs.dir(base) do
      if t == "directory" and name ~= "features" and name ~= "common" and name ~= "modules" then
        if name == "devices" and prefix == "" then
          scan(base .. "/devices", "devices/")
        else
          table.insert(specs, prefix .. name)
        end
      end
    end
  end
  pcall(scan, dir .. "/mkspecs", "")
  table.sort(specs)
  return specs
end

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------

--- Shared logic for :QMakeArgs and :QMakeRunArgs (applies to the active configuration)
--- @param field "qmake_args"|"run_args"
local function edit_args(field, opts)
  with_project(function(p, c)
    local function apply(args)
      c[field] = args
      project.save()
      info(("%s [%s]: %s"):format(opts.label, c.name, #args > 0 and M.join_args(args) or "(none)"))
      if opts.on_change then
        opts.on_change(p)
      end
    end
    local function from_line(line)
      local args, open = M.split_args(line)
      if open then
        return err("unterminated quote")
      end
      if opts.add then
        args = vim.list_extend(vim.deepcopy(c[field] or {}), args)
      end
      apply(args)
    end

    if opts.clear then
      return apply({})
    end
    if opts.line and opts.line ~= "" then
      return from_line(opts.line)
    end
    vim.ui.input({ prompt = opts.label .. ": ", default = M.join_args(c[field]) }, function(line)
      if line ~= nil then
        from_line(line)
      end
    end)
  end)
end

local function regenerate_if_configured(p)
  if project.exists(project.join(project.build_dir(p), "Makefile")) then
    M.generate()
  end
end

--- Additional qmake arguments of the active configuration
function M.set_qmake_args(line, opts)
  opts = opts or {}
  edit_args("qmake_args", {
    line = line,
    clear = opts.clear,
    add = opts.add,
    label = "qmake arguments",
    on_change = regenerate_if_configured,
  })
end

--- Run arguments for :QMakeRun (active configuration)
function M.set_run_args(args, opts)
  opts = opts or {}
  if type(args) == "table" then
    args = M.join_args(args)
  end
  edit_args("run_args", { line = args, clear = opts.clear, label = "run arguments" })
end

function M.stop()
  runner.stop()
end

-- ---------------------------------------------------------------------------
-- Info / statusline
-- ---------------------------------------------------------------------------

function M.info()
  local p = project.get()
  if not p then
    return
  end
  local c = project.config(p)
  local kit = project.kit(c)
  local env_ok, env = true, {}
  if kit then
    env_ok, env = pcall(kits.env, kit)
  end
  local lines = {
    "Project root:   " .. p.root,
    ".pro file:      " .. (p.pro and vim.fs.basename(p.pro) or "(not selected)"),
    "Configuration:  " .. c.name .. ("  (%d total: %s)"):format(#p.configs, table.concat(M.config_names(), ", ")),
    "Kit:            " .. (kit and kit_label(kit) or ((c.kit or "?") .. "  ⚠ not found")),
    "Build type:     " .. c.build_type,
    "Build dir:      " .. project.build_dir(p),
  }
  if kit then
    table.insert(lines, "qmake call:     " .. M.join_args(qmake_cmd(p, c, kit) or { "(qmake missing)" }))
    local make = kits.make(kit)
    table.insert(lines, ("Toolchain:      %s · %s · compile_commands: %s"):format(
      kits.toolchain_type(kit),
      kits.which(kit, make) or (make .. " ⚠ not found"),
      tostring(compile_commands_mode(kit))
    ))
    if not env_ok then
      table.insert(lines, "Environment:    ⚠ " .. tostring(env))
    elseif next(env) then
      local keys = vim.tbl_keys(env)
      table.sort(keys)
      table.insert(lines, "Environment:    " .. table.concat(keys, ", "))
    end
  end
  table.insert(lines, "Target:         " .. (c.run_target or "(auto)"))
  table.insert(lines, "Run arguments:  " .. M.join_args(c.run_args))
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "qmake-tools" })
end

--- For the statusline, e.g. lualine: { require("qmake-tools").statusline }
function M.statusline()
  local p = project.get(true)
  if not p then
    return ""
  end
  local c = project.config(p)
  local kit = c.kit or "?"
  local v = kits.get(c.kit) and kits.version(kits.get(c.kit))
  local parts = { "qmake" }
  if #p.configs > 1 then
    table.insert(parts, c.name)
  end
  table.insert(parts, (v and not kit:find(v, 1, true)) and ("Qt " .. v) or kit)
  table.insert(parts, c.build_type)
  local s = table.concat(parts, " · ")
  if runner.is_running() then
    s = s .. " ⟳"
  end
  return s
end

function M.is_qmake_project()
  return project.find_root() ~= nil
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function M.setup(opts)
  vim.g.qmake_tools_setup_called = true
  config.setup(opts)

  local group = vim.api.nvim_create_augroup("QMakeTools", { clear = true })
  if config.options.regenerate_on_save then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      pattern = { "*.pro", "*.pri" },
      callback = function()
        local p = project.get(true)
        if p and p.pro and not runner.is_running()
          and project.exists(project.join(project.build_dir(p), "Makefile")) then
          M.generate()
        end
      end,
    })
  end
end

return M
