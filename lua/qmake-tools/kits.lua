-- Kits: a Qt version including toolchain and environment (like kits in Qt Creator)
--
-- A kit is a table:
--   name        (string)   display name, unique
--   qmake       (string)   path to qmake
--   spec        (string?)  mkspec, passed as `-spec <spec>`
--   env         (table?)   additional environment variables; ${VAR} is expanded
--   path        (string[]?) directories prepended to PATH
--   env_script  (string|string[]?) script that is sourced first (e.g. Yocto SDK);
--               on Windows also .bat/.cmd, as a list with arguments: { "vcvarsall.bat", "x64" }
--   toolchain   (false?)   Windows: false = do not search for the compiler automatically
--   vcvarsall   (string|false?) Windows/MSVC: path to vcvarsall.bat (nil = find via vswhere,
--               false = do not load)
--   msvc_arch   (string?)  Windows/MSVC: argument for vcvarsall.bat (nil = from the Qt installation)
--   make        (string?)  make program for this kit (nil = matching the toolchain)
--   qmake_args  (string[]?) additional qmake arguments for this kit
--   run         (boolean?) false = programs cannot be started locally
--   run_prefix  (string[]?) prepended to the program, e.g. { "qemu-arm", "-L", "/sysroot" }
local config = require("qmake-tools.config")

local uv = vim.uv or vim.loop
local M = {}

local is_win = vim.fn.has("win32") == 1
M.is_win = is_win
-- Separator in PATH / LD_LIBRARY_PATH
M.path_sep = is_win and ";" or ":"

local qmake_names = { "qmake", "qmake-qt5", "qmake6", "qmake-qt6" }

-- Common installation locations outside PATH
local unix_globs = {
  "~/Qt/*/gcc_64/bin",
  "~/Qt/*/gcc_arm64/bin",
  "~/Qt/*/macos/bin",
  "~/Qt/*/clang_64/bin",
  "/opt/Qt/*/gcc_64/bin",
  "/opt/qt*/bin",
  "/usr/lib/qt5/bin",
  "/usr/lib64/qt5/bin",
  "/usr/lib/x86_64-linux-gnu/qt5/bin",
  "/usr/lib/aarch64-linux-gnu/qt5/bin",
  "/usr/lib/qt6/bin",
  "/usr/lib64/qt6/bin",
  "/usr/lib/x86_64-linux-gnu/qt6/bin",
  "/usr/lib/aarch64-linux-gnu/qt6/bin",
  "/opt/homebrew/opt/qt@5/bin",
  "/usr/local/opt/qt@5/bin",
  "/opt/homebrew/opt/qt/bin",
  "/usr/local/opt/qt/bin",
}

--- Windows: the Qt installer creates <drive>:\Qt\<version>\<compiler> by default,
--- older/offline installers also <drive>:\Qt\<version>\<version>\<compiler>
local function windows_globs()
  local roots = { "~/Qt" }
  for letter in ("CDEFGHIJKLMNOPQRSTUVWXYZ"):gmatch(".") do
    if uv.fs_stat(letter .. ":/Qt") then
      table.insert(roots, letter .. ":/Qt")
    end
  end
  local res = {}
  for _, root in ipairs(roots) do
    for _, sub in ipairs({ "*", "*/*" }) do
      for _, compiler in ipairs({ "msvc*", "mingw*", "llvm-mingw*" }) do
        table.insert(res, ("%s/%s/%s/bin"):format(root, sub, compiler))
      end
    end
  end
  return res
end

local kits_file = vim.fn.stdpath("data") .. "/qmake-tools-kits.json"

-- ---------------------------------------------------------------------------
-- Stored kits (:QMakeKitAdd)
-- ---------------------------------------------------------------------------

local registered -- nil = not loaded yet

local function load_registered()
  if registered then
    return registered
  end
  registered = {}
  local f = io.open(kits_file, "r")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
      registered = data
    end
  end
  return registered
end

local function save_registered()
  vim.fn.mkdir(vim.fs.dirname(kits_file), "p")
  local f = io.open(kits_file, "w")
  if f then
    f:write(vim.json.encode(registered))
    f:close()
  end
end

-- ---------------------------------------------------------------------------
-- Paths and environment variables
-- ---------------------------------------------------------------------------

--- Windows: environment variable names are case-insensitive there.
--- Returns the spelling under which the variable already exists (e.g. "Path"),
--- so that vim.system replaces it instead of creating a second variable.
local env_keys
function M.env_key(name)
  if not is_win then
    return name
  end
  if not env_keys then
    env_keys = {}
    for k in pairs(vim.fn.environ()) do
      env_keys[k:lower()] = k
    end
  end
  return env_keys[name:lower()] or name
end

--- Value of a variable from env, otherwise from Neovim's environment
function M.getenv(env, name)
  return env[M.env_key(name)] or vim.env[name]
end

--- Path in the operating system's spelling (for PATH and cmd.exe)
function M.native(path)
  path = vim.fs.normalize(path)
  return is_win and (path:gsub("/", "\\")) or path
end

--- Absolute path? (/…, ~…, C:\…, C:/…, \\server\…)
function M.is_absolute(path)
  return path:match("^[/~]") ~= nil or (is_win and (path:match("^%a:[/\\]") or path:match("^[/\\][/\\]")) ~= nil)
end

--- Prepend directories to a path list (PATH, LD_LIBRARY_PATH)
---@param env table is modified
function M.prepend_path(env, var, dirs)
  if #dirs == 0 then
    return
  end
  local key = M.env_key(var)
  local cur = env[key] or vim.env[var]
  local list = vim.tbl_map(M.native, dirs)
  if cur and cur ~= "" then
    table.insert(list, cur)
  end
  env[key] = table.concat(list, M.path_sep)
end

local script_env_cache = {}

--- Variables that a script sets or changes (e.g. environment-setup-* from a
--- Yocto SDK or vcvarsall.bat from Visual Studio)
---@param script string
---@param args string[]|nil
local function script_env(script, args)
  script = vim.fs.normalize(script)
  args = args or {}
  local key = script .. "\0" .. table.concat(args, "\0")
  if script_env_cache[key] then
    return script_env_cache[key]
  end
  if not uv.fs_stat(script) then
    error("env_script not found: " .. script, 0)
  end
  local res, sep
  if script:lower():match("%.bat$") or script:lower():match("%.cmd$") then
    -- Via a temporary .cmd file because cmd.exe does not understand the quoting of
    -- libuv arguments (paths with spaces).
    -- chcp 65001: `set` outputs UTF-8, otherwise non-ASCII characters in PATH are corrupted.
    local quoted = vim.tbl_map(function(a)
      return a:find("[%s&|<>^]") and ('"' .. a .. '"') or a
    end, args)
    local tmp = vim.fn.tempname() .. ".cmd"
    vim.fn.writefile({
      "@echo off",
      "chcp 65001 >nul",
      ('call "%s" %s >nul 2>&1'):format(M.native(script), table.concat(quoted, " ")),
      "if errorlevel 1 exit /b 1",
      "set",
    }, tmp)
    res = vim.system({ "cmd.exe", "/d", "/c", M.native(tmp) }, { text = true }):wait(120000)
    os.remove(tmp)
    sep = "\r?\n"
  else
    local cmd = { "bash", "-c", 'set -a; . "$@" >/dev/null 2>&1; env -0', "_", script }
    vim.list_extend(cmd, args)
    res = vim.system(cmd, { text = true }):wait(15000)
    sep = "%z"
  end
  if res.code ~= 0 then
    error("env_script failed: " .. script .. (#args > 0 and (" " .. table.concat(args, " ")) or ""), 0)
  end
  local current = vim.fn.environ()
  local changed = {}
  for entry in (res.stdout .. (sep == "%z" and "\0" or "\n")):gmatch("(.-)" .. sep) do
    local k, v = entry:match("^([^=]+)=(.*)$")
    -- NVIM: Neovim sets this only for child processes, not part of the script's environment
    if k and k ~= "_" and k ~= "SHLVL" and k ~= "PWD" and k ~= "OLDPWD" and k ~= "PROMPT" and k ~= "NVIM" then
      k = M.env_key(k)
      if current[k] ~= v then
        changed[k] = v
      end
    end
  end
  script_env_cache[key] = changed
  return changed
end

local function env_script_of(kit)
  local s = kit.env_script
  if type(s) == "table" then
    return s[1], vim.list_slice(s, 2)
  end
  return s, nil
end

--- Environment from the kit's env_script, path, and env (without automatic toolchain)
local function base_env(kit)
  local env = {}
  local script, args = env_script_of(kit)
  if script then
    env = vim.deepcopy(script_env(script, args))
  end
  if kit.path and #kit.path > 0 then
    M.prepend_path(env, "PATH", kit.path)
  end
  for k, v in pairs(kit.env or {}) do
    v = tostring(v):gsub("%${([%w_]+)}", function(name)
      return M.getenv(env, name) or ""
    end)
    env[M.env_key(k)] = v
  end
  return env
end

local function path_dirs(env)
  local res = {}
  local sep = vim.pesc(M.path_sep)
  for dir in (M.getenv(env, "PATH") or ""):gmatch("[^" .. sep .. "]+") do
    table.insert(res, dir)
  end
  return res
end

local function is_path(exe)
  return exe:find("[/\\]") ~= nil
end

--- Executable file including extension (.exe on Windows), otherwise nil
local function resolve(path)
  if vim.fn.executable(path) ~= 1 then
    return nil
  end
  if is_win then
    local full = vim.fn.exepath(path)
    if full ~= "" then
      return vim.fs.normalize(full)
    end
  end
  return vim.fs.normalize(path)
end

local function which_in(env, exe)
  if is_path(exe) then
    exe = vim.fs.normalize(vim.fn.expand(exe))
    return resolve(exe)
  end
  for _, dir in ipairs(path_dirs(env)) do
    local p = resolve(dir .. "/" .. exe)
    if p then
      return p
    end
  end
  return nil
end

function M.qmake(kit)
  return which_in(base_env(kit), kit.qmake or "qmake")
end

-- ---------------------------------------------------------------------------
-- qmake -query
-- ---------------------------------------------------------------------------

local query_cache = {}

--- Result of `qmake -query <var>` (cached)
function M.query(kit, var)
  local qmake = M.qmake(kit)
  if not qmake then
    return nil
  end
  local key = qmake .. "\0" .. vim.inspect(kit.env_script or "")
  query_cache[key] = query_cache[key] or {}
  if query_cache[key][var] == nil then
    local ok, res = pcall(function()
      return vim.system({ qmake, "-query", var }, { text = true, env = base_env(kit) }):wait(10000)
    end)
    local value = (ok and res.code == 0) and vim.trim(res.stdout) or ""
    -- Paths on Windows consistently with /
    if is_win and value:match("^%a:[/\\]") then
      value = vim.fs.normalize(value)
    end
    query_cache[key][var] = value ~= "" and value or false
  end
  return query_cache[key][var] or nil
end

function M.version(kit)
  return M.query(kit, "QT_VERSION")
end

-- ---------------------------------------------------------------------------
-- Toolchain (Windows): find the compiler and make matching the Qt version
-- ---------------------------------------------------------------------------
--
-- On Linux/macOS the compiler is in PATH. On Windows the environment first has to be
-- set up like in Qt Creator:
--   MinGW: <Qt-Root>/Tools/mingw810_64/bin (matching mingw81_64) into PATH
--   MSVC:  load vcvarsall.bat of the Visual Studio installation (via vswhere)
-- In addition, Qt's bin directory is added to PATH (DLLs, moc, uic, …).

--- Toolchain type based on the mkspec: "msvc" | "mingw" | "gnu"
function M.toolchain_type(kit)
  local spec = kit.spec or M.query(kit, "QMAKE_XSPEC") or ""
  if spec:match("msvc") then
    return "msvc"
  end
  if spec:match("^win32%-") then
    return "mingw"
  end
  return "gnu"
end

--- Name of the Qt installation, e.g. "mingw81_64" from D:/Qt/5.15.2/mingw81_64
local function install_name(kit)
  local prefix = M.query(kit, "QT_INSTALL_PREFIX")
  return prefix and vim.fs.basename(prefix) or ""
end

--- Splits "mingw81_64" / "llvm-mingw1706_64" / "mingw_64" into name, version, bits
local function split_tool_name(name)
  local base, ver, bits = name:lower():match("^(%a[%a%-]-)(%d*)_(%d+)$")
  return base, ver, bits
end

--- Find a matching MinGW under <Qt-Root>/Tools (as laid out by the Qt installer)
local function find_mingw(kit)
  local prefix = M.query(kit, "QT_INSTALL_PREFIX")
  if not prefix then
    return nil
  end
  local want_base, want_ver, want_bits = split_tool_name(vim.fs.basename(prefix))
  if not want_base then
    return nil
  end
  -- Tools is two (Qt/5.15.2/mingw81_64) or three levels up (Qt/5.12.12/5.12.12/mingw73_64)
  local best, best_ver
  local dir = prefix
  for _ = 1, 3 do
    dir = vim.fs.dirname(dir)
    local tools = dir .. "/Tools"
    if uv.fs_stat(tools) then
      for name, t in vim.fs.dir(tools) do
        local base, ver, bits = split_tool_name(name)
        if t == "directory" and base == want_base and bits == want_bits
          and (want_ver == "" or ver:sub(1, #want_ver) == want_ver)
          and uv.fs_stat(tools .. "/" .. name .. "/bin") then
          -- For "mingw_64" (Qt 6) without a version: newest MinGW
          local n = tonumber(ver) or 0
          if not best_ver or n > best_ver then
            best, best_ver = tools .. "/" .. name .. "/bin", n
          end
        end
      end
      if best then
        return best
      end
    end
  end
  return nil
end

--- vcvarsall.bat of the newest Visual Studio installation with a C++ compiler
local vcvarsall_cache
local function find_vcvarsall()
  if vcvarsall_cache ~= nil then
    return vcvarsall_cache or nil
  end
  vcvarsall_cache = false
  local pf86 = vim.env["ProgramFiles(x86)"] or "C:/Program Files (x86)"
  local vswhere = vim.fs.normalize(pf86) .. "/Microsoft Visual Studio/Installer/vswhere.exe"
  if vim.fn.executable(vswhere) ~= 1 then
    return nil
  end
  local res = vim.system({
    vswhere, "-latest", "-products", "*",
    "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "-property", "installationPath",
  }, { text = true }):wait(15000)
  local dir = res.code == 0 and vim.trim(res.stdout or ""):match("[^\r\n]+")
  if dir then
    local bat = vim.fs.normalize(dir) .. "/VC/Auxiliary/Build/vcvarsall.bat"
    if uv.fs_stat(bat) then
      vcvarsall_cache = bat
    end
  end
  return vcvarsall_cache or nil
end

--- Argument for vcvarsall.bat from the Qt installation (msvc2019_64 → x64)
local function msvc_arch(kit)
  if kit.msvc_arch then
    return kit.msvc_arch
  end
  local name = install_name(kit)
  local host_arm = (vim.env.PROCESSOR_ARCHITECTURE or ""):upper() == "ARM64"
  if name:match("_arm64$") then
    return host_arm and "arm64" or "x64_arm64"
  end
  if name:match("_64$") then
    return host_arm and "arm64_amd64" or "x64"
  end
  return host_arm and "arm64_x86" or "x86"
end

--- jom (parallel, nmake-compatible) from the Qt Creator installation or PATH
local function find_jom(kit)
  local found = which_in({}, "jom")
  if found then
    return found
  end
  local dir = M.query(kit, "QT_INSTALL_PREFIX")
  for _ = 1, 3 do
    if not dir then
      break
    end
    dir = vim.fs.dirname(dir)
    for _, sub in ipairs({ "/Tools/QtCreator/bin/jom/jom.exe", "/Tools/QtCreator/bin/jom.exe" }) do
      if uv.fs_stat(dir .. sub) then
        return dir .. sub
      end
    end
  end
  return nil
end

local toolchain_cache = {}

--- Automatically added environment for the kit's compiler (Windows only)
---@return { env: table, make: string|nil, type: string }
local function toolchain(kit, env)
  local key = kit.name .. "\0" .. tostring(M.qmake(kit))
  if toolchain_cache[key] then
    return toolchain_cache[key]
  end
  local tc = { env = {}, type = M.toolchain_type(kit) }
  if is_win and kit.toolchain ~= false then
    local add_path = {}
    if tc.type == "mingw" then
      local cxx = (kit.spec or M.query(kit, "QMAKE_XSPEC") or ""):match("clang") and "clang++" or "g++"
      if not which_in(env, cxx) then
        local bin = find_mingw(kit)
        if not bin then
          error(("MinGW compiler not found (%s missing from PATH, no matching Tools/%s* in Qt) – "
            .. "set path = { \"…/mingw…/bin\" } in the kit"):format(cxx, install_name(kit):gsub("_%d+$", "")), 0)
        end
        table.insert(add_path, bin)
      end
    elseif tc.type == "msvc" and not kit.env_script and kit.vcvarsall ~= false and not which_in(env, "cl") then
      local bat = kit.vcvarsall and vim.fs.normalize(vim.fn.expand(kit.vcvarsall)) or find_vcvarsall()
      if not bat then
        error("Visual Studio (vcvarsall.bat) not found – install Visual Studio or the Build Tools with the "
          .. "C++ workload, or set vcvarsall = \"…/vcvarsall.bat\" in the kit", 0)
      end
      local arch = msvc_arch(kit)
      tc.env = vim.deepcopy(script_env(bat, { arch }))
      -- vcvarsall does not report missing compiler components as an error and then
      -- leaves e.g. the x64 compiler in PATH – that would silently produce wrong binaries
      local target = arch:match("_(%w+)$") or arch
      target = ({ amd64 = "x64", arm64 = "arm64", x86 = "x86", x64 = "x64" })[target] or target
      local cl = which_in(vim.tbl_extend("force", env, tc.env), "cl") or ""
      if not cl:lower():find("/" .. target .. "/cl%.exe$") then
        error(("MSVC compiler for %s not installed (vcvarsall.bat %s) – in the Visual Studio Installer "
          .. "add the C++ build tools for %s"):format(target, arch, target), 0)
      end
    end
    if tc.type == "msvc" then
      -- English compiler messages, otherwise the errorformat does not match
      tc.env.VSLANG = "1033"
    end
    -- Qt DLLs, moc, uic, … as in Qt Creator
    local bins = M.query(kit, "QT_INSTALL_BINS")
    if bins then
      table.insert(add_path, 1, bins)
    end
    if #add_path > 0 then
      -- PATH from vcvarsall (contains the original PATH), otherwise the kit's
      local key = M.env_key("PATH")
      tc.env[key] = tc.env[key] or env[key]
      M.prepend_path(tc.env, "PATH", add_path)
    end
  end
  -- make matching the toolchain
  if tc.type == "msvc" then
    tc.make = find_jom(kit) or "nmake"
  elseif tc.type == "mingw" then
    tc.make = "mingw32-make"
  end
  toolchain_cache[key] = tc
  return tc
end

--- Full additional environment of a kit (only changed variables).
--- Throws an error if env_script or the toolchain cannot be loaded.
---@return table<string,string>
function M.env(kit)
  local env = base_env(kit)
  return vim.tbl_extend("force", env, toolchain(kit, env).env)
end

--- Resolve a program in the PATH of the kit environment
function M.which(kit, exe)
  local ok, env = pcall(M.env, kit)
  return which_in(ok and env or base_env(kit), exe)
end

--- make program of the kit: kit option > setup() option > matching the toolchain
function M.make(kit)
  if kit.make then
    return kit.make
  end
  if config.options.make_executable then
    return config.options.make_executable
  end
  local ok, tc = pcall(function()
    return toolchain(kit, base_env(kit))
  end)
  return ok and tc.make or "make"
end

--- "gnu" (make, mingw32-make) | "nmake" | "jom"
function M.make_flavor(make)
  local name = vim.fs.basename(make):lower():gsub("%.exe$", "")
  if name == "nmake" or name == "jom" then
    return name
  end
  return "gnu"
end

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------

local detected -- cache

local function realpath(p)
  return uv.fs_realpath(p) or p
end

--- Descriptive name, e.g. "Qt 5.15.2 gcc_64" or "Qt 5.15.8 (System)"
local function detected_name(qmake, version)
  local v = version or "?"
  local inst = qmake:match("/Qt/[^/]+/([^/]+)/bin/[^/]+$") or qmake:match("/Qt/.-/([^/]+)/bin/[^/]+$")
  if inst then
    return ("Qt %s %s"):format(v, inst)
  end
  if qmake:match("^/usr/") and not qmake:match("^/usr/local/") then
    return ("Qt %s (System)"):format(v)
  end
  if qmake:match("homebrew") or qmake:match("/usr/local/opt/") then
    return ("Qt %s (Homebrew)"):format(v)
  end
  return ("Qt %s (%s)"):format(v, vim.fn.fnamemodify(qmake, ":~:h:h"))
end

local function shell_lookup()
  local shell = vim.env.SHELL
  if not shell or shell == "" or is_win then
    return {}
  end
  local found = {}
  for _, flags in ipairs({ "-ic", "-lic" }) do
    for _, exe in ipairs(qmake_names) do
      for _, line in ipairs(vim.fn.systemlist({ shell, flags, "type " .. exe .. " 2>/dev/null" })) do
        local path = line:match("^" .. vim.pesc(exe) .. " is (/%S+)$")
          or line:match("aliased to [`'](/[^'`%s]+)")
          or line:match("alias for (/%S+)")
        if path then
          path = path:gsub("['`]$", "")
          if vim.fn.executable(path) == 1 then
            table.insert(found, path)
          end
        end
      end
    end
    if #found > 0 then
      break
    end
  end
  return found
end

--- Find all Qt installations on the system
---@param force boolean|nil rescan
function M.detect(force)
  if detected and not force then
    return detected
  end
  if force then
    query_cache, toolchain_cache, script_env_cache, vcvarsall_cache = {}, {}, {}, nil
  end
  detected = {}
  if config.options.detect_kits == false then
    return detected
  end
  local candidates = {}
  local function add(path)
    local p = resolve(path)
    if p then
      table.insert(candidates, p)
    end
  end
  local env_qmake = vim.env.QMAKE
  if env_qmake and env_qmake ~= "" then
    add(vim.fn.expand(env_qmake))
  end
  for _, exe in ipairs(qmake_names) do
    if vim.fn.executable(exe) == 1 then
      add(vim.fn.exepath(exe))
    end
  end
  for _, pattern in ipairs(is_win and windows_globs() or unix_globs) do
    for _, dir in ipairs(vim.fn.glob(vim.fs.normalize(pattern), false, true)) do
      dir = vim.fs.normalize(dir)
      -- Android/WebAssembly are cross kits and need their own settings
      if not dir:match("/android_[^/]*/bin$") and not dir:match("/wasm_[^/]*/bin$") then
        for _, exe in ipairs(qmake_names) do
          add(dir .. "/" .. exe)
        end
      end
    end
  end
  if #candidates == 0 then
    vim.list_extend(candidates, shell_lookup())
  end

  -- Only one qmake per directory (Qt 6 provides qmake and qmake6)
  local seen, dirs, names = {}, {}, {}
  for _, qmake in ipairs(candidates) do
    local real = realpath(qmake)
    local dir = vim.fs.dirname(real)
    if not seen[real] and not dirs[dir] then
      seen[real], dirs[dir] = true, true
      local kit = { qmake = qmake, detected = true }
      -- ARM64 Qt on an x64 machine (or vice versa) is a cross kit
      local host_arm = (is_win and (vim.env.PROCESSOR_ARCHITECTURE or ""):upper() == "ARM64")
        or (not is_win and (uv.os_uname().machine:match("^aarch64") or uv.os_uname().machine:match("^arm64")) ~= nil)
      if dir:match("_arm64/bin$") and not host_arm then
        kit.run = false
      end
      local name = detected_name(qmake, M.version(kit))
      if names[name] then
        names[name] = names[name] + 1
        name = ("%s #%d"):format(name, names[name])
      else
        names[name] = 1
      end
      kit.name = name
      table.insert(detected, kit)
    end
  end
  -- Newest version first
  local function vkey(k)
    return (M.version(k) or "0"):gsub("%d+", function(n)
      return ("%05d"):format(tonumber(n))
    end)
  end
  table.sort(detected, function(a, b)
    return vkey(a) > vkey(b)
  end)
  return detected
end

-- ---------------------------------------------------------------------------
-- Full list
-- ---------------------------------------------------------------------------

--- All kits: from setup() > stored (:QMakeKitAdd) > automatically detected.
--- Kits with the same name from a higher-priority source replace the others.
function M.all()
  local list, by_name = {}, {}
  local function add(kit, source)
    if not kit.name or by_name[kit.name] then
      return
    end
    kit = vim.deepcopy(kit)
    kit.source = source
    by_name[kit.name] = kit
    table.insert(list, kit)
  end
  -- Compatibility: the old qmake_executable option becomes the kit "Standard"
  if config.options.qmake_executable then
    add({ name = "Standard", qmake = vim.fn.expand(config.options.qmake_executable) }, "setup")
  end
  for name, kit in pairs(config.options.kits or {}) do
    -- allows both a list and { ["Name"] = { ... } }
    if type(name) == "string" and not kit.name then
      kit = vim.tbl_extend("force", { name = name }, kit)
    end
    add(kit, "setup")
  end
  for _, kit in ipairs(load_registered()) do
    add(kit, "registered")
  end
  for _, kit in ipairs(M.detect()) do
    add(kit, "detected")
  end
  return list
end

function M.get(name)
  if not name then
    return nil
  end
  for _, kit in ipairs(M.all()) do
    if kit.name == name then
      return kit
    end
  end
end

--- Default kit: default_kit option, otherwise the first local (non-cross) kit
function M.default()
  local all = M.all()
  local chosen = M.get(config.options.default_kit)
  if chosen then
    return chosen
  end
  for _, kit in ipairs(all) do
    if kit.run ~= false and not kit.spec and not kit.env_script then
      return kit
    end
  end
  return all[1]
end

--- Register a kit (stored in stdpath("data"))
function M.register(kit)
  load_registered()
  for i, k in ipairs(registered) do
    if k.name == kit.name then
      registered[i] = kit
      save_registered()
      return
    end
  end
  table.insert(registered, kit)
  save_registered()
end

function M.unregister(name)
  load_registered()
  for i, k in ipairs(registered) do
    if k.name == name then
      table.remove(registered, i)
      save_registered()
      return true
    end
  end
  return false
end

--- Short, filesystem-safe name for build directories
function M.slug(name)
  local s = (name or "kit"):lower():gsub("[^%w%._]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return s
end

--- Compiler of the kit (for display and checks)
function M.compiler(kit)
  local t = M.toolchain_type(kit)
  if t == "msvc" then
    return "cl"
  end
  return (kit.spec or M.query(kit, "QMAKE_XSPEC") or ""):match("clang") and "clang++" or "g++"
end

--- Problems of a kit (empty list = all good)
function M.check(kit)
  local problems = {}
  if not M.qmake(kit) then
    table.insert(problems, "qmake not found: " .. tostring(kit.qmake))
    return problems
  elseif not M.version(kit) then
    table.insert(problems, "`qmake -query` fails")
    return problems
  end
  local ok, e = pcall(M.env, kit)
  if not ok then
    table.insert(problems, tostring(e))
    return problems
  end
  local cc = M.compiler(kit)
  if kit.run ~= false and not kit.spec and not M.which(kit, cc) then
    table.insert(problems, "compiler not found: " .. cc)
  end
  if not M.which(kit, M.make(kit)) then
    table.insert(problems, "make not found: " .. M.make(kit))
  end
  return problems
end

return M
