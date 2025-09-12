local M = {}

function M.cwd()
	return vim.uv.cwd()
end

function M.git_root(callback)
	vim.system({ "git", "rev-parse", "--show-toplevel" }, { text = true }, function(obj)
		if obj.code == 0 and obj.stdout then
			callback(obj.stdout:gsub("\n$", ""))
		else
			callback(M.cwd())
		end
	end)
end

function M.git_root_bare(callback)
	vim.system(
		{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ text = true },
		function(obj)
			if obj.code == 0 and obj.stdout then
				local git_bare_root = obj.stdout:gsub("/%%.git\n$", "")
				callback(git_bare_root:gsub("\n$", ""))
			else
				callback(M.cwd())
			end
		end
	)
end

return M