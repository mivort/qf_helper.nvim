local config = require'qf_helper.config'
local util = require'qf_helper.util'
local M = {}

M.setup = function(opts)
  config:update(opts)

  if config.sort_lsp_diagnostics then
    -- Sort diagnostics properly so our qf_helper cursor position works
    local diagnostics_handler = vim.lsp.handlers['textDocument/publishDiagnostics']
    vim.lsp.handlers['textDocument/publishDiagnostics'] = function(a1, a2, params, a4, a5, a6)
      table.sort(params.diagnostics, function(a, b)
        if a.range.start.line == b.range.start.line then
          return a.range.start.character < b.range.start.character
        else
          return a.range.start.line < b.range.start.line
        end
      end)
      return diagnostics_handler(a1, a2, params, a4, a5, a6)
    end
  end

  local autocmd = [[augroup QFHelper
    autocmd!
    autocmd FileType qf lua require'qf_helper'._set_qf_defaults()
  ]]
  if config.quickfix.autoclose or config.loclist.autoclose then
    autocmd = autocmd .. [[
      autocmd WinEnter * lua require'qf_helper'.maybe_autoclose()
    ]]
  end
  if config.quickfix.track_location or config.loclist.track_location then
    autocmd = autocmd .. [[
      autocmd CursorMoved * lua require'qf_helper'.update_qf_position()
    ]]
  end
  autocmd = autocmd .. [[
    augroup END
  ]]

  vim.cmd(autocmd)
end

M.open = function(qftype, opts)
  opts = vim.tbl_extend('keep', opts or {}, {
    enter = false, -- enter the qf window after opening
    height = nil, -- explicitly override the height
  })
  local list = util.get_list(qftype)
  if util.is_open(qftype) then
    if opts.enter and util.get_win_type() ~= qftype then
      M.set_pos(qftype, util.calculate_pos(qftype, list))
      vim.cmd(qftype .. "open")
    end
    return
  end
  local conf = config[qftype]
  if not opts.height then
    opts.height = math.min(conf.max_height, math.max(conf.min_height, vim.tbl_count(list)))
  end
  M.set_pos(qftype, util.calculate_pos(qftype, list))
  local winid = vim.api.nvim_get_current_win()
  local cmd = qftype .. "open " .. opts.height
  if qftype == 'c' then
    cmd = 'botright ' .. cmd
  end
  vim.cmd(cmd)
  if not opts.enter then
    vim.api.nvim_set_current_win(winid)
  end
end

M.toggle = function(qftype, opts)
  if util.is_open(qftype) then
    M.close(qftype)
  else
    M.open(qftype, opts)
  end
end

M.close = function(qftype)
  vim.cmd(qftype .. 'close')
end

-- pos is 1-indexed, like nr in the quickfix
local _set_pos = function(qftype, pos)
  if pos < 1 then
    return
  end
  local start_in_qf = util.get_win_type() == qftype
  if start_in_qf then
    -- If we're in the qf buffer, executing :cc will cause a nearby window to
    -- jump to the qf location. In this case, we leave the qf window so we
    -- *know* the window that jumps, so that we can restore its position
    -- afterwards
    vim.cmd('wincmd w')
  end
  local prev = vim.fn.winsaveview()
  local bufnr = vim.api.nvim_get_current_buf()

  vim.cmd('keepjumps silent ' .. pos .. qftype .. qftype)

  vim.api.nvim_set_current_buf(bufnr)
  vim.fn.winrestview(prev)
  if start_in_qf then
    vim.cmd(qftype .. 'open')
  end
end
M._debounce_idx = 0
M.set_pos = function(qftype, pos)
  if util.get_pos(qftype) == pos then return end
  M._debounce_idx = M._debounce_idx + 1
  local idx = M._debounce_idx
  vim.defer_fn(function()
    if idx == M._debounce_idx then
      _set_pos(qftype, pos)
    end
  end, 10)
end

M.navigate = function(steps, opts)
  opts = vim.tbl_extend('keep', opts or {}, {
    qftype = nil, -- 'c' or 'l', otherwise we make a guess
    wrap = true, -- wrap at end or beginning of list
    by_file = false, -- jump to next/prev file
  })
  local active_list
  if opts.qftype == nil then
    active_list = util.get_active_list()
  else
    active_list = {
      qftype = opts.qftype,
      list = util.get_list(opts.qftype),
    }
  end

  local pos = util.get_pos(active_list.qftype) - 1 + steps
  if opts.by_file then
    if steps < 0 then
      vim.cmd(string.format('silent! %dcpf', math.abs(steps)))
    else
      vim.cmd(string.format('silent! %dcnf', steps))
    end
  else
    if opts.wrap then
      pos = pos % vim.tbl_count(active_list.list)
    end
    pos = pos + 1
    local cmd = pos .. active_list.qftype .. active_list.qftype
    vim.cmd('silent! ' .. cmd)
  end
  vim.cmd('normal! zv')
end

M.update_qf_position = function(qftype)
  if qftype == nil then
    if config.loclist.track_location then
      M.update_qf_position('l')
    end
    if config.quickfix.track_location then
      M.update_qf_position('c')
    end
  elseif util.is_open(qftype) then
    M.set_pos(qftype, util.calculate_pos(qftype, util.get_list(qftype)))
  end
end

M.maybe_autoclose = function()
  local qftype = util.get_win_type()
  local conf = config[qftype]
  if conf and vim.tbl_count(vim.api.nvim_list_wins()) == 1 and conf.autoclose then
    vim.cmd('quit')
  end
end

M.open_split = function(cmd)
  local wintype = util.get_win_type()
  if wintype == '' then
    print("Only use qf_helper.util.open_split inside the quickfix buffer")
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  vim.cmd("wincmd p")
  vim.cmd(cmd)
  vim.cmd(line .. wintype .. wintype)
end

M._set_qf_defaults = function()
  local qftype = util.get_win_type()
  local conf = config[qftype]

  if conf.default_options then
    vim.api.nvim_buf_set_option(0, 'buflisted', false)
    vim.api.nvim_win_set_option(0, 'relativenumber', false)
    vim.api.nvim_win_set_option(0, 'winfixheight', true)
  end

  if conf.default_bindings then
    -- CTRL-t opens selection in new tab
    vim.api.nvim_buf_set_keymap(0, 'n', '<C-t>', '<C-W><CR><C-W>T', {noremap = true, silent = true})
    -- CTRL-s opens selection in horizontal split
    vim.api.nvim_buf_set_keymap(0, 'n', '<C-s>', '<cmd>lua require"qf_helper".open_split("split")<CR>', {noremap = true, silent = true})
    -- CTRL-v opens selection in vertical split
    vim.api.nvim_buf_set_keymap(0, 'n', '<C-v>', '<cmd>lua require"qf_helper".open_split("vsplit")<CR>', {noremap = true, silent = true})
    -- p jumps without leaving quickfix
    vim.api.nvim_buf_set_keymap(0, 'n', '<C-p>', '<CR><C-W>p', {noremap = true, silent = true})
    -- <C-k> scrolls up and jumps without leaving quickfix
    vim.api.nvim_buf_set_keymap(0, 'n', '<C-k>', 'k<CR><C-W>p', {noremap = true, silent = true})
    -- <C-j> scrolls down and jumps without leaving quickfix
    vim.api.nvim_buf_set_keymap(0, 'n', '<C-j>', 'j<CR><C-W>p', {noremap = true, silent = true})
    -- { and } navigates up and down by file
    vim.api.nvim_buf_set_keymap(0, 'n', '{', '<cmd>lua require"qf_helper".navigate(-1, {by_file = true})<CR><C-W>p', {noremap = true, silent = true})
    vim.api.nvim_buf_set_keymap(0, 'n', '}', '<cmd>lua require"qf_helper".navigate(1, {by_file = true})<CR><C-W>p', {noremap = true, silent = true})
  end
end

return M