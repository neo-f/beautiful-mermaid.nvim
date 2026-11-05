local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

coroutine.yield("Installing Mermaid renderer")
local result = vim.system({
  "npm",
  "ci",
  "--prefix",
  "tools/mermaid",
  "--ignore-scripts",
  "--no-audit",
  "--no-fund",
}, { cwd = dir, text = true }):wait()

assert(result.code == 0, result.stderr)
coroutine.yield(result.stderr)
