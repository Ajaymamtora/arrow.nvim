# arrow.nvim

Arrow.nvim is a **high-performance** plugin for bookmarking files (like harpoon) using a single UI and keymap. 

**✨ Key Features:**
- **Performance-optimized** with async operations and intelligent caching
- **Dual bookmark system**: file-level and line-level bookmarks
- **Git branch isolation** with optimized branch detection
- **Smart file I/O** with write coalescing and lazy loading
- **User API** for external tool integration

Arrow can be extensively customized for everyone's needs and provides both project-wide and per-buffer bookmarks with automatic position tracking.

### Per Project / Global bookmarks:
![arrow.nvim](https://i.imgur.com/mPdSC5s.png)
![arrow.nvim_gif](https://i.imgur.com/LcvG406.gif)
![arrow_buffers](https://i.imgur.com/Lll9YvY.gif)

## Performance Optimizations

**🚀 Arrow.nvim has been comprehensively optimized for maximum performance:**

- **Cached Git Operations**: Git branch detection uses intelligent caching with 1-second TTL
- **Async System Calls**: Non-blocking `vim.system()` instead of `vim.fn.system()` 
- **Write Coalescing**: File writes are debounced and batched to reduce I/O
- **Lazy Loading**: Buffer bookmarks only loaded when needed
- **Smart Autocommands**: Optimized event handling with selective triggers
- **Memory Efficient**: Proper cache invalidation and resource cleanup

## Installation

### Lazy

```lua
return {
  "otavioschwanck/arrow.nvim",
  dependencies = {
    { "nvim-tree/nvim-web-devicons" },
    -- or if using `mini.icons`
    -- { "echasnovski/mini.icons" },
  },
  opts = {
    show_icons = true,
    leader_key = ';', -- Recommended to be a single key
    buffer_leader_key = 'm', -- Per Buffer Mappings
  }
}
```

### Packer

```lua
use { 'otavioschwanck/arrow.nvim', config = function()
  require('arrow').setup({
    show_icons = true,
    leader_key = ';', -- Recommended to be a single key
    buffer_leader_key = 'm', -- Per Buffer Mappings
  })
end }
```

## Usage

Just press the leader_key set on setup and follow your heart. (It's that easy!)

## API for External Integration

**🔌 Arrow provides a comprehensive API for integration with external tools like git hooks, file watchers, or custom workflows:**

```lua
local arrow_api = require('arrow').api

-- React to git branch changes from external tools
arrow_api.on_git_branch_changed("feature/new-branch")

-- Async git head change detection
arrow_api.on_git_head_changed()

-- Manual directory change notification
arrow_api.on_directory_changed("/new/project/path")

-- Force refresh all bookmarks and caches
arrow_api.refresh_all()

-- Invalidate git cache when needed
arrow_api.invalidate_git_cache()

-- Invalidate specific buffer cache
arrow_api.invalidate_buffer_cache(bufnr)
```

**Example integration with git hooks:**

```lua
-- In your nvim config
vim.api.nvim_create_autocmd("User", {
  pattern = "GitBranchChanged", 
  callback = function()
    require('arrow').api.on_git_head_changed()
  end
})

-- Custom autocmd for your git workflow
vim.api.nvim_create_autocmd("User", {
  pattern = "GitHeadChanged",
  callback = function()
    require('arrow').api.refresh_all()
  end
})
```

## Differences from harpoon:

- **Single keymap needed** - everything in one interface
- **Performance optimized** - async operations, caching, write coalescing
- **Dual bookmark system** - both file-level and line-level bookmarks
- **Advanced UI** - colors, icons, and intuitive navigation
- **Smart path display** - shows path only when needed for disambiguation  
- **Delete mode** - quickly remove multiple items
- **Multiple open modes** - vertical, horizontal, or replace current buffer
- **Statusline integration** - show bookmark status in statusline
- **Session compatibility** - works seamlessly with session plugins
- **Git branch isolation** - separate bookmarks per branch
- **External API** - integrate with git hooks and external tools

## Advanced Setup

```lua
{
  show_icons = true,
  always_show_path = false,
  separate_by_branch = false, -- Bookmarks will be separated by git branch (with optimized caching)
  hide_handbook = false, -- set to true to hide the shortcuts on menu.
  save_path = function()
    return vim.fn.stdpath("cache") .. "/arrow"
  end,
  mappings = {
    edit = "e",
    delete_mode = "d",
    clear_all_items = "C",
    toggle = "s", -- used as save if separate_save_and_remove is true
    open_vertical = "v",
    open_horizontal = "-",
    quit = "q",
    remove = "x", -- only used if separate_save_and_remove is true
    next_item = "]",
    prev_item = "["
  },
  custom_actions = {
    open = function(target_file_name, current_file_name) end, -- target_file_name = file selected to be open, current_file_name = filename from where this was called
    split_vertical = function(target_file_name, current_file_name) end,
    split_horizontal = function(target_file_name, current_file_name) end,
  },
  window = { -- controls the appearance and position of an arrow window (see nvim_open_win() for all options)
    width = "auto",
    height = "auto",
    row = "auto",
    col = "auto",
    border = "double",
  },
  per_buffer_config = {
    lines = 4, -- Number of lines showed on preview.
    sort_automatically = true, -- Auto sort buffer marks (optimized with lazy loading).
    satellite = { -- default to nil, display arrow index in scrollbar at every update
      enable = false,
      overlap = true,
      priority = 1000,
    },
    zindex = 10, --default 50
    treesitter_context = nil, -- it can be { line_shift_down = 2 }, currently not usable, for detail see https://github.com/otavioschwanck/arrow.nvim/pull/43#issue-2236320268
  },
  separate_save_and_remove = false, -- if true, will remove the toggle and create the save/remove keymaps.
  leader_key = ";",
  save_key = "cwd", -- what will be used as root to save the bookmarks. Can be also `git_root` and `git_root_bare`.
  global_bookmarks = false, -- if true, arrow will save files globally (ignores separate_by_branch)
  index_keys = "123456789zxcbnmZXVBNM,afghjklAFGHJKLwrtyuiopWRTYUIOP", -- keys mapped to bookmark index, i.e. 1st bookmark will be accessible by 1, and 12th - by c
  full_path_list = { "update_stuff" } -- filenames on this list will ALWAYS show the file path too.
}
```

You can also map previous and next keys:

```lua
vim.keymap.set("n", "H", require("arrow.persist").previous)
vim.keymap.set("n", "L", require("arrow.persist").next)
vim.keymap.set("n", "<C-s>", require("arrow.persist").toggle)
```

**Performance tip:** These functions are now optimized to avoid unnecessary git operations during navigation.


## Statusline

You can use `require('arrow.statusline')` to access the statusline helpers:

```lua
local statusline = require('arrow.statusline')
statusline.is_on_arrow_file() -- return nil if current file is not on arrow.  Return the index if it is.
statusline.text_for_statusline() -- return the text to be shown in the statusline (the index if is on arrow or "" if not)
statusline.text_for_statusline_with_icons() -- Same, but with an bow and arrow icon ;D
```

![statusline](https://i.imgur.com/v7Rvagj.png)

## NvimTree
Show arrow marks in front of filename

<img width="346" alt="aaaaaaaaaa" src="https://github.com/xzbdmw/arrow.nvim/assets/97848247/5357e7ce-8ec7-4e43-a0cf-0856240bbb9f">


A small patch is needed.
<details>
  <summary>Click to expand</summary>

  In `nvim-tree.lua/lua/nvim-tree/renderer/builder.lua`
change function `formate_line` to
```lua
function Builder:format_line(indent_markers, arrows, icon, name, node)
  local added_len = 0
  local function add_to_end(t1, t2)
    if not t2 then
      return
    end
    for _, v in ipairs(t2) do
      if added_len > 0 then
        table.insert(t1, { str = M.opts.renderer.icons.padding })
      end
      table.insert(t1, v)
    end

    -- first add_to_end don't need padding
    -- hence added_len is calculated at the end to be used next time
    added_len = 0
    for _, v in ipairs(t2) do
      added_len = added_len + #v.str
    end
  end

  local line = { indent_markers, arrows }

  local arrow_index = 1
  local arrow_filenames = vim.g.arrow_filenames
  if arrow_filenames then
    for i, filename in ipairs(arrow_filenames) do
      if string.sub(node.absolute_path, -#filename) == filename then
        local statusline = require "arrow.statusline"
        arrow_index = statusline.text_for_statusline(_, i)
        line[1].str = string.sub(line[1].str, 1, -3)
        line[2].str = "(" .. arrow_index .. ") "
        line[2].hl = { "ArrowFileIndex" }
        break
      end
    end
  end

  add_to_end(line, { icon })

  for i = #M.decorators, 1, -1 do
    add_to_end(line, M.decorators[i]:icons_before(node))
  end

  add_to_end(line, { name })

  for i = #M.decorators, 1, -1 do
    add_to_end(line, M.decorators[i]:icons_after(node))
  end

  return line
end
```

</details>

## Highlights

- ArrowFileIndex
- ArrowCurrentFile
- ArrowAction
- ArrowDeleteMode

## Working with sessions plugins

**🔧 Arrow.nvim is optimized for session plugins and works seamlessly with most of them.**

For session plugins that need manual refresh after loading, add this to your post-load session hook:

```lua
-- Modern optimized approach (recommended)
require('arrow').api.refresh_all()

-- Or individual calls if you need more control
require("arrow.git").refresh_git_branch() -- only if separate_by_branch is true
require("arrow.persist").load_cache_file()
```

**Tested compatibility:**
- ✅ **persistence.nvim** - works perfectly out of the box
- ✅ **mini.sessions** - works with the refresh call above
- ✅ **auto-session** - works with the refresh call above  
- ✅ **session-manager** - works with the refresh call above

**Performance note:** The new `refresh_all()` API function uses async operations to avoid blocking during session restoration.

## Special Contributors

- ![xzbdmw](https://github.com/xzbdmw) - Had the idea of per buffer bookmarks and helped implement it
- **Performance Optimization Contributor** - Comprehensive performance optimizations including async operations, caching, and write coalescing

### Do you like my work? Please, buy me a coffee

https://www.buymeacoffee.com/otavioschwanck
