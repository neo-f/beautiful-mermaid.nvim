local M = {}
local AsciiPreview = require("beautiful-mermaid.preview")

function M.attach(buf)
  AsciiPreview.attach(buf)
end

function M.detach(buf)
  AsciiPreview.detach(buf)
end

function M.toggle(buf)
  AsciiPreview.toggle(buf)
end

function M.refresh(buf, force)
  AsciiPreview.refresh(buf, force)
end

function M.setup()
  if M.did_setup then
    return
  end
  M.did_setup = true
  AsciiPreview.setup()
  local group = vim.api.nvim_create_augroup("beautiful-mermaid.setup", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(event)
      M.attach(event.buf)
    end,
  })
  vim.api.nvim_create_user_command("MermaidPreview", function()
    M.toggle(0)
  end, { desc = "Toggle Mermaid preview" })
  vim.api.nvim_create_user_command("MermaidRefresh", function()
    M.refresh(0, true)
  end, { desc = "Clear cache and render Mermaid diagrams" })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
      M.attach(buf)
    end
  end
end

return M
