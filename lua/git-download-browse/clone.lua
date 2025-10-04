local Path = require("plenary.path")

local Clone = {}

---@param deps table
---@param deps.ensure_repo_root fun(): string
---@param deps.normalize_repo_arg fun(string): (string?, string?, string?)
---@param deps.normalize_github_url fun(string): string?
function Clone.new(deps)
	local ensure_repo_root = assert(deps.ensure_repo_root, "ensure_repo_root dependency is required")
	local normalize_repo_arg = assert(deps.normalize_repo_arg, "normalize_repo_arg dependency is required")
	local normalize_github_url = assert(deps.normalize_github_url, "normalize_github_url dependency is required")

	local M = {}

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

	local function is_package_json_buffer(bufnr)
		local name = vim.api.nvim_buf_get_name(bufnr)
		if name ~= "" then
			return name:sub(-12) == "package.json"
		end
		if vim.fn and vim.fn.expand then
			return vim.fn.expand("%:t") == "package.json"
		end
		return false
	end

	local function decode_package_json_buffer(bufnr)
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		if not lines or #lines == 0 then
			return nil
		end

		local contents = table.concat(lines, "\n")
		if contents == "" then
			return nil
		end

		local decoder = vim.json and vim.json.decode or vim.fn.json_decode
		local ok, decoded = pcall(decoder, contents)
		if not ok or type(decoded) ~= "table" then
			return nil
		end

		return decoded
	end

	local function dependency_name_under_cursor()
		local bufnr = vim.api.nvim_get_current_buf()
		if not is_package_json_buffer(bufnr) then
			return nil
		end

		local cursor = vim.api.nvim_win_get_cursor(0)
		local row = cursor[1]
		local col = cursor[2]
		local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
		if line == "" then
			return nil
		end

		local matches = {}
		local search_start = 1
		while true do
			local key_start, key_match_end, key = line:find('"([^"]+)"%s*:', search_start)
			if not key_start then
				break
			end

			local entry_end = line:find(",", key_match_end + 1, true)
			if not entry_end then
				entry_end = line:find("}", key_match_end + 1, true)
				if not entry_end then
					entry_end = line:find("]", key_match_end + 1, true)
				end
			end
			entry_end = entry_end or (#line + 1)

			table.insert(matches, {
				key = key,
				key_start = key_start,
				entry_end = entry_end,
			})

			search_start = key_match_end + 1
		end

		if #matches == 0 then
			return nil
		end

		local cursor_byte = col + 1
		local selected
		local best_distance = math.huge

		for _, match in ipairs(matches) do
			if cursor_byte >= match.key_start and cursor_byte <= match.entry_end then
				selected = match.key
				break
			end

			local distance
			if cursor_byte < match.key_start then
				distance = match.key_start - cursor_byte
			else
				distance = cursor_byte - match.entry_end
			end

			if distance < best_distance then
				best_distance = distance
				selected = match.key
			end
		end

		if not selected then
			return nil
		end

		local decoded = decode_package_json_buffer(bufnr)
		if not decoded then
			return nil
		end

		if type(decoded.dependencies) == "table" and decoded.dependencies[selected] then
			return selected
		end

		if type(decoded.devDependencies) == "table" and decoded.devDependencies[selected] then
			return selected
		end

		return nil
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

	function M.clone_repo(arg)
		if not arg or arg == "" then
			local dependency_name = dependency_name_under_cursor()
			if dependency_name then
				vim.notify(string.format("Detected package.json dependency %s", dependency_name), vim.log.levels.INFO)
				local resolved_url, resolve_err = M.package_name_to_github_url(dependency_name)
				if not resolved_url then
					vim.notify(resolve_err or string.format("Could not resolve %s to a GitHub repository", dependency_name), vim.log.levels.ERROR)
					return
				end
				arg = resolved_url
			end

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
		local job = vim.system({ "git", "clone", "--depth=1", url, target }, { text = true })
		local result = job:wait()
		if result.code == 0 then
			vim.notify(string.format("Cloned into %s", target), vim.log.levels.INFO)
		else
			local message = vim.trim(result.stderr or result.stdout or "")
			if message == "" then
				message = "git clone failed"
			end
			vim.notify(message, vim.log.levels.ERROR)
		end
	end

	return M
end

return Clone
