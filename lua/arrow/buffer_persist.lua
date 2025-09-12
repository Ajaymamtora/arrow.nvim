local M = {}

local config = require("arrow.config")
local utils = require("arrow.utils")
local json = require("arrow.json")
local git = require("arrow.git") -- [[ ADDED: Required for getting branch info ]]

local ns = nil -- Defer namespace creation until needed
M.local_bookmarks = {}
M.last_sync_bookmarks = {}

-- Write coalescing - debounce file writes
local write_timers = {}
local write_delay = 100 -- ms

local function debounced_write(bufnr, buffer_file_name, fn)
	if write_timers[bufnr] then
		write_timers[bufnr]:stop()
	end

	write_timers[bufnr] = vim.defer_fn(function()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			local stat = vim.uv.fs_stat(buffer_file_name)
			if not stat then
				return
			end
		end
		fn()
		write_timers[bufnr] = nil
	end, write_delay)
end

local function notify()
	vim.api.nvim_exec_autocmds("User", {
		pattern = "ArrowMarkUpdate",
	})
end

local function save_key(filename)
	return utils.normalize_path_to_filename(filename)
end

function M.get_ns()
	if ns == nil then
		ns = vim.api.nvim_create_namespace("arrow_bookmarks")
	end
	return ns
end

function M.invalidate_buffer_cache(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	M.local_bookmarks[bufnr] = nil
	M.last_sync_bookmarks[bufnr] = nil
	
	-- Cancel any pending writes for this buffer
	if write_timers[bufnr] then
		write_timers[bufnr]:stop()
		write_timers[bufnr] = nil
	end
end

-- vvvvvvvv  MODIFIED FUNCTION vvvvvvvv
function M.cache_file_path(filename)
	local save_path = config.getState("save_path")()

	-- If separating by branch, create and use a branch-specific subdirectory
	if config.getState("separate_by_branch") then
		local branch = config.getState("current_branch") or git.get_git_branch()
		if branch and branch ~= "" then
			save_path = save_path .. "/" .. utils.normalize_path_to_filename(branch)
		end
	end

	save_path = save_path:gsub("/$", "")

	if vim.fn.isdirectory(save_path) == 0 then
		vim.fn.mkdir(save_path, "p")
	end

	return save_path .. "/" .. save_key(filename)
end
-- ^^^^^^^^ END OF MODIFIED FUNCTION ^^^^^^^^

function M.clear_buffer_ext_marks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	utils.safe_buf_clear_namespace(bufnr, M.get_ns(), 0, -1)
	notify()
end

function M.redraw_bookmarks(bufnr, result)
	-- Get the total number of lines in the buffer
	local line_count = utils.safe_buf_line_count(bufnr)

	for i, res in ipairs(result) do
		local indexes = config.getState("index_keys")

		local line = res.line

		-- Skip invalid lines that are out of range
		if line <= 0 or line > line_count then
			-- Skip this bookmark as it's out of range
			goto continue
		end

		local id = utils.safe_buf_set_extmark(bufnr, M.get_ns(), line - 1, -1, {
			sign_text = indexes:sub(i, i) .. "",
			sign_hl_group = "ArrowBookmarkSign",
			hl_mode = "combine",
		})

		res.ext_id = id

		::continue::
	end
	notify()
end

function M.load_buffer_bookmarks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	
	-- Return if already loaded and data hasn't changed
	if M.local_bookmarks[bufnr] ~= nil then
		if M.last_sync_bookmarks[bufnr] ~= nil and utils.table_comp(M.last_sync_bookmarks[bufnr], M.local_bookmarks[bufnr]) then
			return
		end
	end

	-- Use absolute path for consistency in cache file naming
	local buffer_path = utils.safe_buf_get_name(bufnr)
	if not buffer_path or buffer_path == "" then
		return
	end -- Don't process unnamed buffers
	local absolute_buffer_path = vim.fn.fnamemodify(buffer_path, ":p")
	local path = M.cache_file_path(absolute_buffer_path)

	if vim.fn.filereadable(path) == 0 then
		M.local_bookmarks[bufnr] = {}
	else
		-- Use vim.fn.readfile for potentially better handling of file reading
		local read_ok, content_lines = pcall(vim.fn.readfile, path)
		if not read_ok or not content_lines then
			vim.notify("Arrow: Failed to read buffer bookmarks from: " .. path, vim.log.levels.ERROR)
			M.local_bookmarks[bufnr] = {}
			return
		end
		local content = table.concat(content_lines, "\n")

		-- Handle empty file case explicitly
		if content == "" then
			M.local_bookmarks[bufnr] = {}
			notify() -- Notify even if empty, e.g., for satellite
			return
		end

		local success, result = pcall(json.decode, content)
		if success then
			M.local_bookmarks[bufnr] = result

			--[[ REMOVED THIS CALL: This was likely causing the issue during session load
   -- Add this line to validate and update bookmarks before redrawing
   M.update(bufnr)
   --]]

			-- Redraw bookmarks based *only* on the loaded data initially
			M.redraw_bookmarks(bufnr, M.local_bookmarks[bufnr])
		else
			vim.notify(
				"Arrow: Failed to decode JSON bookmarks for " .. absolute_buffer_path .. "\nError: " .. tostring(result),
				vim.log.levels.ERROR
			)
			M.local_bookmarks[bufnr] = {}
		end
	end
	notify()
end

function M.sync_buffer_bookmarks(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if
		M.last_sync_bookmarks[bufnr]
		and M.local_bookmarks[bufnr]
		and utils.table_comp(M.last_sync_bookmarks[bufnr], M.local_bookmarks[bufnr])
	then
		return
	end

	local buffer_file_name = utils.safe_buf_get_name(bufnr)
	if not buffer_file_name or buffer_file_name == "" then
		return false
	end

	-- Use debounced write to avoid excessive I/O
	debounced_write(bufnr, buffer_file_name, function()
		if config.getState("per_buffer_config").sort_automatically then
			table.sort(M.local_bookmarks[bufnr], function(a, b)
				return a.line < b.line
			end)
		end

		local path = M.cache_file_path(buffer_file_name)
		local path_dir = vim.fn.fnamemodify(path, ":h")

		if vim.fn.isdirectory(path_dir) == 0 then
			vim.fn.mkdir(path_dir, "p")
		end

		local file = io.open(path, "w")

		if file then
			if M.local_bookmarks[bufnr] ~= nil and #M.local_bookmarks[bufnr] ~= 0 then
				file:write(json.encode(M.local_bookmarks[bufnr]))
			end
			file:flush()
			file:close()

			M.last_sync_bookmarks[bufnr] = vim.deepcopy(M.local_bookmarks[bufnr])
			notify()
			return true
		end

		return false
	end)
end

function M.sync_buffer_bookmarks_immediate(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- Cancel any pending writes and write immediately
	if write_timers[bufnr] then
		write_timers[bufnr]:stop()
		write_timers[bufnr] = nil
	end

	if
		M.last_sync_bookmarks[bufnr]
		and M.local_bookmarks[bufnr]
		and utils.table_comp(M.last_sync_bookmarks[bufnr], M.local_bookmarks[bufnr])
	then
		return true
	end

	local buffer_file_name = utils.safe_buf_get_name(bufnr)
	if not buffer_file_name or buffer_file_name == "" then
		return false
	end

	if not vim.api.nvim_buf_is_valid(bufnr) then
		local stat = vim.uv.fs_stat(buffer_file_name)
		if not stat then
			return
		end
	end

	if config.getState("per_buffer_config").sort_automatically then
		table.sort(M.local_bookmarks[bufnr], function(a, b)
			return a.line < b.line
		end)
	end

	local path = M.cache_file_path(buffer_file_name)
	local path_dir = vim.fn.fnamemodify(path, ":h")

	if vim.fn.isdirectory(path_dir) == 0 then
		vim.fn.mkdir(path_dir, "p")
	end

	local file = io.open(path, "w")

	if file then
		if M.local_bookmarks[bufnr] ~= nil and #M.local_bookmarks[bufnr] ~= 0 then
			file:write(json.encode(M.local_bookmarks[bufnr]))
		end
		file:flush()
		file:close()

		M.last_sync_bookmarks[bufnr] = vim.deepcopy(M.local_bookmarks[bufnr])
		notify()
		return true
	end

	return false
end

function M.is_saved(bufnr, bookmark)
	local saveds = M.get_bookmarks_by(bufnr)

	if saveds and #saveds > 0 then
		for _, saved in ipairs(saveds) do
			if utils.table_comp(saved, bookmark) then
				return true
			end
		end
	end

	return false
end

function M.remove(index, bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if M.local_bookmarks[bufnr] == nil then
		return
	end

	if M.local_bookmarks[bufnr][index] == nil then
		return
	end
	table.remove(M.local_bookmarks[bufnr], index)

	M.sync_buffer_bookmarks(bufnr)
end

function M.clear(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	M.local_bookmarks[bufnr] = {}
	utils.safe_buf_clear_namespace(bufnr, M.get_ns(), 0, -1)
	M.sync_buffer_bookmarks(bufnr)
end

function M.update(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local line_count = utils.safe_buf_line_count(bufnr)
	local extmarks = utils.safe_buf_get_extmarks(bufnr, M.get_ns(), { 0, 0 }, { -1, -1 }, {})

	if M.local_bookmarks[bufnr] ~= nil then
		for _, mark in ipairs(M.local_bookmarks[bufnr]) do
			for _, extmark in ipairs(extmarks) do
				local extmark_id, extmark_row, _ = unpack(extmark)
				if mark.ext_id == extmark_id and mark.line ~= extmark_row + 1 and (extmark_row + 1) < line_count then -- Not ideal, it don't recalculate when formatting changes line count
					mark.line = extmark_row + 1
				end
			end
		end
	end

	-- remove marks that go beyond total_line
	M.local_bookmarks[bufnr] = vim.tbl_filter(function(mark)
		return line_count >= mark.line
	end, M.local_bookmarks[bufnr] or {})

	-- remove overlap marks
	local hash = {}
	local set = {}
	for _, mark in ipairs(M.local_bookmarks[bufnr]) do
		if not hash[mark.line] then
			set[#set + 1] = mark
			hash[mark.line] = true
		end
	end

	M.local_bookmarks[bufnr] = set
	notify()
end

function M.save(bufnr, line_nr, col_nr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if not M.local_bookmarks[bufnr] then
		M.local_bookmarks[bufnr] = {}
	end

	local data = {
		line = line_nr,
		col = col_nr,
	}

	if not (M.is_saved(bufnr, data)) then
		table.insert(M.local_bookmarks[bufnr], data)

		M.sync_buffer_bookmarks(bufnr)
	end
end

function M.get_bookmarks_by(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	return M.local_bookmarks[bufnr]
end

return M
