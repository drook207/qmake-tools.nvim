local config = require("qmake-tools.config")
local executor = require("qmake-tools.executor")

local M = {}

local current -- laufender vim.system-Prozess
local qf_title = "qmake-tools"

function M.is_running()
  return current ~= nil
end

function M.stop()
  if current then
    if vim.fn.has("win32") == 1 and current.pid then
      -- Ganzen Prozessbaum beenden, sonst laufen die Compiler von make/jom weiter
      vim.system({ "taskkill", "/T", "/F", "/PID", tostring(current.pid) }):wait(5000)
    else
      current:kill(15)
    end
    vim.notify("qmake-tools: abgebrochen", vim.log.levels.WARN)
  end
end

-- Eingebautes errorformat: Verzeichniswechsel von make/mingw32-make (-w), gcc/clang,
-- MSVC (cl) und qmake. Ohne die Plattform-Voreinstellungen von 'errorformat', die
-- unter Windows weder gcc-Meldungen mit Verzeichnissen noch mingw32-make kennen.
local builtin_efm = table.concat({
  [[%D%*[^ ]: Entering directory %*[`']%f']],
  [[%X%*[^ ]: Leaving directory %*[`']%f']],
  [[%-GIn file included from %.%#]],
  [[%-G%*[ ]from %.%#]],
  -- gcc/clang
  [[%f:%l:%c: fatal %trror: %m]],
  [[%f:%l:%c: %trror: %m]],
  [[%f:%l:%c: %tarning: %m]],
  [[%f:%l:%c: %tote: %m]],
  [[%f:%l: %trror: %m]],
  [[%f:%l: %tarning: %m]],
  [[%f:%l: %tote: %m]],
  -- MSVC
  [[%f(%l\,%c): fatal %trror %m]],
  [[%f(%l\,%c): %trror %m]],
  [[%f(%l\,%c): %tarning %m]],
  [[%f(%l\,%c): %tote: %m]],
  [[%f(%l): fatal %trror %m]],
  [[%f(%l): %trror %m]],
  [[%f(%l): %tarning %m]],
  [[%f(%l): %tote: %m]],
  -- qmake
  [[%tARNING: %f:%l: %m]],
  [[%tRROR: %f:%l: %m]],
  [[Project %tRROR: %m]],
}, ",")

local function errorformat()
  return config.options.errorformat or builtin_efm
end

local function qf_append(lines)
  if #lines == 0 then
    return
  end
  executor.append(lines)
  -- Nur in unsere eigene Liste schreiben, falls inzwischen eine andere aktiv ist
  local info = vim.fn.getqflist({ title = 0, id = 0 })
  if info.title ~= qf_title then
    return
  end
  vim.fn.setqflist({}, "a", { id = info.id, lines = lines, efm = errorformat() })
  -- Quickfix-Fenster mitscrollen
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "quickfix" and vim.fn.getwininfo(win)[1].loclist == 0 then
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
end

local function line_buffer(on_lines)
  local pending = ""
  return function(_, data)
    if not data then
      if pending ~= "" then
        local rest = pending
        pending = ""
        vim.schedule(function()
          on_lines({ rest })
        end)
      end
      return
    end
    pending = pending .. data
    local lines = {}
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      table.insert(lines, (pending:sub(1, nl - 1):gsub("\r$", "")))
      pending = pending:sub(nl + 1)
    end
    if #lines > 0 then
      vim.schedule(function()
        on_lines(lines)
      end)
    end
  end
end

local function has_errors()
  for _, item in ipairs(vim.fn.getqflist()) do
    if item.valid == 1 and (item.type == "e" or item.type == "E") then
      return true
    end
  end
  return false
end

local function open_qf()
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("botright copen")
  vim.cmd("normal! G")
  vim.api.nvim_set_current_win(cur)
end

---@class QMakeStep
---@field cmd string[]
---@field cwd string
---@field label string

--- Führt Schritte nacheinander aus und streamt die Ausgabe in die Quickfix-Liste.
---@param steps QMakeStep[]
---@param title string
---@param on_done fun(ok: boolean)|nil
function M.run(steps, title, on_done)
  if current then
    vim.notify("qmake-tools: es läuft bereits ein Vorgang (:QMakeStop)", vim.log.levels.WARN)
    return
  end
  vim.fn.setqflist({}, " ", { title = qf_title, lines = {} })
  executor.start(title)
  if config.options.open_quickfix == "always" then
    open_qf()
  end

  local started = vim.uv.hrtime()
  local i = 0
  local function finish(ok)
    current = nil
    local secs = (vim.uv.hrtime() - started) / 1e9
    qf_append({ "", string.format("[%s] %s nach %.1fs", title, ok and "fertig" or "FEHLGESCHLAGEN", secs) })
    executor.finish(title, ok)
    local mode = config.options.open_quickfix
    if mode == "always" or (mode == "on_error" and (not ok or has_errors())) then
      open_qf()
    end
    vim.notify(
      string.format("qmake-tools: %s %s", title, ok and "erfolgreich" or "fehlgeschlagen"),
      ok and vim.log.levels.INFO or vim.log.levels.ERROR
    )
    vim.api.nvim_exec_autocmds("User", { pattern = "QMakeToolsDone", data = { title = title, ok = ok } })
    if on_done then
      on_done(ok)
    end
  end

  local function next_step()
    i = i + 1
    local step = steps[i]
    if not step then
      return finish(true)
    end
    vim.fn.mkdir(step.cwd, "p")
    -- Lua-Schritt (z. B. eingebauter compile_commands-Generator): fn() -> ok, lines
    if step.fn then
      qf_append({ ">> " .. step.label })
      local okc, ok, lines = pcall(step.fn)
      if not okc then
        ok, lines = false, { tostring(ok) }
      end
      qf_append(lines or {})
      if ok then
        return next_step()
      end
      return finish(false)
    end
    qf_append({ string.format(">> %s: %s", step.label, table.concat(step.cmd, " ")) })
    -- quiet: Ausgabe sammeln und nur bei Fehler zeigen (für compiledb, dessen
    -- `make -n`-Testlauf harmlose "No rule to make target"-Meldungen erzeugt)
    local collected = {}
    local sink = step.quiet and function(lines)
      vim.list_extend(collected, lines)
    end or qf_append
    local ok, proc = pcall(vim.system, step.cmd, {
      cwd = step.cwd,
      -- Englische Meldungen von make/gcc, damit das errorformat greift
      env = vim.tbl_extend("force", step.env or {}, { LC_MESSAGES = "C", LANGUAGE = "" }),
      text = true,
      stdout = line_buffer(sink),
      stderr = line_buffer(sink),
    }, function(res)
      vim.schedule(function()
        if res.code == 0 then
          if step.summary then
            local oks, lines = pcall(step.summary)
            if oks and lines then
              qf_append(lines)
            end
          end
          next_step()
        else
          qf_append(collected)
          qf_append({ string.format("%s beendet mit Code %d", step.cmd[1], res.code) })
          finish(false)
        end
      end)
    end)
    if not ok then
      qf_append({ "Konnte nicht starten: " .. tostring(proc) })
      return finish(false)
    end
    current = proc
  end

  next_step()
end

return M
