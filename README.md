# git-download-browse.nvim

Dealing with gitHub repositories from Neovim.

Three commands:

* [Clone](https://git-scm.com/docs/git-clone)
* Browse clones
* [Fork](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/fork-a-repo) a clone in a [worktree].

The commands will prompt you for infos if/when necessary

Default keybindings:

* `<leader>gc` clone a repo
* `<leader>gv` view the cloned repos in telescope
* `<leader>gk` fork, branch then create a worktree

Viewing the folder of clones  is done with telescope
The telescope previewer shows the  `README.md` of the current repo.
The telescope picker opens the folder containing the selected clone.

See [usage](#usage) for more details.
See [screenshots](#screenshots)
See [installation](#installation-lazyvim)

TBD support other git hubs than github

## Screenshots

### browsing

![screenshot](./assets/screenshot.png)

### Cloning

### Forking

## Requirements

* [nvim-lua/plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
* [nvim-telescope/telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
* `git` available in your `$PATH`

## Installation (LazyVim)

Add the plugin to your LazyVim spec so dependencies load automatically.

```lua
return {
  {
    "cognominal/git-download-browse.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-telescope/telescope.nvim",
    },
    config = function()
      require("git-download-browse").setup({
        reposDir = vim.fn.expand("~/git"),
        keymaps = {
          browse = "<leader>gv",
          clone = "<leader>gc",
          fork = "<leader>gk",
        },
      })
    end,
  },
}
```

For LazyVim, drop the spec into `lua/plugins/git-download-browse.lua`
(or any
plugin file under `lua/plugins`). LazyVim will pick it up automatically.

## Usage

* `:CloneGitRepo user/repo` or `:CloneGitRepo https://github.com/user/repo`
  clones the repository (shallow) into `<reposDir>/user---repo`.
  * If you omit the argument, the command falls back to the clipboard contents
    (`+` register first, then `*`). When the cursor is on such a string within
    double quotes.
   You can paste the string using `yi"`
* `:GitRepos` opens the Telescope picker listing downloaded repositories and
  switches Neovim's local directory (`:lcd`) to the selected entry when you
  confirm.
* `:GitFork [path|user/repo]` (or the default `<leader>gk`) forks the current
  repository using GitHub CLI, adds a `fork` remote, and creates a new worktree
  under `forked_dir`. Branch names start at `forked` and gain numeric suffixes
  if needed.
* The default `keymaps.browse` opens the picker (`<leader>gv`),
  `keymaps.clone` clones a repo (`<leader>gc`), and
  `keymaps.fork` forks the current repo (`<leader>gk`). Set any mapping to
  `false`/`nil` or override them inside `setup()` to rebind.
* Change `reposDir` in `setup()` to control where repositories are stored. The
  folder (and missing parents) is created automatically during `setup()`.

The picker previews project READMEs when available; otherwise it shows a
directory listing. Entries display an initial `F` when a fork remote is
configured for that repository.

## Tests

Run the Plenary test suite headlessly:

```sh
nvim --headless -u tests/minimal_init.lua -c "lua require('tests.run').run()"
```
