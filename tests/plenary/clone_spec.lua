local Path = require("plenary.path")

local clone_module = require("git-download-browse.clone")

local function with_temp_dir(fn)
	local tmp_template = assert(vim.loop.os_tmpdir(), "missing tmpdir") .. "/gdb_clone_XXXXXX"
	local tmp_dir = assert(vim.loop.fs_mkdtemp(tmp_template))
	local ok, err = pcall(fn, tmp_dir)
	Path:new(tmp_dir):rm({ recursive = true })
	if not ok then
		error(err)
	end
end

local function replace(table_ref, key, value)
	local original = table_ref[key]
	table_ref[key] = value
	return function()
		table_ref[key] = original
	end
end

local function assert_equal(actual, expected, msg)
	if actual ~= expected then
		error(msg or string.format("Expected %s but got %s", vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_truthy(value, msg)
	if not value then
		error(msg or "Expected value to be truthy")
	end
end

local function assert_deep_equal(actual, expected, msg)
	local ok = vim.deep_equal(actual, expected)
	if not ok then
		error(msg or string.format("Expected %s but got %s", vim.inspect(expected), vim.inspect(actual)))
	end
end

local tests = {}

local function add_test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

add_test("invokes git clone with expected arguments", function()
	with_temp_dir(function(temp_dir)
		local clone = clone_module.new({
			ensure_repo_root = function()
				return temp_dir
			end,
			normalize_repo_arg = function(arg)
				if arg == "user/repo" then
					return "user", "repo", "https://github.com/user/repo"
				end
				return nil, nil, nil
			end,
			normalize_github_url = function(url)
				return url
			end,
		})

		local restore_executable = replace(vim.fn, "executable", function(bin)
			return bin == "git" and 1 or 0
		end)
		local restore_getreg = replace(vim.fn, "getreg", function()
			return ""
		end)

		local notify_calls = {}
		local restore_notify = replace(vim, "notify", function(...)
			notify_calls[#notify_calls + 1] = { ... }
		end)

		local system_calls = {}
		local restore_system = replace(vim, "system", function(cmd)
			system_calls[#system_calls + 1] = cmd
			Path:new(temp_dir, "user---repo"):mkdir({ parents = true })
			return {
				wait = function()
					return { code = 0, stdout = "", stderr = "" }
				end,
			}
		end)

		clone.clone_repo("user/repo")

		restore_system()
		restore_notify()
		restore_getreg()
		restore_executable()

		assert_equal(#system_calls, 1, "expected git clone to run once")
		assert_deep_equal(system_calls[1], {
			"git",
			"clone",
			"--depth=1",
			"https://github.com/user/repo",
			string.format("%s/%s", temp_dir, "user---repo"),
		})
		assert_truthy(Path:new(temp_dir, "user---repo"):exists())
		assert_deep_equal(notify_calls, {
			{ "Cloning https://github.com/user/repo...", vim.log.levels.INFO },
			{ string.format("Cloned into %s", string.format("%s/%s", temp_dir, "user---repo")), vim.log.levels.INFO },
		})
	end)
end)

add_test("warns when target already exists", function()
	with_temp_dir(function(temp_dir)
		Path:new(temp_dir, "user---repo"):mkdir({ parents = true })
		local clone = clone_module.new({
			ensure_repo_root = function()
				return temp_dir
			end,
			normalize_repo_arg = function(arg)
				if arg == "user/repo" then
					return "user", "repo", "https://github.com/user/repo"
				end
				return nil, nil, nil
			end,
			normalize_github_url = function(url)
				return url
			end,
		})

		local restore_executable = replace(vim.fn, "executable", function(bin)
			return bin == "git" and 1 or 0
		end)
		local system_calls = {}
		local restore_system = replace(vim, "system", function(cmd)
			system_calls[#system_calls + 1] = cmd
			return {
				wait = function()
					return { code = 0, stdout = "", stderr = "" }
				end,
			}
		end)
		local notify_calls = {}
		local restore_notify = replace(vim, "notify", function(...)
			notify_calls[#notify_calls + 1] = { ... }
		end)

		clone.clone_repo("user/repo")

		restore_notify()
		restore_system()
		restore_executable()

		assert_equal(#system_calls, 0)
		assert_deep_equal(notify_calls, {
			{ string.format("%s already exists", string.format("%s/%s", temp_dir, "user---repo")), vim.log.levels.WARN },
		})
	end)
end)

add_test("reports git errors", function()
	with_temp_dir(function(temp_dir)
		local clone = clone_module.new({
			ensure_repo_root = function()
				return temp_dir
			end,
			normalize_repo_arg = function(arg)
				if arg == "user/repo" then
					return "user", "repo", "https://github.com/user/repo"
				end
				return nil, nil, nil
			end,
			normalize_github_url = function(url)
				return url
			end,
		})

		local restore_executable = replace(vim.fn, "executable", function(bin)
			return bin == "git" and 1 or 0
		end)
		local restore_getreg = replace(vim.fn, "getreg", function()
			return ""
		end)
		local notify_calls = {}
		local restore_notify = replace(vim, "notify", function(...)
			notify_calls[#notify_calls + 1] = { ... }
		end)
		local restore_system = replace(vim, "system", function()
			return {
				wait = function()
					return { code = 1, stdout = "", stderr = "git clone failed" }
				end,
			}
		end)

		clone.clone_repo("user/repo")

		restore_system()
		restore_notify()
		restore_getreg()
		restore_executable()

		assert_deep_equal(notify_calls, {
			{ "Cloning https://github.com/user/repo...", vim.log.levels.INFO },
			{ "git clone failed", vim.log.levels.ERROR },
		})
	end)
end)

return tests
