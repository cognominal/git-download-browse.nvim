local Path = require("plenary.path")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local utils = require("telescope.utils")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local Browse = {}

---@param deps table
---@param deps.ensure_repo_root fun(): string
---@param deps.detect_repo_language fun(string): string?
---@param deps.fork table
function Browse.new(deps)
	local ensure_repo_root = assert(deps.ensure_repo_root, "ensure_repo_root dependency is required")
	local detect_repo_language = assert(deps.detect_repo_language, "detect_repo_language dependency is required")
	local fork = assert(deps.fork, "fork dependency is required")

	local M = {}

	local function pad_label(label)
		return string.format("%-6s", label or "")
	end

	local function pad_depth(depth)
		return string.format("%6s", depth or "")
	end

	local function repo_clone_depth(repo_path)
		if vim.fn.executable("git") == 0 then
			return "?"
		end

		local ok, output = pcall(utils.get_os_command_output, {
			"git",
			"-C",
			repo_path,
			"rev-list",
			"--count",
			"HEAD",
		})

		if not ok or not output or not output[1] then
			return "?"
		end

		local depth = tonumber(output[1])
		if not depth then
			return "?"
		end

		return tostring(depth)
	end

	local function collect_repos()
		local entries = {}
		local root = ensure_repo_root()
		local fs = vim.loop.fs_scandir(root)
		if not fs then
			return entries
		end

		while true do
			local name, typ = vim.loop.fs_scandir_next(fs)
			if not name then
				break
			end
			if typ == "directory" then
				local repo_path = Path:new(root, name):absolute()
				local label = detect_repo_language(repo_path)
				local depth = repo_clone_depth(repo_path)
				local forked = fork.has_fork(repo_path)
				local display = string.format("%s %s %s %s", fork.marker(forked), pad_label(label), pad_depth(depth), name)
				table.insert(entries, {
					value = name,
					display = display,
					ordinal = name,
					path = repo_path,
					forked = forked,
				})
			end
		end

		table.sort(entries, function(a, b)
			return a.display:lower() < b.display:lower()
		end)

		return entries
	end

	local function repo_previewer()
		return previewers.new_buffer_previewer({
			get_buffer_by_name = function(_, entry)
				return entry.path
			end,
			define_preview = function(self, entry)
				local readme = Path:new(entry.path, "README.md")
				if readme:exists() then
					local lines = readme:readlines()
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				else
					local output = utils.get_os_command_output({ "ls", "-a", entry.path })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, output)
					vim.bo[self.state.bufnr].filetype = "sh"
				end
			end,
		})
	end

	function M.open_picker(opts)
		opts = opts or {}
		local entries = collect_repos()
		pickers
			.new(opts, {
				prompt_title = "Git Repos",
				finder = finders.new_table({
					results = entries,
					entry_maker = function(entry)
						return entry
					end,
				}),
				sorter = conf.generic_sorter(opts),
				previewer = repo_previewer(),
				attach_mappings = function(prompt_bufnr, _)
					actions.select_default:replace(function()
						actions.close(prompt_bufnr)
						local selection = action_state.get_selected_entry()
						if selection and selection.path then
							local escaped = vim.fn.fnameescape(selection.path)
							vim.cmd("lcd " .. escaped)
							vim.cmd("edit " .. escaped)
						end
					end)
					return true
				end,
			})
			:find()
	end

	return M
end

return Browse
