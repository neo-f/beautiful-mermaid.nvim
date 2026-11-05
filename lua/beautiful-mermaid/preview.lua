local M = {}

local cli = vim.fs.joinpath(vim.fs.root(debug.getinfo(1, "S").source:sub(2), "lua"), "tools", "mermaid", "cli.mjs")
local namespace = vim.api.nvim_create_namespace("beautiful-mermaid-preview")
local states = {}
local cache = {}
local failures = {}
local query = vim.treesitter.query.parse(
  "markdown",
  [[
    (fenced_code_block
      (info_string (language) @language)
      (#eq? @language "mermaid")
      (code_fence_content) @content) @block
  ]]
)

local function current_buf(buf)
  if buf == 0 or buf == nil then
    return vim.api.nvim_get_current_buf()
  end
  return buf
end

local function find_blocks(buf)
  local parser = vim.treesitter.get_parser(buf, "markdown")
  local tree = parser:parse()[1]
  local blocks = {}

  for _, match in query:iter_matches(tree:root(), buf, 0, -1) do
    local captures = {}
    for id, nodes in pairs(match) do
      local node = type(nodes) == "userdata" and nodes or nodes[1]
      captures[query.captures[id]] = node
    end

    local block_node = captures.block
    local content_node = captures.content
    if block_node and content_node then
      local start_row, start_col, end_row, end_col = block_node:range()
      if end_col == 0 and end_row > start_row then
        end_row = end_row - 1
        end_col = #(vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or "")
      end
      local source = vim.treesitter.get_node_text(content_node, buf)
      blocks[#blocks + 1] = {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
        source = source,
        hash = vim.fn.sha256(source),
        marks = {},
        displayed = false,
        pending = false,
      }
    end
  end

  table.sort(blocks, function(a, b)
    return a.start_row < b.start_row
  end)
  return blocks
end

local function cursor_in_block(buf, block)
  if vim.api.nvim_get_current_buf() ~= buf then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  return row >= block.start_row and row <= block.end_row
end

local function clear_block(buf, block)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, id in ipairs(block.marks) do
    vim.api.nvim_buf_del_extmark(buf, namespace, id)
  end
  block.marks = {}
  block.displayed = false
end

local function next_visible_row(buf, row)
  local line_count = vim.api.nvim_buf_line_count(buf)
  while row < line_count do
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, { row, 0 }, { row, -1 }, {
      details = true,
      overlap = true,
    })
    local concealed = false
    for _, mark in ipairs(marks) do
      if mark[4].conceal_lines then
        concealed = true
        break
      end
    end
    if not concealed then
      break
    end
    row = row + 1
  end
  return row
end

local function draw_block(buf, block, ascii)
  if cursor_in_block(buf, block) then
    return
  end

  clear_block(buf, block)
  local padding = string.rep(" ", block.start_col)
  local virt_lines = {}
  for _, line in ipairs(vim.split(ascii:gsub("\n+$", ""), "\n", { plain = true })) do
    virt_lines[#virt_lines + 1] = { { padding .. line, "Normal" } }
  end
  if #virt_lines == 0 then
    return
  end

  block.marks = {
    vim.api.nvim_buf_set_extmark(buf, namespace, block.start_row, 0, {
      end_row = block.end_row + 1,
      end_col = 0,
      conceal_lines = "",
      undo_restore = false,
      strict = false,
    }),
    vim.api.nvim_buf_set_extmark(buf, namespace, next_visible_row(buf, block.end_row + 1), 0, {
      virt_lines = virt_lines,
      virt_lines_above = true,
      virt_lines_overflow = "scroll",
      priority = 1000,
      undo_restore = false,
      strict = false,
    }),
  }
  block.displayed = true
end

local show_block

show_block = function(buf, state, block)
  if not state.enabled or block.displayed or block.pending or cursor_in_block(buf, block) then
    return
  end
  if failures[block.hash] then
    return
  end
  if cache[block.hash] then
    draw_block(buf, block, cache[block.hash])
    return
  end

  local node = vim.fn.exepath("node")
  if node == "" then
    failures[block.hash] = "node executable not found"
    vim.notify("Mermaid: node executable not found", vim.log.levels.ERROR)
    return
  end

  block.pending = true
  local generation = state.generation
  vim.system({ node, cli }, { stdin = block.source, text = true }, function(result)
    vim.schedule(function()
      block.pending = false
      if not vim.api.nvim_buf_is_valid(buf) or states[buf] ~= state or not state.enabled or state.generation ~= generation then
        return
      end
      if result.code ~= 0 then
        local message = vim.trim(result.stderr or "rendering failed")
        if not failures[block.hash] then
          vim.notify("Mermaid: " .. message, vim.log.levels.WARN)
        end
        failures[block.hash] = message
        return
      end
      cache[block.hash] = result.stdout
      show_block(buf, state, block)
    end)
  end)
end

local function update_cursor(buf)
  local state = states[buf]
  if not state or not state.enabled then
    return
  end
  for _, block in ipairs(state.blocks) do
    if cursor_in_block(buf, block) then
      clear_block(buf, block)
    else
      show_block(buf, state, block)
    end
  end
end

local function schedule_refresh(buf)
  local state = states[buf]
  if not state or not state.enabled or state.refresh_scheduled then
    return
  end
  state.refresh_scheduled = true
  vim.defer_fn(function()
    state.refresh_scheduled = false
    if vim.api.nvim_buf_is_valid(buf) and states[buf] == state and state.enabled then
      M.refresh(buf)
    end
  end, 150)
end

local function prepare_conceallevel(buf)
  local state = states[buf]
  if state.conceallevel == nil then
    state.conceallevel = vim.wo.conceallevel
  end
  vim.wo.conceallevel = 3
end

local function restore_conceallevel(state)
  if state.conceallevel ~= nil then
    vim.wo.conceallevel = state.conceallevel
    state.conceallevel = nil
  end
end

function M.refresh(buf, force)
  buf = current_buf(buf)
  local state = states[buf]
  if not state or not state.enabled then
    return
  end
  if force then
    cache = {}
    failures = {}
  end

  prepare_conceallevel(buf)
  state.generation = state.generation + 1
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local ok, blocks = pcall(find_blocks, buf)
  if not ok then
    vim.notify("Mermaid: " .. tostring(blocks), vim.log.levels.ERROR)
    return
  end
  state.blocks = blocks
  for _, block in ipairs(blocks) do
    if cursor_in_block(buf, block) then
      clear_block(buf, block)
    else
      show_block(buf, state, block)
    end
  end
end

function M.attach(buf)
  buf = current_buf(buf)
  if states[buf] or vim.bo[buf].filetype ~= "markdown" then
    return
  end

  local state = {
    enabled = true,
    generation = 0,
    blocks = {},
    refresh_scheduled = false,
  }
  states[buf] = state
  state.group = vim.api.nvim_create_augroup("beautiful-mermaid.preview." .. buf, { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = state.group,
    buffer = buf,
    callback = function()
      update_cursor(buf)
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = state.group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        update_cursor(buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = state.group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        M.refresh(buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = state.group,
    buffer = buf,
    callback = function()
      schedule_refresh(buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufReadPost", "BufWritePost" }, {
    group = state.group,
    buffer = buf,
    callback = function()
      if state.enabled and not vim.api.nvim_get_mode().mode:match("^i") then
        M.refresh(buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.group,
    buffer = buf,
    callback = function()
      M.detach(buf)
    end,
  })

  M.refresh(buf)
end

function M.suspend(buf)
  buf = current_buf(buf)
  local state = states[buf]
  if state then
    state.enabled = false
    state.generation = state.generation + 1
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    restore_conceallevel(state)
  end
end

function M.resume(buf)
  buf = current_buf(buf)
  local state = states[buf]
  if state then
    state.enabled = true
  end
  M.attach(buf)
  M.refresh(buf)
end

function M.detach(buf)
  buf = current_buf(buf)
  local state = states[buf]
  if not state then
    return
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  end
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  restore_conceallevel(state)
  states[buf] = nil
end

function M.toggle(buf)
  buf = current_buf(buf)
  M.attach(buf)
  local state = states[buf]
  if not state then
    vim.notify("Mermaid: current buffer is not Markdown", vim.log.levels.WARN)
    return
  end
  state.enabled = not state.enabled
  if state.enabled then
    M.refresh(buf)
  else
    state.generation = state.generation + 1
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    restore_conceallevel(state)
  end
end

function M.show_source(buf)
  buf = current_buf(buf)
  local state = states[buf]
  if not state then
    return
  end
  for _, block in ipairs(state.blocks) do
    clear_block(buf, block)
  end
end

function M.setup()
  M.did_setup = true
end

return M
