-- Test for arrow.bookmark_jump
--
-- To run this test:
-- 1. Make sure you have a testing framework like busted installed.
-- 2. Run `busted tests/bookmark_jump_test.lua` from the root of the project.

describe("arrow.bookmark_jump", function()
  local bookmark_jump = require("arrow.bookmark_jump")
  local persist = require("arrow.persist")

  -- Mock the persist module
  local mock_persist = {
    load_cache_file = function() end,
    go_to = function(n) end,
  }

  -- Stub the original persist module
  _G.arrow_persist_original = persist
  package.loaded["arrow.persist"] = mock_persist

  -- Restore the original persist module after the tests
  teardown(function()
    package.loaded["arrow.persist"] = _G.arrow_persist_original
    _G.arrow_persist_original = nil
  end)

  it("should call persist.go_to with the correct index", function()
    -- Spy on the go_to function
    local go_to_spy = spy.on(mock_persist, "go_to")

    -- Set up the bookmarks
    vim.g.arrow_filenames = { "/tmp/file1.txt", "/tmp/file2.txt" }

    -- Call the function to be tested
    bookmark_jump.open_bookmark_by_number(2)

    -- Assert that the spy was called with the correct argument
    assert.spy(go_to_spy).was.called_with(2)
  end)

  it("should show a notification if the bookmark is not found", function()
    -- Spy on vim.notify
    local notify_spy = spy.on(vim, "notify")

    -- Set up the bookmarks
    vim.g.arrow_filenames = { "/tmp/file1.txt" }

    -- Call the function with an invalid index
    bookmark_jump.open_bookmark_by_number(2)

    -- Assert that vim.notify was called
    assert.spy(notify_spy).was.called()
  end)
end)
