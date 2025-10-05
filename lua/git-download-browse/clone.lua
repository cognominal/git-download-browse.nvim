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

	local repo_resolvers = {
		{
			lang = "js/ts",
			file = "package.json",
			action = function()
				local dependency_name = dependency_name_under_cursor()
				if not dependency_name then
					return nil, nil
				end

				vim.notify(string.format("Detected package.json dependency %s", dependency_name), vim.log.levels.INFO)
				local resolved_url, resolve_err = M.package_name_to_github_url(dependency_name)
				if not resolved_url then
					return nil, resolve_err or string.format("Could not resolve %s to a GitHub repository", dependency_name)
				end

				return resolved_url, nil
			end,
		},
	}

	local function prompt_for_repo_input(on_submit)
		local ok_input, Input = pcall(require, "nui.input")
		if not ok_input then
			vim.notify("nui.nvim is required to provide manual repository input", vim.log.levels.ERROR)
			on_submit(nil)
			return
		end

		local ok_utils, autocmd = pcall(require, "nui.utils.autocmd")
		if not ok_utils then
			vim.notify("nui.utils.autocmd is required to manage popup lifecycle", vim.log.levels.ERROR)
			on_submit(nil)
			return
		end

		local event = autocmd.event

		local message = "Use https://github.com/user/repo or user/repo"
		local popup_width = math.max(#message + 8, 60)
		local input_popup
		local completed = false

		local function finish(value)
			if completed then
				return
			end
			completed = true
			if input_popup then
				input_popup:unmount()
			end
			on_submit(value)
		end
		input_popup = Input(
			{
				position = "50%",
				size = {
					width = popup_width,
				},
				border = {
					style = "rounded",
					text = {
						top = message,
						top_align = "center",
					},
				},
				win_options = {
					winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
				},
			},
			{
				prompt = "repo> ",
				on_submit = finish,
				on_close = function()
					finish(nil)
				end,
			}
		)

		input_popup:mount()

		input_popup:on(event.BufLeave, function()
			vim.schedule(function()
				if completed then
					return
				end
				finish(nil)
			end)
		end)

		for _, mode in ipairs({ "n", "i" }) do
			input_popup:map(mode, "<Esc>", function()
				finish(nil)
			end, { nowait = true, noremap = true, silent = true })
		end

		vim.schedule(function()
			if vim.api.nvim_get_current_buf() == input_popup.bufnr then
				vim.cmd("startinsert")
			end
		end)
	end

	local function resolve_repo_from_context()
		local current_path = vim.api.nvim_buf_get_name(0)
		local current_filename = current_path ~= "" and vim.fn.fnamemodify(current_path, ":t") or nil

		for _, resolver in ipairs(repo_resolvers) do
			local resolver_path = Path:new(resolver.file)
			if resolver_path:exists() then
				if current_filename and current_filename == vim.fn.fnamemodify(resolver.file, ":t") then
					local ok, result, err = pcall(resolver.action)
					if not ok then
						return nil, string.format("Failed to execute resolver for %s: %s", resolver.file, result), { source = "resolver", resolver = resolver }
					end
					if result then
						return result, nil, { source = "resolver", resolver = resolver }
					end
					if err then
						return nil, err, { source = "resolver", resolver = resolver }
					end
				end
				break
			end
		end

		return nil, nil, nil
	end

	local function confirm_clone(context, on_done)
		on_done = on_done or function() end
		local ok_popup, Popup = pcall(require, "nui.popup")
		if not ok_popup then
			vim.notify("nui.nvim is required to confirm clone – proceeding without confirmation", vim.log.levels.WARN)
			on_done(true)
			return
		end

		local ok_utils, autocmd = pcall(require, "nui.utils.autocmd")
		if not ok_utils then
			vim.notify("nui.utils.autocmd is required to confirm clone – proceeding without confirmation", vim.log.levels.WARN)
			on_done(true)
			return
		end

		local function source_label()
			if context.source == "clipboard" then
				return "Clipboard content"
			end
			if context.source == "manual" then
				return "Manual input"
			end
			if context.source == "argument" then
				return "Command argument"
			end
			if context.source == "resolver" then
				local resolver = context.resolver
				if resolver and resolver.file then
					local filename = vim.fn.fnamemodify(resolver.file, ":t")
					return string.format("Detected from %s", filename)
				end
				return "Detected from current file"
			end
			return "Unknown source"
		end

		local repo_display = string.format("%s/%s", context.user, context.repo)
		local lines = {
			string.format("Repository: %s", repo_display),
			string.format("Source: %s", source_label()),
			string.format("URL: %s", context.url),
			"",
			"Press y/Enter to confirm or n/Esc to cancel.",
		}

		local max_line = 0
		for _, line in ipairs(lines) do
			if #line > max_line then
				max_line = #line
			end
		end

		local popup_width = math.max(60, max_line + 4)
		local popup_height = #lines + 2

		local popup = Popup({
			position = "50%",
			size = {
				width = popup_width,
				height = popup_height,
			},
			enter = true,
			focusable = true,
			border = {
				style = "rounded",
				text = {
					top = "Confirm Clone",
					top_align = "center",
				},
			},
			win_options = {
				winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
			},
		})

		local completed = false
		local function finish(confirmed)
			if completed then
				return
			end
			completed = true
			popup:unmount()
			on_done(confirmed)
		end

		popup:mount()

		vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)

		local event = autocmd.event
		popup:on(event.BufLeave, function()
			vim.schedule(function()
				if completed then
					return
				end
				finish(false)
			end)
		end)

		local mappings = {
			{ mode = "n", key = "y", handler = function()
				finish(true)
			end },
			{ mode = "n", key = "<CR>", handler = function()
				finish(true)
			end },
			{ mode = "n", key = "n", handler = function()
				finish(false)
			end },
			{ mode = "n", key = "<Esc>", handler = function()
				finish(false)
			end },
		}

		for _, mapping in ipairs(mappings) do
			popup:map(mapping.mode, mapping.key, function()
				mapping.handler()
			end, { nowait = true, noremap = true, silent = true })
		end
	end

	local function continue_clone(repo_arg, opts)
		opts = opts or {}
		local trim = vim.trim or vim.fn.trim
		repo_arg = trim(repo_arg or "")
		if repo_arg == "" then
			vim.notify("Repository argument is empty", vim.log.levels.ERROR)
			return
		end

		local parsed = opts.parsed
		local user, repo, url
		if parsed and parsed.user and parsed.repo and parsed.url then
			user, repo, url = parsed.user, parsed.repo, parsed.url
		else
			user, repo, url = normalize_repo_arg(repo_arg)
		end
		if not user then
			vim.notify("Invalid repository. Use https://github.com/user/repo or user/repo", vim.log.levels.ERROR)
			return
		end

		if vim.fn.executable("git") == 0 then
			vim.notify("git is not available", vim.log.levels.ERROR)
			return
		end

		local function perform_clone()
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

		confirm_clone({
			user = user,
			repo = repo,
			url = url,
			source = opts.source,
			resolver = opts.resolver,
		}, function(confirmed)
			if not confirmed then
				vim.notify("Clone cancelled", vim.log.levels.WARN)
				return
			end
			perform_clone()
		end)
	end

	function M.clone_repo(arg)
		if arg and arg ~= "" then
			continue_clone(arg, { source = "argument" })
			return
		end

		local resolved_repo, resolve_err, resolve_meta = resolve_repo_from_context()
		if resolved_repo then
			continue_clone(resolved_repo, {
				source = resolve_meta and resolve_meta.source or "resolver",
				resolver = resolve_meta and resolve_meta.resolver or nil,
			})
			return
		end

		if resolve_err then
			vim.notify(resolve_err, vim.log.levels.ERROR)
		end

		local function prompt_manual(reason_level, reason_msg)
			if reason_msg then
				vim.notify(reason_msg, reason_level or vim.log.levels.WARN)
			end

			prompt_for_repo_input(function(manual_value)
				local trim = vim.trim or vim.fn.trim
				manual_value = trim(manual_value or "")
				if manual_value == "" then
					vim.notify("Clone cancelled: no repository provided", vim.log.levels.WARN)
					return
				end
				continue_clone(manual_value, { source = "manual" })
			end)
		end

		local clipboard = vim.fn.getreg("+")
		if clipboard == "" then
			clipboard = vim.fn.getreg("*")
		end

		local trim = vim.trim or vim.fn.trim
		clipboard = trim(clipboard or "")

		if clipboard == "" then
			prompt_manual(vim.log.levels.WARN, "Clipboard is empty – enter repository manually")
			return
		end

		local user, repo, url = normalize_repo_arg(clipboard)
		if not user then
			prompt_manual(vim.log.levels.WARN, "Clipboard content is not a valid repository – enter one manually")
			return
		end

		continue_clone(clipboard, {
			source = "clipboard",
			parsed = {
				user = user,
				repo = repo,
				url = url,
			},
		})
	end

	return M
end

return Clone
