if vim.g.loaded_git_download_browse then
	return
end

vim.g.loaded_git_download_browse = true

require("git-download-browse").setup()
