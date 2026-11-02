-- Executor: eigenes Fenster mit der Live-Ausgabe von qmake / compiledb / make
local config = require("qmake-tools.config")

local M = {}

local buf
local ns = vim.api.nvim_create_namespace("qmake-tools-executor")
local BUF_NAME = "qmake://executor"

local function opts()
  return config.options.executor
end

local function valid_buf()
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function find_win()
  if not valid_buf() then
    return nil
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

--- Datei unter dem Cursor öffnen (gcc/clang: datei:zeile:spalte)
local function jump()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local file, lnum, col = line:match("^%s*(.-):(%d+):(%d+):")
  if not file then
    file, lnum = line:match("^%s*(.-):(%d+):")
  end
  if not file or file == "" then
    return
  end
  -- Relativen Pfad über das letzte "Entering directory" darüber auflösen
  if file:sub(1, 1) ~= "/" then
    local dir
    local lines = vim.api.nvim_buf_get_lines(buf, 0, row, false)
    for i = #lines, 1, -1 do
      dir = lines[i]:match("Entering directory [`'](.-)'")
      if dir then
        break
      end
    end
    file = vim.fs.normalize((dir or vim.uv.cwd()) .. "/" .. file)
  end
  if not vim.uv.fs_stat(file) then
    return vim.notify("qmake-tools: Datei nicht gefunden: " .. file, vim.log.levels.WARN)
  end
  -- Im vorherigen Fenster öffnen, nicht im Executor
  vim.cmd("wincmd p")
  if vim.api.nvim_get_current_buf() == buf then
    vim.cmd("aboveleft split")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { tonumber(lnum), math.max(0, (tonumber(col) or 1) - 1) })
  vim.cmd("normal! zz")
end

local function ensure_buf()
  if valid_buf() then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, BUF_NAME)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "qmake-executor"
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("q", M.close, "Executor schließen")
  map("<CR>", jump, "Zur Fehlerstelle springen")
  map("<C-c>", function()
    require("qmake-tools.runner").stop()
  end, "Vorgang abbrechen")
  map("]e", function()
    vim.fn.search("\\v(error|Error|Fehler)", "W")
  end, "Nächster Fehler")
  map("[e", function()
    vim.fn.search("\\v(error|Error|Fehler)", "bW")
  end, "Vorheriger Fehler")
  return buf
end

local function setup_win(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.spell = false
  wo.wrap = opts().wrap
  wo.winfixheight = true
  wo.winfixwidth = true
  wo.statusline = " qmake-tools  %=%{v:lua.require'qmake-tools.executor'.status()} "
end

local last_status = ""
function M.status()
  return last_status
end

function M.is_open()
  return find_win() ~= nil
end

--- Executor öffnen; focus = true springt hinein
function M.open(focus)
  ensure_buf()
  local win = find_win()
  if not win then
    local cur = vim.api.nvim_get_current_win()
    local o = opts()
    local vertical = o.position == "right" or o.position == "left"
    local pos = (o.position == "top" or o.position == "left") and "topleft" or "botright"
    vim.cmd(("%s %d%s"):format(pos, o.size, vertical and "vsplit" or "split"))
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    setup_win(win)
    M.scroll_to_end()
    if not focus then
      vim.api.nvim_set_current_win(cur)
    end
  elseif focus then
    vim.api.nvim_set_current_win(win)
  end
end

function M.close()
  local win = find_win()
  if win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, false)
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open(false)
  end
end

function M.scroll_to_end()
  local win = find_win()
  if win and win ~= vim.api.nvim_get_current_win() then
    vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

local function highlight(first, lines)
  for i, l in ipairs(lines) do
    local group
    if l:match("^>> ") then
      group = "Title"
    elseif l:match("FEHLGESCHLAGEN") or l:match("[Ee]rror:") or l:match("Error %d")
      or l:match("[Ee]rror [CLU]%u*%d+") or l:match("%*%*%*") or l:match("beendet mit Code")
      or l:match("^Konnte nicht starten") then
      group = "DiagnosticError"
    elseif l:match("[Ww]arning:") or l:match("[Ww]arning [CLU]%u*%d+") or l:match("^WARNING") then
      group = "DiagnosticWarn"
    elseif l:match("^%[.-%] .*fertig") then
      group = "DiagnosticOk"
    elseif l:match("[Nn]ote:") or l:match("^%S*make[^:]*: Entering") or l:match("^%S*make[^:]*: Leaving") then
      group = "Comment"
    end
    if group then
      vim.api.nvim_buf_set_extmark(buf, ns, first + i - 1, 0, { line_hl_group = group, priority = 50 })
    end
  end
end

--- Neuen Lauf beginnen: Puffer leeren, ggf. Fenster öffnen
function M.start(title)
  if not opts().enabled then
    return
  end
  ensure_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.bo[buf].modifiable = false
  last_status = title .. " ⟳"
  if opts().open == "always" then
    M.open(opts().focus)
  end
end

--- Zeilen anhängen (läuft im Hauptthread)
function M.append(lines)
  if not opts().enabled or not valid_buf() or #lines == 0 then
    return
  end
  -- Nur mitscrollen, wenn der Nutzer am Ende steht (sonst nicht beim Lesen stören)
  local win = find_win()
  local follow = true
  if win and win == vim.api.nvim_get_current_win() then
    follow = vim.api.nvim_win_get_cursor(win)[1] >= vim.api.nvim_buf_line_count(buf)
  end
  local count = vim.api.nvim_buf_line_count(buf)
  local empty = count == 1 and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  local first = empty and 0 or count
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
  vim.bo[buf].modifiable = false
  highlight(first, lines)
  if win and follow then
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

--- Lauf beendet
function M.finish(title, ok)
  if not opts().enabled then
    return
  end
  last_status = title .. (ok and " ✓" or " ✗")
  local o = opts()
  if not ok and o.open == "on_error" then
    M.open(false)
  end
  if ok and o.close_on_success and M.is_open() then
    vim.defer_fn(function()
      -- Nur schließen, wenn inzwischen nicht schon der nächste Lauf gestartet wurde
      if not require("qmake-tools.runner").is_running() then
        M.close()
      end
    end, o.close_on_success_delay)
  end
  vim.cmd("redrawstatus!")
end

return M
