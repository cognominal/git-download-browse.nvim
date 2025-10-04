local M = {}

local function write(msg)
	vim.api.nvim_out_write(msg .. "\n")
end

local test_modules = {
	"tests.plenary.clone_spec",
}

function M.run()
	local total = 0
	local failed = 0

	for _, module_name in ipairs(test_modules) do
		local cases = require(module_name)
		for _, case in ipairs(cases) do
			total = total + 1
			local ok, err = pcall(case.fn)
			if ok then
				write(string.format("ok	%s", case.name))
			else
				failed = failed + 1
				write(string.format("not ok\t%s", case.name))
				write(string.format("    %s", err))
			end
		end
	end

	if failed > 0 then
		write(string.format("%d of %d tests failed", failed, total))
		vim.cmd("cq")
	else
		write(string.format("All %d tests passed", total))
		vim.cmd("qa")
	end
end

return M
