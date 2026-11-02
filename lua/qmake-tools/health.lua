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
    h.error("Neovim >= 0.10 benötigt")
  end

  local cc = config.compile_commands
  if cc == "compiledb" or cc == "bear" then
    if cc == "bear" and vim.fn.has("win32") == 1 then
      h.error("bear gibt es nicht für Windows", { 'compile_commands = "auto" oder "builtin"' })
    elseif vim.fn.executable(cc) == 1 then
      h.ok(cc .. ": " .. vim.fn.exepath(cc))
    else
      h.error(cc .. " nicht gefunden", { cc == "compiledb" and "pip install compiledb" or "bear installieren" })
    end
  elseif cc == "auto" then
    if vim.fn.executable("compiledb") == 1 then
      h.ok("compile_commands: compiledb (" .. vim.fn.exepath("compiledb") .. ") für GNU make, sonst eingebaut")
    else
      h.ok("compile_commands: eingebauter Generator (compiledb nicht installiert)")
    end
  elseif cc == "builtin" then
    h.ok("compile_commands: eingebauter Generator")
  else
    h.info("compile_commands.json-Erzeugung deaktiviert")
  end

  if vim.fn.executable("clangd") == 1 then
    h.ok("clangd gefunden")
  else
    h.warn("clangd nicht im PATH (wird für LSP benötigt)")
  end

  h.start("qmake-tools: Kits")
  local all = kits.all()
  if #all == 0 then
    h.error("kein Kit gefunden", {
      ":QMakeKitAdd \"Name\" /pfad/zu/qmake",
      "oder in setup(): kits = { { name = \"Qt 5.15\", qmake = \"/pfad/zu/qmake\" } }",
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
    h.info("Für Cross-Kits sollte clangd mit --query-driver gestartet werden, damit es die "
      .. "System-Header der Toolchain findet (siehe README, Abschnitt Cross-Compiling).")
  end

  local p = project.get(true)
  if p then
    h.start("qmake-tools: Projekt")
    local c = project.config(p)
    h.info("Root: " .. p.root .. " (" .. (p.pro and vim.fs.basename(p.pro) or "keine .pro gewählt") .. ")")
    for _, cc2 in ipairs(p.configs) do
      local kit = kits.get(cc2.kit)
      local line = ("%s %s: %s · %s → %s"):format(cc2.name == c.name and "●" or "○", cc2.name,
        cc2.kit or "kein Kit", cc2.build_type, project.build_dir(p, cc2))
      if kit then
        h.ok(line)
      else
        h.warn(line .. " (Kit fehlt)", { ":QMakeSelectKit" })
      end
    end
  end
end

return M
