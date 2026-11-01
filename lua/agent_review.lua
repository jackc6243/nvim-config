-- Sends your review back to the agent: review.nvim comments plus the edits you
-- made by hand, measured against a snapshot taken when the review was opened.
local M = {}

local REF = "refs/worktree/agent-review/baseline" -- refs/worktree/* is per worktree
local REVIEW_DIR = ".agent-review"
local REVIEW_FILE = REVIEW_DIR .. "/latest.md"

local PROMPT = "I reviewed your changes. Read "
	.. REVIEW_FILE
	.. " and address everything in it. The edits it lists are mine and are already in the"
	.. " working tree: keep them and follow their intent."

local function git(root, args, env)
	local cmd = vim.list_extend({ "git" }, args)
	local res = vim.system(cmd, { cwd = root, text = true, env = env }):wait()
	return res.code == 0, vim.trim(res.stdout or ""), res.stderr or ""
end

local function git_root()
	local ok, root = git(vim.fn.getcwd(), { "rev-parse", "--show-toplevel" })
	if not ok then
		vim.notify("Not in a git repository", vim.log.levels.ERROR)
		return nil
	end
	return root
end

-- Keep the review file out of snapshots and `git status` without touching .gitignore
local function exclude_review_dir(root)
	local _, path = git(root, { "rev-parse", "--path-format=absolute", "--git-path", "info/exclude" })
	local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
	if not vim.tbl_contains(lines, REVIEW_DIR .. "/") then
		vim.fn.mkdir(vim.fs.dirname(path), "p")
		table.insert(lines, REVIEW_DIR .. "/")
		vim.fn.writefile(lines, path)
	end
end
M.exclude_review_dir = exclude_review_dir
M.REVIEW_DIR = REVIEW_DIR

-- Tree of the working directory including untracked files, using a throwaway
-- index so whatever you have staged stays as it is
local function snapshot_tree(root)
	local index = vim.fn.tempname()
	local env = { GIT_INDEX_FILE = index }
	local ok, tree, err = git(root, { "add", "-A", "." }, env)
	if ok then
		ok, tree, err = git(root, { "write-tree" }, env)
	end
	vim.fn.delete(index)
	if not ok then
		vim.notify("Could not snapshot the working tree: " .. err, vim.log.levels.ERROR)
		return nil
	end
	return tree
end

local function baseline(root)
	local ok, tree = git(root, { "rev-parse", "--verify", "--quiet", REF })
	return ok and tree or nil
end

local function set_baseline(root)
	local tree = snapshot_tree(root)
	if tree then
		git(root, { "update-ref", REF, tree })
	end
end

---Open a review, remembering the code as it is now unless a review is already
---in progress, so reopening does not lose track of edits you have not sent.
---@param command string
function M.open(command)
	local root = git_root()
	if not root then
		return
	end
	exclude_review_dir(root)
	vim.cmd("silent! wall")
	if not baseline(root) then
		set_baseline(root)
	end
	vim.cmd(command)
end

---Start counting your edits from the current code.
function M.reset()
	local root = git_root()
	if not root then
		return
	end
	exclude_review_dir(root)
	vim.cmd("silent! wall")
	set_baseline(root)
	vim.notify("Review baseline reset")
end

local function your_edits(root)
	local base = baseline(root)
	if not base then
		return ""
	end
	local tree = snapshot_tree(root)
	if not tree or tree == base then
		return ""
	end
	local _, diff = git(root, { "diff", "--no-ext-diff", "--no-color", base, tree })
	return diff
end

---When the agent stops after a send, whatever you change next is your edit. An
---existing baseline is kept, since it may already be tracking edits you made.
---@param session_id string the session that stopped; events cover every worktree
function M.on_agent_idle(session_id)
	require("opencode.server.discovery")
		.get()
		:next(function(server)
			return server:get_sessions()
		end)
		:next(function(sessions)
			local cwd = vim.fn.getcwd()
			for _, session in ipairs(sessions) do
				if session.id == session_id and session.location and session.location.directory == cwd then
					local ok, root = git(cwd, { "rev-parse", "--show-toplevel" })
					if ok and not baseline(root) then
						exclude_review_dir(root)
						set_baseline(root)
					end
					return
				end
			end
		end)
		:catch(function() end)
end

---Send comments and your edits to the agent's most recent session in this directory.
function M.send()
	local root = git_root()
	if not root then
		return
	end
	exclude_review_dir(root)
	vim.cmd("silent! wall")

	local store = require("review.store")
	local comment_count = store.count()
	local diff = your_edits(root)
	if comment_count == 0 and diff == "" then
		vim.notify("No comments or edits to send", vim.log.levels.WARN)
		return
	end

	local sections = {}
	if comment_count > 0 then
		table.insert(sections, require("review.export").generate_markdown())
	end
	if diff ~= "" then
		table.insert(sections, "## Edits I made by hand\n\n```diff\n" .. diff .. "\n```")
	end
	vim.fn.mkdir(root .. "/" .. REVIEW_DIR, "p")
	vim.fn.writefile(vim.split(table.concat(sections, "\n\n"), "\n"), root .. "/" .. REVIEW_FILE)

	-- The public require("opencode").prompt() swallows errors, so go one level down
	require("opencode.server.discovery")
		.get()
		:next(function(server)
			return require("opencode.api.prompt").prompt(PROMPT, require("opencode.context").new(server))
		end)
		:next(function()
			-- Only forget the review once the agent has it, so a failed send can be retried
			require("review").clear()
			git(root, { "update-ref", "-d", REF })
			vim.notify(string.format("Sent %d comment(s) and %s to the agent", comment_count, diff ~= "" and "your edits" or "no edits"))
		end)
		:catch(function(err)
			vim.notify("Review not sent, comments kept: " .. tostring(err), vim.log.levels.ERROR)
		end)
end

return M
