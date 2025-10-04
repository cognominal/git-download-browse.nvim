vim.g.loaded_git_download_browse = true

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local project_root = vim.fn.fnamemodify(config_dir, ":h")

package.path = table.concat({
	string.format("%s/?.lua", project_root),
	string.format("%s/?/init.lua", project_root),
	string.format("%s/?.lua", config_dir),
	string.format("%s/?/init.lua", config_dir),
	package.path,
}, ";")

package.cpath = table.concat({
	package.cpath,
}, ";")

vim.opt.runtimepath:append(project_root)
vim.opt.runtimepath:append(config_dir)
