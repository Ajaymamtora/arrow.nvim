local M = {}

local config = require("arrow.config")

function M.get_git_branch()
	local git_files = vim.fs.find(".git", { upward = true, stop = vim.loop.os_homedir() })

	if git_files then
		local result = vim.fn.system({ "git", "symbolic-ref", "--short", "HEAD" })

		return vim.trim(string.gsub(result, "\n", ""))
	else
		return nil
	end
end

-- vvvvvvvv  MODIFIED FUNCTION vvvvvvvv
function M.refresh_git_branch()
	if vim.v.vim_did_enter ~= 1 then
		return
	end
	if config.getState("separate_by_branch") then
		local current_branch = config.getState("current_branch")
		local new_branch = M.get_git_branch()

		if current_branch ~= new_branch then
			-- Update branch and reload the main file-level bookmark list
			config.setState("current_branch", new_branch)
			require("arrow.persist").load_cache_file()

			-- Defer the line bookmark reload to avoid race conditions on startup/session-load.
			-- This ensures buffers are fully loaded before we try to update them.
			vim.schedule(function()
				local buffer_persist = require("arrow.buffer_persist")
				for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
					-- Check if the buffer is valid, loaded, and listed
					if
						vim.api.nvim_buf_is_valid(bufnr)
						and vim.api.nvim_buf_is_loaded(bufnr)
						and vim.bo[bufnr].buflisted
					then
						local bufname = vim.api.nvim_buf_get_name(bufnr)
						if bufname and bufname ~= "" then
							-- Forcefully invalidate the cache for this buffer
							buffer_persist.local_bookmarks[bufnr] = nil
							buffer_persist.last_sync_bookmarks[bufnr] = nil

							-- Clear any old markers from the UI
							buffer_persist.clear_buffer_ext_marks(bufnr)

							-- Trigger a fresh load from disk. This will now use the correct
							-- branch-specific file path.
							buffer_persist.load_buffer_bookmarks(bufnr)
						end
					end
				end
			end)
		end
	end

	return config.getState("current_branch")
end
-- ^^^^^^^^ END OF MODIFIED FUNCTION ^^^^^^^^

return M
