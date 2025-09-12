local M = {}

local config = require("arrow.config")
local utils = require("arrow.utils")

-- Cache for git operations
local git_cache = {
	branch = nil,
	branch_timestamp = 0,
	is_git_repo = nil,
	repo_timestamp = 0,
	cache_ttl = 1000, -- 1 second TTL
}

local function get_current_time()
	return vim.uv.hrtime() / 1000000 -- Convert to milliseconds
end

local function is_cache_valid(timestamp)
	return (get_current_time() - timestamp) < git_cache.cache_ttl
end

function M.invalidate_cache()
	git_cache.branch = nil
	git_cache.branch_timestamp = 0
	git_cache.is_git_repo = nil
	git_cache.repo_timestamp = 0
end

function M.is_git_repo()
	if git_cache.is_git_repo ~= nil and is_cache_valid(git_cache.repo_timestamp) then
		return git_cache.is_git_repo
	end
	
	local git_files = vim.fs.find(".git", { upward = true, stop = vim.uv.os_homedir() })
	git_cache.is_git_repo = git_files and #git_files > 0
	git_cache.repo_timestamp = get_current_time()
	
	return git_cache.is_git_repo
end

function M.get_git_branch()
	-- Return cached result if valid
	if git_cache.branch and is_cache_valid(git_cache.branch_timestamp) then
		return git_cache.branch
	end

	if not M.is_git_repo() then
		git_cache.branch = nil
		git_cache.branch_timestamp = get_current_time()
		return nil
	end

	-- Return cached branch or nil if we need to avoid fast event context
	-- This function should primarily be used for cached results
	-- For fresh data, use get_git_branch_async instead
	if git_cache.branch ~= nil then
		return git_cache.branch
	end

	-- If we can't get the branch due to fast event context, return nil
	-- and schedule an async update for next time
	vim.schedule(function()
		M.get_git_branch_async(function(branch)
			-- This will update the cache for future calls
		end)
	end)

	return nil
end

function M.get_git_branch_async(callback)
	-- Return cached result if valid
	if git_cache.branch and is_cache_valid(git_cache.branch_timestamp) then
		callback(git_cache.branch)
		return
	end

	if not M.is_git_repo() then
		git_cache.branch = nil
		git_cache.branch_timestamp = get_current_time()
		callback(nil)
		return
	end

	-- Use async vim.system for non-blocking git calls
	vim.system(
		{ "git", "symbolic-ref", "--short", "HEAD" },
		{ text = true },
		function(obj)
			local branch = nil
			if obj.code == 0 and obj.stdout then
				branch = vim.trim(string.gsub(obj.stdout, "\n", ""))
				branch = branch ~= "" and branch or nil
			end
			
			-- Cache the result
			git_cache.branch = branch
			git_cache.branch_timestamp = get_current_time()
			
			callback(branch)
		end
	)
end

function M.refresh_git_branch()
	if vim.v.vim_did_enter ~= 1 then
		return config.getState("current_branch")
	end
	
	if not config.getState("separate_by_branch") then
		return config.getState("current_branch")
	end
	
	local current_branch = config.getState("current_branch")
	local new_branch = M.get_git_branch()

	if current_branch ~= new_branch then
		config.setState("current_branch", new_branch)
		require("arrow.persist").load_cache_file()

		vim.schedule(function()
			local buffer_persist = require("arrow.buffer_persist")
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if
					vim.api.nvim_buf_is_valid(bufnr)
					and vim.api.nvim_buf_is_loaded(bufnr)
					and vim.bo[bufnr].buflisted
				then
					local bufname = utils.safe_buf_get_name(bufnr)
					if bufname and bufname ~= "" then
						buffer_persist.invalidate_buffer_cache(bufnr)
						buffer_persist.clear_buffer_ext_marks(bufnr)
						buffer_persist.load_buffer_bookmarks(bufnr)
					end
				end
			end
		end)
	end

	return config.getState("current_branch")
end

function M.refresh_git_branch_async(callback)
	if vim.v.vim_did_enter ~= 1 then
		callback(config.getState("current_branch"))
		return
	end
	
	if not config.getState("separate_by_branch") then
		callback(config.getState("current_branch"))
		return
	end
	
	local current_branch = config.getState("current_branch")
	
	M.get_git_branch_async(function(new_branch)
		if current_branch ~= new_branch then
			config.setState("current_branch", new_branch)
			require("arrow.persist").load_cache_file()

			vim.schedule(function()
				local buffer_persist = require("arrow.buffer_persist")
				for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
					if
						vim.api.nvim_buf_is_valid(bufnr)
						and vim.api.nvim_buf_is_loaded(bufnr)
						and vim.bo[bufnr].buflisted
					then
						local bufname = utils.safe_buf_get_name(bufnr)
						if bufname and bufname ~= "" then
							buffer_persist.invalidate_buffer_cache(bufnr)
							buffer_persist.clear_buffer_ext_marks(bufnr)
							buffer_persist.load_buffer_bookmarks(bufnr)
						end
					end
				end
			end)
		end
		
		callback(config.getState("current_branch"))
	end)
end

return M
