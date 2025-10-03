local M = {}

local Path = require("plenary.path")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local utils = require("telescope.utils")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local config = {
  repo_root = vim.fn.expand("~/git"),
  keymap = "<leader>gv",
}

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

local function ensure_repo_root()
  local root = config.repo_root
  if vim.fn.isdirectory(root) == 0 then
    vim.fn.mkdir(root, "p")
  end
  return root
end

function M.download_repo(arg)
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
  local result = vim.fn.system({ "git", "clone", "--depth=1", url, target })
  if vim.v.shell_error == 0 then
    vim.notify(string.format("Cloned into %s", target), vim.log.levels.INFO)
  else
    vim.notify(result ~= "" and result or "git clone failed", vim.log.levels.ERROR)
  end
end

local function collect_repos()
  local entries = {}
  local root = ensure_repo_root()
  local fs = vim.loop.fs_scandir(root)
  if not fs then
    return entries
  end

  while true do
    local name, typ = vim.loop.fs_scandir_next(fs)
    if not name then
      break
    end
    if typ == "directory" then
      table.insert(entries, {
        value = name,
        display = name,
        ordinal = name,
        path = Path:new(root, name):absolute(),
      })
    end
  end

  table.sort(entries, function(a, b)
    return a.display:lower() < b.display:lower()
  end)

  return entries
end

local function repo_previewer()
  return previewers.new_buffer_previewer({
    get_buffer_by_name = function(_, entry)
      return entry.path
    end,
    define_preview = function(self, entry)
      local readme = Path:new(entry.path, "README.md")
      if readme:exists() then
        local lines = readme:readlines()
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
        vim.bo[self.state.bufnr].filetype = "markdown"
      else
        local output = utils.get_os_command_output({ "ls", "-a", entry.path })
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, output)
        vim.bo[self.state.bufnr].filetype = "sh"
      end
    end,
  })
end

function M.open_picker(opts)
  opts = opts or {}
  local entries = collect_repos()
  pickers
    .new(opts, {
      prompt_title = "Git Repos",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return entry
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = repo_previewer(),
      attach_mappings = function(prompt_bufnr, _)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if selection and selection.path then
            vim.cmd("lcd " .. vim.fn.fnameescape(selection.path))
          end
        end)
        return true
      end,
    })
    :find()
end

local function set_keymap()
  if not config.keymap or config.keymap == "" then
    return
  end
  vim.keymap.set("n", config.keymap, M.open_picker, {
    desc = "Git download browser",
    silent = true,
  })
end

function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", config, opts)

  -- Ensure the configured repository root exists ahead of time so later
  -- commands can assume it is available.
  ensure_repo_root()

  pcall(vim.api.nvim_del_user_command, "DownloadGitRepo")
  pcall(vim.api.nvim_del_user_command, "GitRepos")

  vim.api.nvim_create_user_command("DownloadGitRepo", function(params)
    M.download_repo(params.args)
  end, {
    nargs = 1,
    complete = function()
      return {}
    end,
  })

  vim.api.nvim_create_user_command("GitRepos", function()
    M.open_picker()
  end, {})

  set_keymap()
end

M.setup()

return M
