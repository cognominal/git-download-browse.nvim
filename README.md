# git-download-browse.nvim

Work in progress. Browsing works

Browse, clone, fork GitHub repositories from Neovim. The plugin stores clones
in a configurable directory, (default: `~/git` )
offers a shallow clone command, and ships a Telescope
picker with README previews.

The fork commands will add the fork to the clone folder, but also create
a branch named "forked" and a worktree folder in the the worktree folder
(default: `~/forked`). Depends on the `gh` command.

TBD support other git hubs than github

![screenshot](./assets/screenshot.png)

## Requirements

- [nvim-lua/plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [nvim-telescope/telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- `git` available in your `$PATH`

## Installation (LazyVim / lazy.nvim)

Add the plugin to your LazyVim spec so dependencies load automatically.

```lua
return {
  {
    "cog/git-download-browse.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
    },
    config = function()
      require("git-download-browse").setup({
        repo_root = vim.fn.expand("~/git"),
        keymap = "<leader>gv",
      })
    end,
  },
}
```

For LazyVim, drop the spec into `lua/plugins/git-download-browse.lua`
(or any
plugin file under `lua/plugins`). LazyVim will pick it up automatically.

## Usage

- `:DownloadGitRepo user/repo` or `:DownloadGitRepo https://github.com/user/repo`
  clones the repository (shallow) into `<repo_root>/user---repo`.
  - If you omit the argument, the command falls back to the clipboard contents
    (`+` register first, then `*`). When the cursor is on such a string within double quotes.
  You can paste the string using `yi"`
- `:GitRepos` opens the Telescope picker listing downloaded repositories and
  switches Neovim's local directory (`:lcd`) to the selected entry when you
  confirm.
- The default keymap `<leader>gv` opens the picker. Set `keymap = false` (or
  `nil`) in `setup()` to disable it.
- Change `repo_root` in `setup()` to control where repositories are stored. The
  folder (and missing parents) is created automatically during `setup()`.

The picker previews project READMEs when available; otherwise it shows a
directory listing.
