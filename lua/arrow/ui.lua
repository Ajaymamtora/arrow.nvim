local M = {}

local config = require("arrow.config")
local persist = require("arrow.persist")
local utils = require("arrow.utils")
local git = require("arrow.git")
local icons = require("arrow.integration.icons")

-- Model for the current menu render
local menu_model = {
	entries = {}, -- { line, key, filename, group = 'branch'|'global', icon_hl? }
	lines = {}, -- strings for buffer
	current_line = 0,
	header = { -- line numbers for headers & underlines
		global = { header = nil, underline = nil },
		branch = { header = nil, underline = nil },
	},
}

-- ===== Helpers ==============================================================

local function is_letter(c)
	return c:match("%a") ~= nil
end

local function build_reserved_keys()
	local reserved = {}
	local mappings = config.getState("mappings") or {}
	for _, k in pairs(mappings) do
		if type(k) == "string" and #k == 1 then
			reserved[k] = true
		end
	end
	local leader_key = config.getState("leader_key")
	if type(leader_key) == "string" and #leader_key == 1 then
		reserved[leader_key] = true
	end
	local buffer_leader_key = config.getState("buffer_leader_key")
	if type(buffer_leader_key) == "string" and #buffer_leader_key == 1 then
		reserved[buffer_leader_key] = true
	end
	-- keep these out of selection
	reserved[" "] = true
	reserved["\27"] = true -- <Esc>
	reserved["-"] = true -- used by open_horizontal
	-- Also reserve any user-defined *normal-mode* single-char mappings
	for byte = 65, 90 do -- A..Z
		local c = string.char(byte)
		if vim.fn.maparg(c, "n") ~= "" then
			reserved[c] = true
		end
	end
	for byte = 97, 122 do -- a..z
		local c = string.char(byte)
		if vim.fn.maparg(c, "n") ~= "" then
			reserved[c] = true
		end
	end
	return reserved
end

local function build_key_pools()
	local reserved = build_reserved_keys()
	local pools = {
		digits = {},
		letters = {},
	}

	-- Digits 1..9 for local (branch) first
	for d = 1, 9 do
		local c = tostring(d)
		if not reserved[c] then
			table.insert(pools.digits, c)
		end
	end

	-- Letters from index_keys but filtered to alphabetic & not reserved
	local index_keys = config.getState("index_keys") or "123456789zxcbnmZXVBNM,afghjklAFGHJKLwrtyuiopWRTYUIOP"
	for i = 1, #index_keys do
		local c = index_keys:sub(i, i)
		if is_letter(c) and not reserved[c] then
			pools.letters[#pools.letters + 1] = c
		end
	end

	return pools
end

local function format_names(file_names)
	local full_path_list = config.getState("full_path_list")
	local formatted_names = {}
	local perm_lookup = vim.g.arrow_permanent_lookup or {}
	local show_icons = config.getState("show_icons")

	-- occurrences for tail disambiguation
	local occ = {}
	for _, full_path in ipairs(file_names) do
		local tail = vim.fn.fnamemodify(full_path, ":t:r")
		if vim.fn.isdirectory(full_path) == 1 then
			local parsed_path = full_path
			if parsed_path:sub(#parsed_path, #parsed_path) == "/" then
				parsed_path = parsed_path:sub(1, #parsed_path - 1)
			end
			local splitted_path = vim.split(parsed_path, "/")
			local folder = splitted_path[#splitted_path]
			occ[folder] = occ[folder] or {}
			table.insert(occ[folder], full_path)
		else
			occ[tail] = occ[tail] or {}
			table.insert(occ[tail], full_path)
		end
	end

	for _, full_path in ipairs(file_names) do
		local tail = vim.fn.fnamemodify(full_path, ":t:r")
		local tail_with_ext = vim.fn.fnamemodify(full_path, ":t")
		local perm_glyph = perm_lookup[full_path] and " " or ""

		if vim.fn.isdirectory(full_path) == 1 then
			if not (string.sub(full_path, #full_path, #full_path) == "/") then
				full_path = full_path .. "/"
			end

			local splitted_path = vim.split(vim.fn.fnamemodify(full_path, ":h"), "/")
			if #splitted_path > 1 then
				local folder_name = splitted_path[#splitted_path]
				local location = vim.fn.fnamemodify(full_path, ":h:h")
				if #occ[folder_name] > 1 or config.getState("always_show_path") then
					table.insert(formatted_names, string.format("%s . %s%s", folder_name .. "/", location, perm_glyph))
				else
					table.insert(formatted_names, string.format("%s%s", folder_name .. "/", perm_glyph))
				end
			else
				if config.getState("always_show_path") then
					table.insert(formatted_names, full_path .. " . /" .. perm_glyph)
				else
					table.insert(formatted_names, full_path .. perm_glyph)
				end
			end
		elseif
			not (config.getState("always_show_path"))
			and #occ[tail] == 1
			and not (vim.tbl_contains(full_path_list, tail))
		then
			table.insert(formatted_names, tail_with_ext .. perm_glyph)
		else
			local display_path = vim.fn.fnamemodify(full_path, ":h")
			if vim.tbl_contains(full_path_list, tail) then
				display_path = vim.fn.fnamemodify(full_path, ":h")
			end
			table.insert(formatted_names, string.format("%s . %s%s", tail_with_ext, display_path, perm_glyph))
		end
	end

	return formatted_names
end

-- Build the complete menu lines (sections) ===================================
local function build_menu_model(filename_current_buf)
	local model = {
		entries = {},
		lines = {},
		current_line = 0,
		header = {
			global = { header = nil, underline = nil },
			branch = { header = nil, underline = nil },
		},
	}
	local show_icons = config.getState("show_icons")

	local branch_list = persist.get_branch_list()
	local global_list = persist.get_permanent_list()

	local formatted_branch = format_names(branch_list)
	local formatted_global = format_names(global_list)

	local pools = build_key_pools()
	local digits_pool = pools.digits
	local letters_pool = pools.letters

	local function pop_digit()
		return table.remove(digits_pool, 1)
	end

	local function pop_letter()
		return table.remove(letters_pool, 1)
	end

	local function next_branch_key()
		-- first 1..9 (digits), then letters
		local kd = pop_digit()
		if kd then
			return kd
		end
		return pop_letter()
	end

	local function next_global_key()
		-- letters only
		return pop_letter()
	end

	-- Top padding
	table.insert(model.lines, "")

	-- Global section FIRST -----------------------------------------------------
	table.insert(model.lines, "   Global bookmarks")
	model.header.global.header = #model.lines
	table.insert(model.lines, "   ----------------")
	model.header.global.underline = #model.lines

	if #global_list == 0 then
		table.insert(model.lines, "   (none)")
	else
		for i, full_path in ipairs(global_list) do
			local disp = formatted_global[i]
			local key = next_global_key() or "?"

			local rendered = "   " .. key .. " " .. disp
			local entry = { line = #model.lines + 1, key = key, filename = full_path, group = "global" }

			if show_icons then
				local icon, hl_group = icons.get_file_icon(full_path)
				rendered = "   " .. key .. " " .. icon .. " " .. disp
				entry.icon_hl = hl_group
			end

			table.insert(model.lines, rendered)
			table.insert(model.entries, entry)

			local parsed_filename = full_path
			if parsed_filename:sub(1, 2) == "./" then
				parsed_filename = parsed_filename:sub(3)
			end
			if parsed_filename == filename_current_buf then
				model.current_line = #model.lines
			end
		end
	end

	table.insert(model.lines, "") -- spacer

	-- Branch (local) section SECOND -------------------------------------------
	table.insert(model.lines, "   Local (branch) bookmarks")
	model.header.branch.header = #model.lines
	table.insert(model.lines, "   ------------------------")
	model.header.branch.underline = #model.lines

	if #branch_list == 0 then
		table.insert(model.lines, "   (none)")
	else
		for i, full_path in ipairs(branch_list) do
			local disp = formatted_branch[i]
			local key = next_branch_key() or "?"

			local rendered = "   " .. key .. " " .. disp
			local entry = { line = #model.lines + 1, key = key, filename = full_path, group = "branch" }

			if show_icons then
				local icon, hl_group = icons.get_file_icon(full_path)
				rendered = "   " .. key .. " " .. icon .. " " .. disp
				entry.icon_hl = hl_group
			end

			table.insert(model.lines, rendered)
			table.insert(model.entries, entry)

			local parsed_filename = full_path
			if parsed_filename:sub(1, 2) == "./" then
				parsed_filename = parsed_filename:sub(3)
			end
			if parsed_filename == filename_current_buf then
				model.current_line = #model.lines
			end
		end
	end

	return model
end

-- Build & return the actions “handbook” lines ================================

local function build_actions_lines(filename_current)
	local mappings = config.getState("mappings")
	local separate_save_and_remove = config.getState("separate_save_and_remove")
	local show_handbook = not (config.getState("hide_handbook"))

	if not show_handbook then
		return {}
	end

	local actions = {}
	local already_saved = persist.is_saved(filename_current) ~= nil

	if separate_save_and_remove then
		table.insert(actions, string.format("%s Save Current File", mappings.toggle))
		table.insert(actions, string.format("%s Remove Current File", mappings.remove))
	else
		if already_saved then
			table.insert(actions, string.format("%s Remove Current File", mappings.toggle))
		else
			table.insert(actions, string.format("%s Save Current File", mappings.toggle))
		end
	end

	local is_perm = persist.is_saved_permanent(filename_current) ~= nil
	if is_perm then
		table.insert(actions, string.format("%s Remove Permanent File", mappings.toggle_permanent or "P"))
	else
		table.insert(actions, string.format("%s Save Permanently", mappings.toggle_permanent or "P"))
	end

	table.insert(actions, string.format("%s Edit Arrow File", mappings.edit))
	table.insert(actions, string.format("%s Clear All Items", mappings.clear_all_items))
	table.insert(actions, string.format("%s Delete Mode", mappings.delete_mode))
	table.insert(actions, string.format("%s Open Vertical", mappings.open_vertical))
	table.insert(actions, string.format("%s Open Horizontal", mappings.open_horizontal))
	table.insert(actions, string.format("%s Next Item", mappings.next_item))
	table.insert(actions, string.format("%s Prev Item", mappings.prev_item))
	table.insert(actions, string.format("%s Quit", mappings.quit))

	local lines = { "" }
	for _, a in ipairs(actions) do
		table.insert(lines, "   " .. a)
	end

	return lines
end

-- Compute window size from FINAL content (no user width/height overrides) ----

local function compute_window_size(lines)
	-- Width based on display width (icons, wide chars)
	local width = 0
	for _, l in ipairs(lines) do
		local w = vim.fn.strdisplaywidth(l)
		if w > width then
			width = w
		end
	end
	width = width + 2 -- small margin

	-- Height is number of lines in content, plus +1 visual bottom pad
	local desired = #lines + 1

	-- Clamp to available editor space (leave tiny safety margin)
	local avail_h = math.max(1, (vim.o.lines or desired) - 2)
	local height = math.min(desired, avail_h)

	return width, height
end

-- ===== Rendering & Highlighting ============================================

local function render_highlights(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)

	-- Highlight section headers & underlines
	local h = menu_model.header or {}
	if h.global and h.global.header then
		vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", h.global.header - 1, 0, -1)
	end
	if h.global and h.global.underline then
		vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", h.global.underline - 1, 0, -1)
	end
	if h.branch and h.branch.header then
		vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", h.branch.header - 1, 0, -1)
	end
	if h.branch and h.branch.underline then
		vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", h.branch.underline - 1, 0, -1)
	end

	-- Highlight current file line (if any)
	if menu_model.current_line > 0 then
		vim.api.nvim_buf_add_highlight(bufnr, -1, "ArrowCurrentFile", menu_model.current_line - 1, 0, -1)
	end

	-- Highlight the “index key” (3rd col) and icon groups on entries
	for _, e in ipairs(menu_model.entries) do
		vim.api.nvim_buf_add_highlight(bufnr, -1, "ArrowFileIndex", e.line - 1, 3, 4)
		if e.icon_hl then
			vim.api.nvim_buf_add_highlight(bufnr, -1, e.icon_hl, e.line - 1, 5, 8)
		end
	end

	-- Highlight action area keys and current mode indicators
	local mappings = config.getState("mappings")

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for i = 1, line_count do
		local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""

		-- First token highlight on each handbook line
		if line:match("^%s+[%w%p]%s") then
			vim.api.nvim_buf_add_highlight(bufnr, -1, "ArrowAction", i - 1, 3, 4)
		end

		-- Mode indicators
		if line:find((mappings.delete_mode or "d") .. " Delete Mode", 1, true) then
			if vim.b.arrow_current_mode == "delete_mode" then
				vim.api.nvim_buf_add_highlight(bufnr, -1, "ArrowDeleteMode", i - 1, 0, -1)
			end
		elseif line:find((mappings.open_vertical or "v") .. " Open Vertical", 1, true) then
			if vim.b.arrow_current_mode == "vertical_mode" then
				vim.api.nvim_buf_add_highlight(bufnr, -1, "ArrowAction", i - 1, 0, -1)
			end
		elseif line:find((mappings.open_horizontal or "-") .. " Open Horizontal", 1, true) then
			if vim.b.arrow_current_mode == "horizontal_mode" then
				vim.api.nvim_buf_add_highlight(bufnr, -1, "ArrowAction", i - 1, 0, -1)
			end
		end
	end
end

local function closeMenu()
	local win = vim.fn.win_getid()
	if win ~= 0 and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
end

local function open_target(fileName)
	local action

	fileName = vim.fn.fnameescape(fileName)

	if vim.b.arrow_current_mode == "" or not vim.b.arrow_current_mode then
		action = config.getState("open_action")
	elseif vim.b.arrow_current_mode == "vertical_mode" then
		action = config.getState("vertical_action")
	elseif vim.b.arrow_current_mode == "horizontal_mode" then
		action = config.getState("horizontal_action")
	end

	closeMenu()
	vim.api.nvim_exec_autocmds("User", { pattern = "ArrowOpenFile" })

	if
		config.getState("global_bookmarks") == true
		or config.getState("save_key_name") == "cwd"
		or config.getState("save_key_name") == "git_root_bare"
	then
		action(fileName, vim.b.filename)
	else
		action(config.getState("save_key_cached") .. "/" .. fileName, vim.b.filename)
	end
end

-- ===== Public UI ============================================================

function M.openMenu(bufnr)
	git.refresh_git_branch()

	local call_buffer = bufnr or vim.api.nvim_get_current_buf()

	if vim.g.arrow_filenames == 0 then
		persist.load_cache_file()
	end

	local filename
	if config.getState("global_bookmarks") == true then
		filename = vim.fn.expand("%:p")
	else
		filename = utils.get_current_buffer_path()
	end

	-- Build sections (GLOBAL first, then BRANCH)
	menu_model = build_menu_model(filename)

	-- Build actions “handbook” and append to lines *before* rendering buffer
	local action_lines = build_actions_lines(filename)
	for _, l in ipairs(action_lines) do
		table.insert(menu_model.lines, l)
	end

	-- Compute window size from FINAL content (with padding)
	local width, height = compute_window_size(menu_model.lines)

	-- Create buffer & window
	local menuBuf = vim.api.nvim_create_buf(false, true)
	vim.b[menuBuf].filename = filename
	vim.b[menuBuf].arrow_current_mode = ""

	local ui_config = config.getState("ui") or {}

	local final_config = {
		relative = ui_config.relative or "editor",
		style = ui_config.style or "minimal",
		border = ui_config.border or "single",
		width = width,
		height = height,
	}

	-- Positioning after we know height/width (no user overrides of size)
	local win_width = vim.o.columns
	local win_height = vim.o.lines
	local row, col
	local position = ui_config.position or "center"
	if position == "center" then
		row = math.floor((win_height - final_config.height) / 2)
		col = math.floor((win_width - final_config.width) / 2)
	elseif position == "top-left" then
		row = 0
		col = 0
	elseif position == "top-center" then
		row = 0
		col = math.floor((win_width - final_config.width) / 2)
	elseif position == "top-right" then
		row = 0
		col = win_width - final_config.width
	elseif position == "middle-left" then
		row = math.floor((win_height - final_config.height) / 2)
		col = 0
	elseif position == "middle-right" then
		row = math.floor((win_height - final_config.height) / 2)
		col = win_width - final_config.width
	elseif position == "bottom-left" then
		row = win_height - final_config.height
		col = 0
	elseif position == "bottom-center" then
		row = win_height - final_config.height
		col = math.floor((win_width - final_config.width) / 2)
	elseif position == "bottom-right" then
		row = win_height - final_config.height
		col = win_width - final_config.width
	else
		row = math.floor((win_height - final_config.height) / 2)
		col = math.floor((win_width - final_config.width) / 2)
	end
	final_config.row = (ui_config.row and ui_config.row ~= "auto") and ui_config.row or row
	final_config.col = (ui_config.col and ui_config.col ~= "auto") and ui_config.col or col

	local win = vim.api.nvim_open_win(menuBuf, true, final_config)

	-- Write final lines to buffer now
	vim.api.nvim_buf_set_option(menuBuf, "modifiable", true)
	vim.api.nvim_buf_set_lines(menuBuf, 0, -1, false, menu_model.lines)
	vim.api.nvim_buf_set_option(menuBuf, "modifiable", false)
	vim.api.nvim_buf_set_option(menuBuf, "buftype", "nofile")

	-- Make bottom pad visually clean (no ~)
	local prev_fill = vim.wo.fillchars or ""
	if not prev_fill:match("eob:") then
		vim.wo.fillchars = (prev_fill == "" and "eob: ") or (prev_fill .. ",eob: ")
	end

	-- Entry selection keymaps
	local menuKeymapOpts = { noremap = true, silent = true, buffer = menuBuf, nowait = true }
	for _, e in ipairs(menu_model.entries) do
		vim.keymap.set("n", e.key, function()
			if vim.b.arrow_current_mode == "delete_mode" then
				persist.remove(e.filename) -- removes from permanent if present, else from branch
				closeMenu()
				vim.schedule(function()
					M.openMenu(call_buffer)
				end)
			else
				open_target(e.filename)
			end
		end, menuKeymapOpts)
	end

	-- Actions (save/toggle/etc) keymaps
	local mappings = config.getState("mappings")
	vim.keymap.set("n", config.getState("leader_key"), closeMenu, menuKeymapOpts)

	local buffer_leader_key = config.getState("buffer_leader_key")
	if buffer_leader_key then
		vim.keymap.set("n", buffer_leader_key, function()
			closeMenu()
			vim.schedule(function()
				require("arrow.buffer_ui").openMenu(call_buffer)
			end)
		end, menuKeymapOpts)
	end

	vim.keymap.set("n", mappings.quit, closeMenu, menuKeymapOpts)
	vim.keymap.set("n", mappings.edit, function()
		closeMenu()
		persist.open_cache_file()
	end, menuKeymapOpts)

	if config.getState("separate_save_and_remove") then
		vim.keymap.set("n", mappings.toggle, function()
			persist.save(filename or utils.get_current_buffer_path())
			closeMenu()
		end, menuKeymapOpts)

		vim.keymap.set("n", mappings.remove, function()
			persist.remove(filename or utils.get_current_buffer_path())
			closeMenu()
		end, menuKeymapOpts)
	else
		vim.keymap.set("n", mappings.toggle, function()
			persist.toggle(filename)
			closeMenu()
		end, menuKeymapOpts)
	end

	vim.keymap.set("n", mappings.clear_all_items, function()
		persist.clear()
		closeMenu()
	end, menuKeymapOpts)

	if mappings.toggle_permanent then
		vim.keymap.set("n", mappings.toggle_permanent, function()
			persist.toggle_permanent(filename or utils.get_current_buffer_path())
			closeMenu()
		end, menuKeymapOpts)
	end

	vim.keymap.set("n", mappings.next_item, function()
		closeMenu()
		persist.next()
	end, menuKeymapOpts)

	vim.keymap.set("n", mappings.prev_item, function()
		closeMenu()
		persist.previous()
	end, menuKeymapOpts)

	vim.keymap.set("n", "<Esc>", closeMenu, menuKeymapOpts)

	vim.keymap.set("n", mappings.delete_mode, function()
		vim.b.arrow_current_mode = (vim.b.arrow_current_mode == "delete_mode") and "" or "delete_mode"
		render_highlights(menuBuf)
	end, menuKeymapOpts)

	vim.keymap.set("n", mappings.open_vertical, function()
		vim.b.arrow_current_mode = (vim.b.arrow_current_mode == "vertical_mode") and "" or "vertical_mode"
		render_highlights(menuBuf)
	end, menuKeymapOpts)

	vim.keymap.set("n", mappings.open_horizontal, function()
		vim.b.arrow_current_mode = (vim.b.arrow_current_mode == "horizontal_mode") and "" or "horizontal_mode"
		render_highlights(menuBuf)
	end, menuKeymapOpts)

	-- Cursor & highlight behavior
	vim.api.nvim_set_hl(0, "ArrowCursor", { nocombine = true, blend = 100 })
	vim.opt.guicursor:append("a:ArrowCursor/ArrowCursor")

	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = 0,
		desc = "Disable Cursor",
		once = true,
		callback = function()
			vim.cmd("highlight clear ArrowCursor")
			vim.schedule(function()
				vim.opt.guicursor:remove("a:ArrowCursor/ArrowCursor")
			end)
		end,
	})

	-- disable cursorline for this buffer
	vim.wo.cursorline = false

	-- Render highlights after content is in place
	render_highlights(menuBuf)
end

return M
