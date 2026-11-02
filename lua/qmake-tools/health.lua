local M = {}

function M.check()
  local h = vim.health
  local config = require("qmake-tools.config").options
  local project = require("qmake-tools.project")
  local kits = require("qmake-tools.kits")

  h.start("qmake-tools")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim >= 0.10 required")
  end

  local cc = config.compile_commands
  if cc == "compiledb" or cc == "bear" then
    if cc == "bear" and vim.fn.has("win32") == 1 then
      h.error("bear is not available for Windows", { 'compile_commands = "auto" or "builtin"' })
    elseif vim.fn.executable(cc) == 1 then
      h.ok(cc .. ": " .. vim.fn.exepath(cc))
    else
      h.error(cc .. " not found", { cc == "compiledb" and "pip install compiledb" or "install bear" })
    end
  elseif cc == "auto" then
    if vim.fn.executable("compiledb") == 1 then
      h.ok("compile_commands: compiledb (" .. vim.fn.exepath("compiledb") .. ") for GNU make, builtin otherwise")
    else
      h.ok("compile_commands: builtin generator (compiledb not installed)")
    end
  elseif cc == "builtin" then
    h.ok("compile_commands: builtin generator")
  else
    h.info("compile_commands.json generation disabled")
  end

  if vim.fn.executable("clangd") == 1 then
    h.ok("clangd found")
  else
    h.warn("clangd not in PATH (required for LSP)")
  end

  h.start("qmake-tools: Kits")
  local all = kits.all()
  if #all == 0 then
    h.error("no kit found", {
      ':QMakeKitAdd "Name" /path/to/qmake',
      'or in setup(): kits = { { name = "Qt 5.15", qmake = "/path/to/qmake" } }',
    })
  end
  local cross = false
  for _, kit in ipairs(all) do
    local problems = kits.check(kit)
    local label = ("%s [%s] – %s"):format(kit.name, kit.source, kits.qmake(kit) or tostring(kit.qmake))
    if #problems == 0 then
      local make = kits.make(kit)
      h.ok(("%s (Qt %s) · %s: %s · make: %s"):format(label, kits.version(kit) or "?", kits.toolchain_type(kit),
        kits.which(kit, kits.compiler(kit)) or kits.compiler(kit), kits.which(kit, make) or make))
    else
      h.error(label, problems)
    end
    if kit.spec or kit.env_script or kit.run == false then
      cross = true
    end
  end
  if cross then
    h.info("For cross kits, clangd should be started with --query-driver so it can find the "
      .. "toolchain's system headers (see README, section Cross-compiling).")
  end

  local p = project.get(true)
  if p then
    h.start("qmake-tools: Project")
    local c = project.config(p)
    h.info("Root: " .. p.root .. " (" .. (p.pro and vim.fs.basename(p.pro) or "no .pro selected") .. ")")
    for _, cc2 in ipairs(p.configs) do
      local kit = kits.get(cc2.kit)
      local line = ("%s %s: %s · %s → %s"):format(cc2.name == c.name and "●" or "○", cc2.name,
        cc2.kit or "no kit", cc2.build_type, project.build_dir(p, cc2))
      if kit then
        h.ok(line)
      else
        h.warn(line .. " (kit missing)", { ":QMakeSelectKit" })
      end
    end
  end
end

return M
