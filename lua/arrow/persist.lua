-- lua/arrow/persist.lua
local M = {}

local config = require("arrow.config")
local utils = require("arrow.utils")
local git = require("arrow.git")

-- Internal split storage
M._branch_filenames = {}
M._permanent_filenames = {}

-- Compute the base key (root for the repo/cwd), independent of branch, normalized
local function base_key()
	if config.getState("global_bookmarks") == true then
		return "global"
	end
	return utils.normalize_path_to_filename(config.getState("save_key_cached"))
end

-- Compute the branch-aware key (normalized: base + "-" + branch)
local function branch_key()
	if config.getState("global_bookmarks") == true then
		return "global"
	end

	if config.getState("separate_by_branch") then
		local branch = git.refresh_git_branch()
		if branch and branch ~= "" then
			-- IMPORTANT: normalize base + "-" + branch to avoid "/" issues
			return utils.normalize_path_to_filename(config.getState("save_key_cached") .. "-" .. branch)
		end
	end

	return base_key()
end

-- Backward‑compatible key (used by original cache file)
local function save_key()
	return branch_key()
end

local function cache_file_path()
	local save_path = config.getState("save_path")()
	save_path = save_path:gsub("/$", "")

	if vim.fn.isdirectory(save_path) == 0 then
		vim.fn.mkdir(save_path, "p")
	end

	return save_path .. "/" .. save_key()
end

-- Path for branch‑independent (permanent) bookmarks.
-- Only meaningful when we separate by branch and not using global storage.
local function permanent_cache_file_path()
	if config.getState("global_bookmarks") == true then
		return nil
	end
	if config.getState("separate_by_branch") ~= true then
		return nil
	end

	local save_path = config.getState("save_path")()
	save_path = save_path:gsub("/$", "")

	if vim.fn.isdirectory(save_path) == 0 then
		vim.fn.mkdir(save_path, "p")
	end

	-- base_key() is normalized already
	return save_path .. "/" .. (base_key() .. ".permanent")
end

local function notify()
	vim.api.nvim_exec_autocmds("User", {
		pattern = "ArrowUpdate",
	})
end

vim.g.arrow_filenames = vim.g.arrow_filenames or {}
-- Lookup set for permanent entries: filename -> true (used by UI)
vim.g.arrow_permanent_lookup = vim.g.arrow_permanent_lookup or {}

-- Helpers to be tolerant with "./" prefix when relative_path = true
local function maybe_prefix_dot(p)
	if config.getState("relative_path") == true and config.getState("global_bookmarks") == false then
		if not p:match("^%./") and not utils.string_contains_whitespace(p) then
			return "./" .. p
		end
	end
	return p
end

local function find_in_list(list, filename)
	local want = maybe_prefix_dot(filename)
	for i, name in ipairs(list) do
		local n = maybe_prefix_dot(name)
		if n == want then
			return i
		end
	end
	return nil
end

local function write_lines(path, arr)
	if not path then
		return
	end
	local content = vim.fn.join(arr, "\n")
	local lines = vim.fn.split(content, "\n")
	vim.fn.writefile(lines, path)
end

local function cache_files()
	-- branch/current list
	write_lines(cache_file_path(), M._branch_filenames)
	-- permanent list (only used when separate_by_branch)
	write_lines(permanent_cache_file_path(), M._permanent_filenames)
end

-- Combine with branch first, then permanent (so 1–9 map nicely to locals)
local function combine_unique(branch, permanent)
	local combined, seen = {}, {}
	for _, v in ipairs(branch or {}) do
		if not seen[v] then
			table.insert(combined, v)
			seen[v] = true
		end
	end
	for _, v in ipairs(permanent or {}) do
		if not seen[v] then
			table.insert(combined, v)
			seen[v] = true
		end
	end
	return combined
end

function M.save(filename)
	if not M.is_saved(filename) then
		table.insert(M._branch_filenames, filename)
		cache_files()
		M.load_cache_file()
	end
	notify()
end

function M.remove(filename)
	-- Prefer removing from permanent list; otherwise remove from branch list
	local idx_perm = find_in_list(M._permanent_filenames, filename)
	if idx_perm then
		table.remove(M._permanent_filenames, idx_perm)
	else
		local idx_branch = find_in_list(M._branch_filenames, filename)
		if idx_branch then
			table.remove(M._branch_filenames, idx_branch)
		end
	end

	cache_files()
	M.load_cache_file()
	notify()
end

function M.toggle(filename)
	git.refresh_git_branch()

	filename = filename or utils.get_current_buffer_path()

	local index = M.is_saved(filename)
	if index then
		M.remove(filename)
	else
		M.save(filename)
	end
	notify()
end

-- Clear only the branch‑scoped list. Permanent bookmarks are kept.
function M.clear()
	M._branch_filenames = {}
	cache_files()
	M.load_cache_file()
	notify()
end

function M.is_saved(filename)
	for i, name in ipairs(vim.g.arrow_filenames) do
		if config.getState("relative_path") == true and config.getState("global_bookmarks") == false then
			if not name:match("^%./") and not utils.string_contains_whitespace(name) then
				name = "./" .. name
			end

			if not filename:match("^%./") and not utils.string_contains_whitespace(filename) then
				filename = "./" .. filename
			end
		end

		if name == filename then
			return i
		end
	end
	return nil
end

-- Is the filename in the permanent list?
function M.is_saved_permanent(filename)
	return find_in_list(M._permanent_filenames, filename)
end

function M.load_cache_file()
	local branch_path = cache_file_path()
	local perm_path = permanent_cache_file_path()

	-- Load branch/current list
	if vim.fn.filereadable(branch_path) == 0 then
		M._branch_filenames = {}
	else
		local ok, data = pcall(vim.fn.readfile, branch_path)
		M._branch_filenames = (ok and data) or {}
	end

	-- Load permanent list (only when used)
	if perm_path and vim.fn.filereadable(perm_path) == 1 then
		local okp, datap = pcall(vim.fn.readfile, perm_path)
		M._permanent_filenames = (okp and datap) or {}
	else
		M._permanent_filenames = {}
	end

	-- Merge (branch first), de-duplicated
	vim.g.arrow_filenames = combine_unique(M._branch_filenames, M._permanent_filenames)

	-- Build lookup set for permanent items only
	local perm_lookup = {}
	for _, v in ipairs(M._permanent_filenames) do
		perm_lookup[v] = true
	end
	vim.g.arrow_permanent_lookup = perm_lookup
end

-- Backward‑compatible API: now writes both underlying files
function M.cache_file()
	cache_files()
end

function M.go_to(index)
	local filename = vim.g.arrow_filenames[index]

	if not filename then
		return
	end

	if
		config.getState("global_bookmarks") == true
		or config.getState("save_key_name") == "cwd"
		or config.getState("save_key_name") == "git_root_bare"
	then
		vim.cmd(":edit " .. filename)
	else
		vim.cmd(":edit " .. config.getState("save_key_cached") .. "/" .. filename)
	end
end

function M.next()
	git.refresh_git_branch()

	local current_index = M.is_saved(utils.get_current_buffer_path())
	local next_index

	if current_index and current_index < #vim.g.arrow_filenames then
		next_index = current_index + 1
	else
		next_index = 1
	end

	M.go_to(next_index)
end

function M.previous()
	git.refresh_git_branch()

	local current_index = M.is_saved(utils.get_current_buffer_path())
	local previous_index

	if current_index and current_index == 1 then
		previous_index = #vim.g.arrow_filenames
	elseif current_index then
		previous_index = current_index - 1
	else
		previous_index = #vim.g.arrow_filenames
	end

	M.go_to(previous_index)
end

-- ===== Scoped navigation (local-only or global/permanent-only) ==============

-- Internal helper to navigate within a specific list
local function _navigate_scoped(list, forward)
	git.refresh_git_branch()

	if not list or #list == 0 then
		return
	end

	-- Choose the comparable filename for this mode (respects relative_path)
	local filename
	if config.getState("global_bookmarks") == true then
		filename = vim.fn.expand("%:p")
	else
		filename = utils.get_current_buffer_path()
	end

	-- Find current position inside the provided list
	local cur_idx = find_in_list(list, filename)

	-- Compute target index (wrap around)
	local target_idx
	if cur_idx then
		if forward then
			target_idx = (cur_idx % #list) + 1
		else
			target_idx = ((cur_idx - 2) % #list) + 1
		end
	else
		target_idx = forward and 1 or #list
	end

	local target = list[target_idx]
	if not target then
		return
	end

	-- Try to reuse merged navigation when possible
	local merged_idx = M.is_saved(target)
	if merged_idx then
		M.go_to(merged_idx)
		return
	end

	-- Fallback open (very unlikely, but keeps behavior consistent)
	if
		config.getState("global_bookmarks") == true
		or config.getState("save_key_name") == "cwd"
		or config.getState("save_key_name") == "git_root_bare"
	then
		vim.cmd(":edit " .. target)
	else
		vim.cmd(":edit " .. config.getState("save_key_cached") .. "/" .. target)
	end
end

-- Choose which list represents "global" depending on configuration.
local function _get_global_list()
	-- When global_bookmarks = true, the only list we have is the branch/current file.
	-- Treat "global" navigation as the same as the main list to avoid a no-op.
	if config.getState("global_bookmarks") == true then
		return M._branch_filenames
	end
	return M._permanent_filenames
end

-- Public scoped navigations ---------------------------------------------------

-- Local/branch-only
function M.next_local()
	_navigate_scoped(M._branch_filenames, true)
end

function M.previous_local()
	_navigate_scoped(M._branch_filenames, false)
end

-- Global/permanent-only (what the UI shows under “Global bookmarks”)
function M.next_global()
	_navigate_scoped(_get_global_list(), true)
end

function M.previous_global()
	_navigate_scoped(_get_global_list(), false)
end

-- Optional aliases for taste
M.next_branch = M.next_local
M.previous_branch = M.previous_local
M.next_permanent = M.next_global
M.previous_permanent = M.previous_global

function M.open_cache_file()
	git.refresh_git_branch()

	local cache_path = cache_file_path()
	local cache_content

	if vim.fn.filereadable(cache_path) == 0 then
		cache_content = {}
	else
		cache_content = vim.fn.readfile(cache_path)
	end

	if config.getState("relative_path") == true and config.getState("global_bookmarks") == false then
		for i, line in ipairs(cache_content) do
			if not line:match("^%./") and not utils.string_contains_whitespace(line) and #cache_content[i] > 1 then
				cache_content[i] = "./" .. line
			end
		end
	end

	local bufnr = vim.api.nvim_create_buf(false, true)

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, cache_content)

	local width = math.min(80, vim.fn.winwidth(0) - 4)
	local height = math.min(20, #cache_content + 2)

	local row = math.ceil((vim.o.lines - height) / 2)
	local col = math.ceil((vim.o.columns - width) / 2)

	local border = (config.getState("window") or {}).border -- keep legacy field tolerant

	local opts = {
		style = "minimal",
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		focusable = true,
		border = border,
	}

	local winid = vim.api.nvim_open_win(bufnr, true, opts)

	local close_buffer = ":lua vim.api.nvim_win_close(" .. winid .. ", {force = true})<CR>"
	vim.api.nvim_buf_set_keymap(bufnr, "n", "q", close_buffer, { noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<Esc>", close_buffer, { noremap = true, silent = true })
	vim.keymap.set("n", config.getState("leader_key"), close_buffer, { noremap = true, silent = true, buffer = bufnr })

	vim.keymap.set("n", "<CR>", function()
		local line = vim.api.nvim_get_current_line()

		vim.api.nvim_win_close(winid, true)
		vim.cmd(":edit " .. vim.fn.fnameescape(line))
	end, { noremap = true, silent = true, buffer = bufnr })

	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = bufnr,
		desc = "save cache buffer on leave",
		callback = function()
			local updated_content = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			vim.fn.writefile(updated_content, cache_path)
			M.load_cache_file()
		end,
	})

	vim.cmd("setlocal nu")

	return bufnr, winid
end

-- Public helpers for permanent bookmarks ---------------------------------

function M.save_permanent(filename)
	-- If not in split mode, saving permanent is the same as normal save
	if config.getState("separate_by_branch") ~= true or config.getState("global_bookmarks") == true then
		return M.save(filename)
	end

	if not M.is_saved_permanent(filename) then
		table.insert(M._permanent_filenames, filename)
		-- ensure we don't keep a duplicate in the branch list
		local idx_branch = find_in_list(M._branch_filenames, filename)
		if idx_branch then
			table.remove(M._branch_filenames, idx_branch)
		end
		cache_files()
		M.load_cache_file()
		notify()
	end
end

function M.remove_permanent(filename)
	if config.getState("separate_by_branch") ~= true or config.getState("global_bookmarks") == true then
		return
	end
	local idx = find_in_list(M._permanent_filenames, filename)
	if idx then
		table.remove(M._permanent_filenames, idx)
		cache_files()
		M.load_cache_file()
		notify()
	end
end

function M.toggle_permanent(filename)
	filename = filename or utils.get_current_buffer_path()
	if M.is_saved_permanent(filename) then
		M.remove_permanent(filename)
	else
		M.save_permanent(filename)
	end
end

-- Expose raw lists for UI
function M.get_branch_list()
	return vim.deepcopy(M._branch_filenames)
end

function M.get_permanent_list()
	return vim.deepcopy(M._permanent_filenames)
end

return M
