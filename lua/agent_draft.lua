-- A per-worktree draft for prompts: collect code and files from anywhere, write
-- the prompt in a normal buffer, then paste it all into the opencode TUI pane.
local M = {}

local DRAFT_FILE = "draft.md"
local LAST_FILE = "last-draft.md" -- the last sent or discarded draft, in case you want it back

local MENU = {
	"s  Send to current session",
	"n  New session, then send",
	"y  Copy to clipboard",
	"f  Add files",
	"d  Discard draft",
	"q  Cancel",
}

local function git_root()
	local res = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = vim.fn.getcwd(), text = true }):wait()
	if res.code ~= 0 then
		vim.notify("Not in a git repository", vim.log.levels.ERROR)
		return nil
	end
	return vim.trim(res.stdout)
end

local function draft_dir(root)
	local review = require("agent_review")
	review.exclude_review_dir(root)
	local dir = root .. "/" .. review.REVIEW_DIR
	vim.fn.mkdir(dir, "p")
	return dir
end

-- ============================================================================
-- Draft contents
-- ============================================================================
---Find the labelled code blocks at the start of a draft.
---@return integer count
---@return integer last line of the last block, 0 when there are none
local function scan_snippets(lines)
	local count, last = 0, 0
	local i = 1
	while i < #lines do
		local fence = lines[i + 1]:match("^(```+)%S*$")
		if lines[i]:match("^`[^`]+`$") and fence then
			for j = i + 2, #lines do
				if lines[j] == fence then
					count, last = count + 1, j
					i = j
					break
				end
			end
		end
		i = i + 1
	end
	return count, last
end

local function file_line(lines)
	for i, line in ipairs(lines) do
		local files = line:match("^Files: (.*)$")
		if files then
			return i, vim.split(files, ", ", { plain = true, trimempty = true })
		end
	end
	return nil, {}
end

local function update_winbar(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local snippets = scan_snippets(lines)
	local _, files = file_line(lines)
	local winbar = string.format(" AI draft · %d snippet%s · %d file%s", snippets, snippets == 1 and "" or "s", #files, #files == 1 and "" or "s")
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		vim.wo[win].winbar = winbar
	end
end

local function save(buf)
	vim.api.nvim_buf_call(buf, function()
		vim.cmd("silent! write")
	end)
end

-- ============================================================================
-- Draft window
-- ============================================================================
local function close_windows(buf)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) > 1 then
			vim.api.nvim_win_close(win, false)
		else
			vim.api.nvim_win_call(win, function()
				vim.cmd("enew")
			end)
		end
	end
end

local function get_buf(root)
	local buf = vim.fn.bufadd(draft_dir(root) .. "/" .. DRAFT_FILE)
	vim.fn.bufload(buf)
	if vim.b[buf].agent_draft then
		return buf
	end

	vim.b[buf].agent_draft = true
	vim.bo[buf].buflisted = false
	-- Quitting only hides the pane, and every change is on disk straight away
	vim.keymap.set("n", "q", function()
		save(buf)
		close_windows(buf)
	end, { buffer = buf, nowait = true, desc = "Close the draft pane and keep the draft" })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
		buffer = buf,
		callback = function(args)
			update_winbar(buf)
			if args.event ~= "TextChangedI" then
				save(buf)
			end
		end,
	})
	return buf
end

---Show the draft below everything in this tab, leaving the cursor where it is.
local function show(buf)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	local win = vim.api.nvim_open_win(buf, false, {
		split = "below",
		win = -1,
		height = math.floor(vim.o.lines * 0.4),
	})
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].colorcolumn = ""
	vim.wo[win].winfixheight = true
	update_winbar(buf)
	return win
end

local function insert(buf, win, at, block)
	vim.api.nvim_buf_set_lines(buf, at, at, false, block)
	vim.api.nvim_win_set_cursor(win, { at + #block, 0 })
	save(buf)
	update_winbar(buf)
end

-- Context stays above the prompt you are writing, in the order you added it
local function context_end(lines)
	local _, last = scan_snippets(lines)
	if last > 0 and lines[last + 1] == "" then
		return last + 1
	end
	return last
end

---@return string label like `src/auth.py:40-42`, relative to the worktree
local function location(root, first, last)
	local name = vim.api.nvim_buf_get_name(0)
	local path
	-- The old side of a review is a virtual buffer: codediff:///<repo>///<rev>/<path>
	local rev, old_path = name:match("^codediff:.*///([^/]+)/(.+)$")
	if rev then
		path = old_path .. "@" .. rev:sub(1, 7)
	elseif name == "" or vim.bo.buftype ~= "" then
		path = "selection"
	else
		local real = vim.uv.fs_realpath(name) or name
		path = vim.fs.relpath(root, real) or vim.fn.fnamemodify(real, ":~")
	end
	return first == last and string.format("%s:%d", path, first) or string.format("%s:%d-%d", path, first, last)
end

local function add_selection(root)
	local mode = vim.fn.mode()
	local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
	local code = vim.fn.getregion(from, to, { type = mode })
	local first, last = math.min(from[2], to[2]), math.max(from[2], to[2])
	local label = location(root, first, last)
	local filetype = vim.bo.filetype
	vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)

	-- A fence longer than any backticks in the code, so the code cannot end the block early
	local fence = "```"
	for _, line in ipairs(code) do
		local ticks = line:match("^%s*(```+)")
		if ticks and #ticks >= #fence then
			fence = ticks .. "`"
		end
	end

	local buf = get_buf(root)
	local win = show(buf)
	local block = { "`" .. label .. "`", fence .. filetype }
	vim.list_extend(block, code)
	vim.list_extend(block, { fence, "" })
	insert(buf, win, context_end(vim.api.nvim_buf_get_lines(buf, 0, -1, false)), block)
end

local function add_paths(root, paths)
	local buf = get_buf(root)
	local win = show(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local at, files = file_line(lines)
	for _, path in ipairs(paths) do
		if not vim.tbl_contains(files, path) then
			table.insert(files, path)
		end
	end
	local line = "Files: " .. table.concat(files, ", ")
	if at then
		vim.api.nvim_buf_set_lines(buf, at - 1, at, false, { line })
		save(buf)
		update_winbar(buf)
	else
		insert(buf, win, context_end(lines), { line, "" })
	end
end

local function add_tree_node(root)
	local node = require("nvim-tree.api").tree.get_node_under_cursor()
	if node and node.absolute_path then
		local real = vim.uv.fs_realpath(node.absolute_path) or node.absolute_path
		add_paths(root, { vim.fs.relpath(root, real) or real })
	end
end

local function pick_files(root)
	local fzf = require("fzf-lua")
	fzf.files({
		actions = {
			["default"] = function(selected, opts)
				add_paths(
					root,
					vim.tbl_map(function(entry)
						return vim.fn.fnamemodify(fzf.path.entry_to_file(entry, opts).path, ":.")
					end, selected)
				)
			end,
		},
	})
end

-- ============================================================================
-- Sending to the TUI
-- ============================================================================
local function tmux(args)
	local res = vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait()
	return res.code == 0, res.stdout or ""
end

---@return string|nil pane id of the opencode TUI in this tmux window
---@return string|nil err why there is nothing to send to
local function find_pane()
	if not vim.env.TMUX then
		return nil, "Neovim is not running inside tmux"
	end
	local ok, out = tmux({ "list-panes", "-t", vim.env.TMUX_PANE, "-F", "#{pane_id} #{pane_current_command}" })
	if ok then
		for line in vim.gsplit(out, "\n", { trimempty = true }) do
			local id, command = line:match("^(%S+) (.*)$")
			if command and command:match("opencode") then
				return id
			end
		end
	end
	return nil, "No opencode pane in this tmux window"
end

---Enter would act on an open dialog, for example approving a permission request,
---so only send when the prompt bar is showing and nothing is drawn over it.
local function tui_ready(pane)
	local ok, screen = tmux({ "capture-pane", "-p", "-t", pane })
	if not ok then
		return false
	end
	local bar = false
	for line in vim.gsplit(screen, "\n", { plain = true }) do
		if line:match("%s%s+esc%s*$") then
			return false
		end
		bar = bar or line:find("╹" .. string.rep("▀", 20), 1, true) ~= nil
	end
	return bar
end

local function draft_text(buf)
	return vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
end

local function clear(buf)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
	save(buf)
	update_winbar(buf)
	close_windows(buf)
end

local function keep_last(root, text)
	local path = draft_dir(root) .. "/" .. LAST_FILE
	vim.fn.writefile(vim.split(text, "\n"), path, "b")
	return path
end

local function send(root, buf, new_session)
	local text = draft_text(buf)
	if text == "" then
		vim.notify("The draft is empty", vim.log.levels.WARN)
		return
	end
	local pane, err = find_pane()
	if not pane then
		vim.notify(err .. ", draft kept. Use y to copy it instead", vim.log.levels.ERROR)
		return
	end
	-- Keys sent to a pane in copy mode would drive copy mode, not the TUI
	tmux({ "send-keys", "-t", pane, "-X", "cancel" })
	if not tui_ready(pane) then
		vim.notify("The opencode pane has a dialog open, draft kept. Deal with it and send again", vim.log.levels.WARN)
		return
	end

	local path = keep_last(root, text)
	local function paste()
		if not tmux({ "load-buffer", "-b", "agent-draft", path }) or not tmux({ "paste-buffer", "-p", "-d", "-b", "agent-draft", "-t", pane }) then
			vim.notify("Could not paste into the opencode pane, draft kept", vim.log.levels.ERROR)
			return
		end
		-- The TUI needs a moment to take the paste before Enter submits it
		vim.defer_fn(function()
			tmux({ "send-keys", "-t", pane, "Enter" })
			clear(buf)
			vim.notify(new_session and "Sent to a new session" or "Sent to the current session")
		end, 500)
	end

	if not new_session then
		paste()
		return
	end
	tmux({ "send-keys", "-t", pane, "C-x" })
	vim.defer_fn(function()
		tmux({ "send-keys", "-t", pane, "n" })
		vim.defer_fn(paste, 1000)
	end, 200)
end

local function copy(buf)
	local text = draft_text(buf)
	if text == "" then
		vim.notify("The draft is empty", vim.log.levels.WARN)
		return
	end
	vim.fn.setreg("+", text)
	vim.notify("Draft copied to the clipboard")
end

local function discard(root, buf)
	local text = draft_text(buf)
	if text == "" then
		close_windows(buf)
		return
	end
	local path = keep_last(root, text)
	clear(buf)
	vim.notify("Draft discarded, a copy is in " .. vim.fn.fnamemodify(path, ":."))
end

-- ============================================================================
-- <leader>a
-- ============================================================================
---Show the menu and wait for one key.
local function read_choice()
	local width = 0
	for _, item in ipairs(MENU) do
		width = math.max(width, vim.fn.strdisplaywidth(item))
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, MENU)
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "win",
		row = 1,
		col = 2,
		width = width + 2,
		height = #MENU,
		style = "minimal",
		border = "rounded",
		title = " Send draft ",
	})
	vim.cmd("redraw")
	local ok, choice = pcall(vim.fn.getcharstr)
	vim.api.nvim_win_close(win, true)
	vim.api.nvim_buf_delete(buf, { force = true })
	return ok and choice or nil
end

local function menu(root, buf)
	local choice = read_choice()
	if choice == "s" then
		send(root, buf, false)
	elseif choice == "n" then
		send(root, buf, true)
	elseif choice == "y" then
		copy(buf)
	elseif choice == "f" then
		pick_files(root)
	elseif choice == "d" then
		discard(root, buf)
	end
end

---The one AI shortcut: what it does depends on where you are.
function M.leader_a()
	local root = git_root()
	if not root then
		return
	end
	local visual = vim.fn.mode():match("^[vV\22]") ~= nil

	if vim.b.agent_draft then
		if visual then
			vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
		end
		menu(root, vim.api.nvim_get_current_buf())
	elseif visual then
		add_selection(root)
	elseif vim.bo.filetype == "NvimTree" then
		add_tree_node(root)
	else
		local buf = get_buf(root)
		local win = show(buf)
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
	end
end

return M
