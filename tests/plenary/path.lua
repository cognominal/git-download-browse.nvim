local Path = {}
Path.__index = Path

local function join_segments(segments)
	local parts = {}
	for _, piece in ipairs(segments) do
		if type(piece) == "string" and piece ~= "" then
			local normalized = piece:gsub("/$", "")
			normalized = normalized:gsub("^%./", "")
			table.insert(parts, normalized)
		end
	end
	local joined = table.concat(parts, "/")
	if joined == "" then
		joined = segments[#segments] or ""
	end
	return joined
end

function Path:new(...)
	local segments = { ... }
	local path
	if #segments == 1 and type(segments[1]) == "string" then
		path = segments[1]
	else
		path = join_segments(segments)
	end
	local expanded = vim.fn.fnamemodify(path, ":p")
	return setmetatable({ _path = expanded }, self)
end

function Path:absolute()
	return vim.fn.fnamemodify(self._path, ":p")
end

function Path:exists()
	local stat = vim.loop.fs_stat(self._path)
	return stat ~= nil
end

function Path:mkdir(opts)
	local flags = opts and opts.parents and "p" or ""
	vim.fn.mkdir(self._path, flags)
	return self
end

function Path:rm(opts)
	local flags = opts and opts.recursive and "rf" or ""
	vim.fn.delete(self._path, flags)
end

function Path:read()
	return table.concat(self:readlines(), "\n")
end

function Path:readlines()
	if not self:exists() then
		return {}
	end
	return vim.fn.readfile(self._path)
end

return Path
