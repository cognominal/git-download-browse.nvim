--[[-
Provides helpers for GitHub fork workflows:
- detects whether a cloned repo already has a `fork` remote
- resolves repository paths from cwd, filesystem paths, or user/repo slugs
- creates fork remotes/worktrees via `gh repo fork` and `git worktree add`
]]

local Path = require("plenary.path")

local Fork = {}

---@param deps table
---@param deps.get_options fun(): table
---@param deps.ensure_repo_root fun(): string
---@param deps.normalize_repo_arg fun(string): (string?, string?, string?)
---@param deps.normalize_github_url fun(string): string?
function Fork.new(deps)
	local M = {}

	local get_options = assert(deps.get_options, "get_options dependency is required")
	local ensure_repo_root = assert(deps.ensure_repo_root, "ensure_repo_root dependency is required")
	local normalize_repo_arg = assert(deps.normalize_repo_arg, "normalize_repo_arg dependency is required")
	local normalize_github_url = assert(deps.normalize_github_url, "normalize_github_url dependency is required")

	local function options()
		return get_options()
	end

	local function ensure_fork_root()
		local root = options().forked_dir
		if vim.fn.isdirectory(root) == 0 then
			vim.fn.mkdir(root, "p")
		end
		return root
	end

	local function run_command(cmd, cwd)
		local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
		local stdout = vim.split(result.stdout or "", "\n", { trimempty = true })
		local stderr = vim.split(result.stderr or "", "\n", { trimempty = true })
		return result.code, stdout, stderr
	end

	local function git_remote_url(repo_path, remote)
		local code, stdout = run_command({ "git", "remote", "get-url", remote }, repo_path)
		if code ~= 0 or not stdout[1] or stdout[1] == "" then
			return nil
		end
		return stdout[1]
	end

	local function git_remote_exists(repo_path, remote)
		return git_remote_url(repo_path, remote) ~= nil
	end

	local function branch_exists(repo_path, branch)
		local ref = string.format("refs/heads/%s", branch)
		local code = run_command({ "git", "rev-parse", "--verify", ref }, repo_path)
		return code == 0
	end

	local function next_fork_branch(repo_path)
		local base = "forked"
		local idx = 0
		while true do
			local candidate = idx == 0 and base or string.format("%s%d", base, idx)
			if not branch_exists(repo_path, candidate) then
				return candidate
			end
			idx = idx + 1
		end
	end

	local function next_worktree_path(repo_path, branch)
		local fork_root = ensure_fork_root()
		local repo_dirname = vim.fs.basename(repo_path)
		local base_name = string.format("%s-%s", repo_dirname, branch)
		local candidate = Path:new(fork_root, base_name)
		local suffix = 0
		while candidate:exists() do
			suffix = suffix + 1
			candidate = Path:new(fork_root, string.format("%s-%s-%d", repo_dirname, branch, suffix))
		end
		return candidate:absolute()
	end

	local function repo_has_fork(repo_path)
		return git_remote_exists(repo_path, "fork")
	end

	local function lines_to_message(lines)
		return table.concat(lines or {}, "\n")
	end

	local function find_git_root(path)
		local resolved = Path:new(path):absolute()
		local git_path = Path:new(resolved, ".git")
		if git_path:exists() then
			return resolved
		end

		local candidates = vim.fs.find(".git", { path = resolved, upward = true, limit = 1 })
		if candidates and candidates[1] then
			local parent = vim.fn.fnamemodify(candidates[1], ":h")
			return Path:new(parent):absolute()
		end

		return nil
	end

	local function resolve_repo_path(arg)
		local resolved
		if arg and arg ~= "" then
			resolved = vim.fn.expand(arg)
			if resolved ~= "" and vim.fn.isdirectory(resolved) == 1 then
				resolved = find_git_root(resolved)
			else
				local user, repo = normalize_repo_arg(arg)
				if not user then
					local normalized = normalize_github_url(arg)
					if normalized then
						user, repo = normalize_repo_arg(normalized)
					end
				end
				if user and repo then
					local candidate = Path:new(ensure_repo_root(), string.format("%s---%s", user, repo))
					if candidate:exists() then
						resolved = candidate:absolute()
					end
				end
			end
		else
			resolved = find_git_root(vim.fn.getcwd())
		end

		if not resolved or resolved == "" then
			vim.notify("Unable to determine repository path", vim.log.levels.ERROR)
			return nil
		end

		return Path:new(resolved):absolute()
	end

	local function fork_repo(arg)
		if vim.fn.executable("git") == 0 then
			vim.notify("git is not available", vim.log.levels.ERROR)
			return
		end

		if vim.fn.executable("gh") == 0 then
			vim.notify("gh command is required to fork repositories", vim.log.levels.ERROR)
			return
		end

		local repo_path = resolve_repo_path(arg)
		if not repo_path then
			return
		end

		local origin_url = git_remote_url(repo_path, "origin")
		if not origin_url then
			vim.notify("Repository does not have an origin remote", vim.log.levels.ERROR)
			return
		end

		local normalized_origin = normalize_github_url(origin_url) or origin_url
		local user, repo = normalize_repo_arg(normalized_origin)
		if not user or not repo then
			vim.notify("Unable to parse origin remote for forking", vim.log.levels.ERROR)
			return
		end

		local slug = string.format("%s/%s", user, repo)

		if not repo_has_fork(repo_path) then
			local code, _, stderr = run_command({
				"gh",
				"repo",
				"fork",
				slug,
				"--clone=false",
				"--remote",
				"--remote-name",
				"fork",
			}, repo_path)
			if code ~= 0 then
				local message = lines_to_message(stderr)
				vim.notify(message ~= "" and message or "gh repo fork failed", vim.log.levels.ERROR)
				return
			end
			vim.notify(string.format("Fork remote added for %s", slug), vim.log.levels.INFO)
		end

		local branch = next_fork_branch(repo_path)
		local worktree_path = next_worktree_path(repo_path, branch)
		local code, _, stderr = run_command({
			"git",
			"worktree",
			"add",
			"-b",
			branch,
			worktree_path,
		}, repo_path)
		if code ~= 0 then
			local message = lines_to_message(stderr)
			vim.notify(message ~= "" and message or "Failed to create worktree", vim.log.levels.ERROR)
			return
		end
		vim.notify(string.format("Created worktree %s for branch %s", worktree_path, branch), vim.log.levels.INFO)

		local push_code, _, push_err = run_command({
			"git",
			"push",
			"--set-upstream",
			"fork",
			branch,
		}, worktree_path)
		if push_code == 0 then
			vim.notify(string.format("Pushed %s to fork remote", branch), vim.log.levels.INFO)
		else
			local message = lines_to_message(push_err)
			if message ~= "" then
				vim.notify(message, vim.log.levels.WARN)
			end
		end
	end

	function M.has_fork(repo_path)
		return repo_has_fork(repo_path)
	end

	function M.marker(forked)
		return forked and "F" or " "
	end

	function M.fork_repo(arg)
		fork_repo(arg)
	end

	function M.resolve_repo_path(arg)
		return resolve_repo_path(arg)
	end

	return M
end

return Fork
