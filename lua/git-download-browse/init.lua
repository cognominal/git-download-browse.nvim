local M = {}

local v = vim.version()
if v.major ~= 0 or v.minor < 11 then
  vim.notify("git-download-browse not supported on nvim version < 0.11")
end

local Path = require("plenary.path")



local DEFAULT_CONFIG = {
	reposDir = vim.fn.expand("~/git"),
	forked_dir = vim.fn.expand("~/forked"),
	keymaps = {
		browse = "<leader>gv",
		clone = "<leader>gc",
		fork = "<leader>gk",
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

local function ensure_repo_root()
	local root = M.options.reposDir
	if vim.fn.isdirectory(root) == 0 then
		vim.fn.mkdir(root, "p")
	end
	return root
end

local fork_module = require("git-download-browse.fork")
local fork = fork_module.new({
	get_options = function()
		return M.options
	end,
	ensure_repo_root = ensure_repo_root,
	normalize_repo_arg = normalize_repo_arg,
	normalize_github_url = normalize_github_url,
})

local clone_module = require("git-download-browse.clone")
local clone = clone_module.new({
	ensure_repo_root = ensure_repo_root,
	normalize_repo_arg = normalize_repo_arg,
	normalize_github_url = normalize_github_url,
})

local browse_module = require("git-download-browse.browse")
local browse = browse_module.new({
	ensure_repo_root = ensure_repo_root,
	detect_repo_language = detect_repo_language,
	fork = fork,
})

M.package_names_from_package_json = clone.package_names_from_package_json
M.package_name_to_github_url = clone.package_name_to_github_url

function M.clone_repo(arg)
	clone.clone_repo(arg)
end

function M.fork_repo(arg)
	fork.fork_repo(arg)
end

function M.open_picker(opts)
	browse.open_picker(opts)
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

	local browse = mappings.browse
	if browse and browse ~= "" then
		vim.keymap.set("n", browse, M.open_picker, {
			desc = "Git download browser",
			silent = true,
		})
		active_keymaps.browse = { key = browse, mode = "n" }
	end

	local clone = mappings.clone
	if clone and clone ~= "" then
		vim.keymap.set("n", clone, function()
			M.clone_repo()
		end, {
			desc = "Clone GitHub repo",
			silent = true,
		})
		active_keymaps.clone = { key = clone, mode = "n" }
	end

	local fork = mappings.fork
	if fork and fork ~= "" then
		vim.keymap.set("n", fork, function()
			M.fork_repo()
		end, {
			desc = "Fork current repo",
			silent = true,
		})
		active_keymaps.fork = { key = fork, mode = "n" }
	end
end

function M.setup(opts)
	opts = opts or {}
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULT_CONFIG), opts)

	-- Ensure the configured repository root exists ahead of time so later
	-- commands can assume it is available.
	ensure_repo_root()

	pcall(vim.api.nvim_del_user_command, "DownloadGitRepo")
	pcall(vim.api.nvim_del_user_command, "CloneGitRepo")
	pcall(vim.api.nvim_del_user_command, "GitRepos")
	pcall(vim.api.nvim_del_user_command, "GitFork")

	vim.api.nvim_create_user_command("CloneGitRepo", function(params)
		M.clone_repo(params.args)
	end, {
		nargs = "?",
		complete = function()
			return {}
		end,
	})

	vim.api.nvim_create_user_command("GitRepos", function()
		M.open_picker()
	end, {})

	vim.api.nvim_create_user_command("GitFork", function(params)
		M.fork_repo(params.args)
	end, {
		nargs = "?",
	})

	set_keymaps()
end

function M.config(_, opts)
	M.setup(opts)
end

return M
