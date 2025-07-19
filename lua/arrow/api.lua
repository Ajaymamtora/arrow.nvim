local M = {}

local config = require("arrow.config")
local persist = require("arrow.persist")
local buffer_persist = require("arrow.buffer_persist")
local git = require("arrow.git")

-- User API for external event triggering
-- This allows users to integrate arrow with their own git hooks, file watchers, etc.

function M.on_git_branch_changed(new_branch)
	if config.getState("separate_by_branch") then
		local current_branch = config.getState("current_branch")
		
		if current_branch ~= new_branch then
			config.setState("current_branch", new_branch)
			git.invalidate_cache()
			
			vim.schedule(function()
				persist.load_cache_file()
				
				-- Refresh all loaded buffer bookmarks for the new branch
				for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
						local bufname = vim.api.nvim_buf_get_name(bufnr)
						if bufname and bufname ~= "" then
							buffer_persist.invalidate_buffer_cache(bufnr)
							buffer_persist.load_buffer_bookmarks(bufnr)
						end
					end
				end
				
				vim.api.nvim_exec_autocmds("User", { pattern = "ArrowGitBranchChanged" })
			end)
		end
	end
end

function M.on_git_head_changed()
	if config.getState("separate_by_branch") then
		vim.schedule(function()
			git.refresh_git_branch_async(function(branch)
				if branch then
					M.on_git_branch_changed(branch)
				end
			end)
		end)
	end
end

function M.on_directory_changed(new_cwd)
	config.setState("save_key_cached", config.getState("save_key")())
	
	vim.schedule(function()
		git.refresh_git_branch_async(function(branch)
			if branch then
				config.setState("current_branch", branch)
			end
			persist.load_cache_file()
			vim.api.nvim_exec_autocmds("User", { pattern = "ArrowDirectoryChanged" })
		end)
	end)
end

function M.refresh_all()
	vim.schedule(function()
		git.refresh_git_branch_async(function(branch)
			if branch then
				config.setState("current_branch", branch)
			end
			config.setState("save_key_cached", config.getState("save_key")())
			
			persist.load_cache_file()
			require("arrow.global_bookmarks").load_cache_file()
			
			local bufnr = vim.api.nvim_get_current_buf()
			if vim.api.nvim_buf_is_valid(bufnr) then
				buffer_persist.load_buffer_bookmarks(bufnr)
			end
			
			vim.api.nvim_exec_autocmds("User", { pattern = "ArrowRefreshComplete" })
		end)
	end)
end

function M.invalidate_git_cache()
	git.invalidate_cache()
end

function M.invalidate_buffer_cache(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	buffer_persist.invalidate_buffer_cache(bufnr)
end

return M