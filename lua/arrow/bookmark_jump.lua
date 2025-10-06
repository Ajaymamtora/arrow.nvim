local M = {}

local persist = require("arrow.persist")

function M.open_bookmark_by_number(n)
	persist.load_cache_file()
	local bookmarks = vim.g.arrow_filenames

	if bookmarks and #bookmarks >= n and n > 0 then
		persist.go_to(n)
	else
		vim.notify("Bookmark " .. n .. " not found.", vim.log.levels.WARN)
	end
end

return M