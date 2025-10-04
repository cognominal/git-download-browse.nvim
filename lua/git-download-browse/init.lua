local M = {}

local v = vim.version()
if v.major ~= 0 or v.minor < 11 then
  vim.notify("git-download-browse not supported on nvim version < 0.11")
end

local Path = require("plenary.path")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local utils = require("telescope.utils")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")



local DEFAULT_CONFIG = {
	repo_root = vim.fn.expand("~/git"),
	forked_dir = vim.fn.expand("~/forked"),
	keymaps = {
		toggle = "<leader>gv",
	},
}

M.defaults = vim.deepcopy(DEFAULT_CONFIG)
M.options = vim.deepcopy(DEFAULT_CONFIG)

local active_keymaps = {}

local language_root_files = {
	{ label = "js/ts", filename = { "package.json", "tsconfig.json" } },
	{ label = "python", filename = { "pyproject.toml", "requirements.txt", "setup.cfg" } },
	{ label = "ruby", filename = "Gemfile" },
	{ label = "rust", filename = "Cargo.toml" },
	{ label = "lua", filename = { "init.lua", "lua" } },
	{ label = "elixir", filename = "mix.exs" },
	{ label = "php", filename = "composer.json" },
	{ label = "java", filename = { "pom.xml", "build.gradle", "build.gradle.kts" } },
	{ label = "csharp", filename = { "*.csproj", "*.sln" } },
	{ label = "haskell", filename = { "package.yaml", "cabal.project" } },
	{ label = "cpp", filename = { "CMakeLists.txt", "Makefile" } },
	{ label = "perl", filename = "Makefile.PL" },
	{ label = "raku", filename = "META6.json" },
	{ label = "go", filename = { "go.mod", "Taskfile.yaml" } },
}

local function candidate_exists(repo_path, candidate_name)
	local candidate = Path:new(repo_path, candidate_name)
	local candidate_path = candidate:absolute()

	if candidate_name:find("[%*%?%[]") then
		local matches = vim.fn.glob(candidate_path)
		return type(matches) == "string" and matches ~= ""
	end

	return candidate:exists()
end

local function detect_repo_language(repo_path)
	for _, item in ipairs(language_root_files) do
		local filenames = item.filenames or item.filename
		if type(filenames) == "string" then
			filenames = { filenames }
		end

		if type(filenames) == "table" then
			for _, candidate_name in ipairs(filenames) do
				if candidate_exists(repo_path, candidate_name) then
					return item.label
				end
			end
		end
	end
	return nil
end

local function normalize_repo_arg(arg)
	if type(arg) ~= "string" or arg == "" then
		return nil, nil, nil
	end

	local user, repo = arg:match("^https://github.com/([^/]+)/([^/]+)%.git/?$")
	if not user then
		user, repo = arg:match("^https://github.com/([^/]+)/([^/]+)/?$")
	end

	if not user then
		user, repo = arg:match("^([^/]+)/([^/]+)%.git$")
		if user and repo then
			arg = string.format("https://github.com/%s/%s", user, repo)
		end
	end

	if not user then
		user, repo = arg:match("^([^/]+)/([^/]+)$")
		if user and repo then
			arg = string.format("https://github.com/%s/%s", user, repo)
		end
	end

	if repo and repo:sub(-4) == ".git" then
		repo = repo:sub(1, -5)
	end

	if user and repo then
		return user, repo, string.format("https://github.com/%s/%s", user, repo)
	end

	return nil, nil, nil
end

local function ensure_repo_root()
	local root = M.options.repo_root
	if vim.fn.isdirectory(root) == 0 then
		vim.fn.mkdir(root, "p")
	end
	return root
end

local function read_json_file(path)
	local file = Path:new(path)
	if not file:exists() then
		return nil, string.format("%s does not exist", path)
	end

	local ok, contents = pcall(function()
		return file:read()
	end)
	if not ok then
		return nil, string.format("Failed to read %s: %s", path, contents)
	end

	if contents == "" then
		return nil, string.format("%s is empty", path)
	end

	local ok_decode, decoded = pcall(vim.json.decode or vim.fn.json_decode, contents)
	if not ok_decode then
		return nil, string.format("Failed to decode %s: %s", path, decoded)
	end

	return decoded, nil
end

local function collect_dependency_names(tbl)
	local names = {}
	if type(tbl) ~= "table" then
		return names
	end

	for name, _ in pairs(tbl) do
		table.insert(names, name)
	end

	table.sort(names)
	return names
end

---Extract dependency names from a package.json file.
---@param package_json_path? string Absolute or relative path. Defaults to cwd/package.json.
---@return string[] dependencies List of package names.
---@return string? err Error message if parsing failed.
function M.package_names_from_package_json(package_json_path)
	local path = package_json_path or "package.json"
	local decoded, err = read_json_file(path)
	if not decoded then
		return {}, err
	end

	local names = {}
	local seen = {}
	for _, section in ipairs({ decoded.dependencies, decoded.devDependencies }) do
		for _, name in ipairs(collect_dependency_names(section)) do
			if not seen[name] then
				table.insert(names, name)
				seen[name] = true
			end
		end
	end

	table.sort(names)
	return names, nil
end

local function normalize_github_url(url)
	if type(url) ~= "string" or url == "" then
		return nil
	end

	url = url:gsub("^git%+", "")

	if url:match("^git@github.com:") then
		local without_prefix = url:gsub("^git@github.com:", "")
		without_prefix = without_prefix:gsub("%.git$", "")
		return string.format("https://github.com/%s", without_prefix)
	end

	if url:match("^github:") then
		local without_prefix = url:gsub("^github:", "")
		without_prefix = without_prefix:gsub("%.git$", "")
		return string.format("https://github.com/%s", without_prefix)
	end

	if url:match("^git://github.com/") then
		url = url:gsub("^git://", "https://")
	end

	url = url:gsub("%.git$", "")

	if url:match("^https?://github.com/") then
		return url
	end

	return nil
end

---Resolve a package name to a GitHub repository URL via npm metadata.
---@param package_name string
---@return string? url GitHub URL (https) if found.
---@return string? err Error description when resolution fails.
function M.package_name_to_github_url(package_name)
	if type(package_name) ~= "string" or package_name == "" then
		return nil, "Package name must be a non-empty string"
	end

	if vim.fn.executable("npm") == 0 then
		return nil, "npm is not available"
	end

	local result = vim.fn.system({ "npm", "view", package_name, "repository", "--json" })
	if vim.v.shell_error ~= 0 then
		local output = vim.trim(result)
		if output == "" then
			output = string.format("npm view %s failed", package_name)
		end
		return nil, output
	end

	local ok, decoded = pcall(vim.json.decode or vim.fn.json_decode, result)
	local url

	if ok then
		if type(decoded) == "string" then
			url = normalize_github_url(decoded)
		elseif type(decoded) == "table" then
			if decoded.url then
				url = normalize_github_url(decoded.url)
			elseif decoded.path then
				url = normalize_github_url(decoded.path)
			end

			if not url and decoded.type == "git" and decoded.directory and decoded.user then
				url = normalize_github_url(string.format("https://github.com/%s/%s", decoded.user, decoded.directory))
			end
		end
	else
		url = normalize_github_url(vim.trim(result))
	end

	if url then
		return url, nil
	end

	return nil, string.format("Could not determine GitHub URL for %s", package_name)
end

function M.download_repo(arg)
	if not arg or arg == "" then
		local clipboard = vim.fn.getreg("+")
		if clipboard == "" then
			clipboard = vim.fn.getreg("*")
		end
		if clipboard and clipboard ~= "" then
			local trim = vim.trim or vim.fn.trim
			arg = trim(clipboard)
		else
			vim.notify("No repository provided and clipboard is empty", vim.log.levels.ERROR)
			return
		end
	end

	local trim = vim.trim or vim.fn.trim
	arg = trim(arg)
	local user, repo, url = normalize_repo_arg(arg)
	if not user then
		vim.notify("Invalid repository. Use https://github.com/user/repo or user/repo", vim.log.levels.ERROR)
		return
	end

	if vim.fn.executable("git") == 0 then
		vim.notify("git is not available", vim.log.levels.ERROR)
		return
	end

	local root = ensure_repo_root()
	local target = string.format("%s/%s---%s", root, user, repo)

	if vim.fn.isdirectory(target) == 1 then
		vim.notify(string.format("%s already exists", target), vim.log.levels.WARN)
		return
	end

	vim.notify(string.format("Cloning %s...", url), vim.log.levels.INFO)
	local result = vim.fn.system({ "git", "clone", "--depth=1", url, target })
	if vim.v.shell_error == 0 then
		vim.notify(string.format("Cloned into %s", target), vim.log.levels.INFO)
	else
		vim.notify(result ~= "" and result or "git clone failed", vim.log.levels.ERROR)
	end
end

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
			local display = string.format("%s %s %s", pad_label(label), pad_depth(depth), name)
			table.insert(entries, {
				value = name,
				display = display,
				ordinal = name,
				path = repo_path,
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

local function set_keymaps()
	for _, value in pairs(active_keymaps) do
		local rhs = value.key
		if rhs and rhs ~= "" then
			pcall(vim.keymap.del, value.mode or "n", rhs)
		end
	end
	active_keymaps = {}

	local mappings = M.options.keymaps
	if type(mappings) ~= "table" then
		return
	end

	local toggle = mappings.toggle
	if toggle and toggle ~= "" then
		vim.keymap.set("n", toggle, M.open_picker, {
			desc = "Git download browser",
			silent = true,
		})
		active_keymaps.toggle = { key = toggle, mode = "n" }
	end
end

function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), opts)

	-- Ensure the configured repository root exists ahead of time so later
	-- commands can assume it is available.
	ensure_repo_root()

	pcall(vim.api.nvim_del_user_command, "DownloadGitRepo")
	pcall(vim.api.nvim_del_user_command, "GitRepos")

	vim.api.nvim_create_user_command("DownloadGitRepo", function(params)
		M.download_repo(params.args)
	end, {
		nargs = "?",
		complete = function()
			return {}
		end,
	})

	vim.api.nvim_create_user_command("GitRepos", function()
		M.open_picker()
	end, {})

	set_keymaps()
end

function M.config(_, opts)
	M.setup(opts)
end

return M
