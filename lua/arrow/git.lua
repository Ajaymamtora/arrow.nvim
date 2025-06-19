local M = {}

local config = require("arrow.config")

function M.get_git_branch()
	local git_files = vim.fs.find(".git", { upward = true, stop = vim.uv.os_homedir() })

	if git_files then
		local result = vim.fn.system({ "git", "symbolic-ref", "--short", "HEAD" })

		return vim.trim(string.gsub(result, "\n", ""))
	else
		return nil
	end
end

-- vvvvvvvv  MODIFIED FUNCTION vvvvvvvv
function M.refresh_git_branch()
	if config.getState("separate_by_branch") then
		local current_branch = config.getState("current_branch")
		local new_branch = M.get_git_branch()

		if current_branch ~= new_branch then
			-- Update branch and reload file-level bookmarks
			config.setState("current_branch", new_branch)
			require("arrow.persist").load_cache_file()

			-- [[ ADDED: Reload line-level bookmarks for all open buffers ]]
			local buffer_persist = require("arrow.buffer_persist")
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
					-- Only act on buffers that already have bookmarks loaded
					if buffer_persist.local_bookmarks[bufnr] ~= nil then
						-- Invalidate cache to force a reload from disk
						buffer_persist.local_bookmarks[bufnr] = nil
						buffer_persist.last_sync_bookmarks[bufnr] = nil

						-- Clear old UI markers
						buffer_persist.clear_buffer_ext_marks(bufnr)

						-- Reload bookmarks, which will now use the correct branch path
						buffer_persist.load_buffer_bookmarks(bufnr)
					end
				end
			end
		end
	end

	return config.getState("current_branch")
end
-- ^^^^^^^^ END OF MODIFIED FUNCTION ^^^^^^^^

return M
