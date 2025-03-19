--- *todox.nvim* Todo.txt manager for Neovim
--- *Todox*
---
--- MIT License Copyright (c) 2025 Hans Schnedlitz
---
--- ==============================================================================
---
--- A Todo.txt file manager that provides a comprehensive set of tools for
--- managing and organizing tasks following the todo.txt format specification.
---
--- Key features:
--- - Task management. create, edit, and toggle completion
--- - Task organization. Sort by priority, project, context, or due date
--- - Task categorization. Add priorities and project tags
--- - Supports multiple todo files, including per-project todos.
--- - Archiving. Move completed tasks to done.txt files
--- - Integration with fzf-lua for easy task selection and management
---
--- # Setup ~
---
--- This module needs a setup with `require('todox').setup({})` (replace
--- `{}` with your `config` table). It will create global Lua table `Todox`
--- which you can use for scripting or manually (with `:lua Todox.*`).
---
--- See |Todox.config| for available config settings.
---
--- # Dependencies ~
---
--- - fzf-lua: Required for task selection, tag management, and file picking
--- - nvim-treesitter (optional): For enhanced syntax highlighting
---
--- # Todo.txt Format ~
---
--- Todox follows the Todo.txt format specification (http://todotxt.org/):
--- - Tasks are stored one per line
--- - Priority is indicated with (A), (B), etc.
--- - Completion is marked with 'x' at the beginning
--- - Projects are tagged with +project
--- - Contexts are tagged with @context
--- - Creation date is in the format YYYY-MM-DD
--- - Metadata is stored as key:value

-- Module definition ==========================================================
local Todox = {}
local H = {}

-- Constants
local PRIORITIES = {
	{ value = "A", name = "Today" },
	{ value = "B", name = "This Week" },
	{ value = "C", name = "This Month" },
	{ value = "D", name = "Later" },
	{ value = "E", name = "Never" },
	{ value = " ", name = "None" },
}

-- Module setup
---
---@param opts table|nil Module config table. See |Todox.config|.
---
---@usage >lua
---   require('todox').setup() -- use default config
---   -- OR
---   require('todox').setup({}) -- replace {} with your config table
--- <
--- Setup function for the plugin
function Todox.setup(opts)
	opts = opts or {}

	-- Handle configuration
	if opts.todo_files and #opts.todo_files > 0 then
		-- Map paths but don't expand relative paths with special treatment
		Todox.config.todo_files = vim.tbl_map(function(path)
			-- Only expand absolute paths
			if not H.is_relative_path(path) then
				return H.expand_path(path)
			end
			return path
		end, opts.todo_files)
	end

	if opts.picker then
		Todox.config.picker = vim.tbl_deep_extend("force", Todox.config.picker, opts.picker)
	end

	if opts.sorting then
		Todox.config.sorting = vim.tbl_deep_extend("force", Todox.config.sorting or {}, opts.sorting)
	end

	-- Set up filetypes and create missing files
	H.setup_filetypes(Todox.config.todo_files)
	H.check_todotxt_syntax()
	H.create_missing_files(Todox.config.todo_files)
end

--- Module config
---
--- Default values:
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
Todox.config = {
	todo_files = {
		H.expand_path("~/Documents/todo.txt"),
	},
	picker = {
		opts = {},
	},
	sorting = {},
}

----------------------------------------
-- Public API
----------------------------------------

--- Sort tasks by date
---@return nil
function Todox.sort_tasks()
	H.sort_tasks_by(function(a, b)
		local date_a = a:match("^x (%d%d%d%d%-%d%d%-%d%d)") or a:match("^(%d%d%d%d%-%d%d%-%d%d)")
		local date_b = b:match("^x (%d%d%d%d%-%d%d%-%d%d)") or b:match("^(%d%d%d%d%-%d%d%-%d%d)")
		if date_a and date_b then
			return date_a > date_b
		elseif date_a then
			return false
		elseif date_b then
			return true
		else
			return a > b
		end
	end)
end

--- Sort tasks by priority
---@return nil
function Todox.sort_tasks_by_priority()
	-- Check if there's a custom sort function
	if Todox.config.sorting and Todox.config.sorting.by_priority then
		H.sort_tasks_by(Todox.config.sorting.by_priority)
		return
	end

	-- Get all lines
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	-- Group lines by priority status
	local priority_groups = {}
	local no_priority = {}
	local completed = {}

	for _, line in ipairs(lines) do
		if line:match("^%s*$") then
		elseif line:match("^x ") then
			table.insert(completed, line)
		else
			local priority = line:match("^%((%a)%)")
			if priority then
				priority_groups[priority] = priority_groups[priority] or {}
				table.insert(priority_groups[priority], line)
			else
				table.insert(no_priority, line)
			end
		end
	end

	table.sort(no_priority)

	for _, group in pairs(priority_groups) do
		table.sort(group) -- Sort lines within each priority group by name
	end

	table.sort(completed)

	local priorities = {}
	for p in pairs(priority_groups) do
		table.insert(priorities, p)
	end
	table.sort(priorities) -- Sort A, B, C, etc.

	local result = {}

	for _, line in ipairs(no_priority) do
		table.insert(result, line)
	end

	if #no_priority > 0 and #priorities > 0 then
		table.insert(result, "")
	end

	-- Add priority tasks in order with separators between different priorities
	for i, p in ipairs(priorities) do
		-- Add tasks with this priority
		for _, line in ipairs(priority_groups[p]) do
			table.insert(result, line)
		end

		-- Add separator between different priority groups (but not after the last one)
		if i < #priorities then
			table.insert(result, "")
		end
	end

	-- Add separator before completed tasks
	if (#no_priority > 0 or #priorities > 0) and #completed > 0 then
		table.insert(result, "")
	end

	-- Add completed tasks
	for _, line in ipairs(completed) do
		table.insert(result, line)
	end

	-- Update buffer
	vim.api.nvim_buf_set_lines(0, 0, -1, false, result)
end

--- Sort tasks by project
---@return nil
function Todox.sort_tasks_by_project()
	H.sort_tasks_with_separators(function(a, b)
		local project_a = a:match("%+(%w+)") or ""
		local project_b = b:match("%+(%w+)") or ""
		return project_a < project_b
	end, function(line)
		return line:match("%+(%w+)") or ""
	end)
end

--- Sort tasks by context
---@return nil
function Todox.sort_tasks_by_context()
	H.sort_tasks_with_separators(function(a, b)
		local context_a = a:match("@(%w+)") or ""
		local context_b = b:match("@(%w+)") or ""
		return context_a < context_b
	end, function(line)
		return line:match("@(%w+)") or ""
	end)
end

--- Sort tasks by due date
---@return nil
function Todox.sort_tasks_by_due_date()
	H.sort_tasks_with_separators(function(a, b)
		local due_date_a = a:match("due:(%d%d%d%d%-%d%d%-%d%d)")
		local due_date_b = b:match("due:(%d%d%d%d%-%d%d%-%d%d)")
		if due_date_a and due_date_b then
			return due_date_a < due_date_b
		elseif due_date_a then
			return true
		elseif due_date_b then
			return false
		else
			return a < b
		end
	end, function(line)
		return line:match("due:(%d%d%d%d%-%d%d%-%d%d)") or ""
	end)
end

--- Generic sort function that delegates to specific sort functions
---@param sort_type string|nil The type of sort to perform: "date", "priority", "project", "context", or "due"
---@return nil
function Todox.sort_by(sort_type)
	sort_type = sort_type or "name" -- Default to sorting by date

	if sort_type == "name" then
		Todox.sort_tasks()
	elseif sort_type == "priority" then
		Todox.sort_tasks_by_priority()
	elseif sort_type == "project" then
		Todox.sort_tasks_by_project()
	elseif sort_type == "context" then
		Todox.sort_tasks_by_context()
	elseif sort_type == "due" then
		Todox.sort_tasks_by_due_date()
	else
		vim.notify("Unknown sort type: " .. sort_type, vim.log.levels.ERROR)
	end
end

--- Captures a new todo entry with the current date
---@return nil
function Todox.capture_todo()
	-- Determine the target todo file first
	local todo_file = H.get_current_todo_file()

	-- If no todo file is currently open, show a picker
	if todo_file then
		H.capture_todo_with_file(todo_file)
	else
		if not H.ensure_picker() then
			return
		end

		local active_files = H.get_active_todo_files()
		if #active_files == 1 then
			vim.cmd("edit " .. vim.fn.fnameescape(active_files[1]))
			return
		elseif #active_files == 0 then
			vim.notify("No todo files found", vim.log.levels.ERROR)
			return
		end

		if not H.ensure_picker() then
			return
		end

		local fzf = require("fzf-lua")
		local fzf_opts = H.picker_default_opts()
		fzf_opts.actions = {
			["default"] = function(selection)
				if selection and selection[1] then
					H.capture_todo_with_file(selection[1])
				end
			end,
		}
		fzf.fzf_exec(active_files, fzf_opts)
	end
end

--- Toggles the todo state of the current line in a todo.txt file
---@return nil
function Todox.toggle_todo_state()
	local node = vim.treesitter.get_node()

	if not node then
		return
	end

	local start_row, _ = node:range()
	local line = vim.fn.getline(start_row + 1)
	local pattern = "^x %d%d%d%d%-%d%d%-%d%d "

	if line:match(pattern) then
		line = line:gsub(pattern, "")
	else
		local date = os.date("%Y-%m-%d")
		line = "x " .. date .. " " .. line
	end

	vim.fn.setline(start_row + 1, line)
end

--- Show priority picker and apply selected priority
---@return nil
function Todox.add_priority()
	if not H.ensure_picker("A picker is required for priority selection") then
		return
	end

	local start_row, end_row = H.get_line_range()
	local selected_lines = vim.api.nvim_buf_get_lines(0, start_row, end_row, false)

	local fzf = require("fzf-lua")
	local items = {}
	for _, entry in ipairs(PRIORITIES) do
		table.insert(items, "(" .. entry.value .. ") " .. fzf.utils.ansi_codes.grey(entry.name))
	end

	local fzf_opts = H.picker_default_opts()
	fzf_opts.actions = {
		["default"] = function(selection)
			if selection and selection[1] then
				local priority_value = string.match(selection[1], "%(([A-Z])%)")
				H.update_lines_with_priority(selected_lines, priority_value, start_row, end_row)
			else
				vim.notify("No tags selected", vim.log.levels.WARN)
			end
		end,
	}
	fzf.fzf_exec(items, fzf_opts)
end

--- Adds project tags to the current line or selected lines
---@return nil
function Todox.add_project_tag()
	if not H.ensure_picker("A picker is required for project tag selection") then
		return
	end

	local existing_tags = H.extract_project_tags()
	local start_line, end_line = H.get_line_range()
	local selected_lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)

	-- Check if there are valid todos in the selection
	local valid_todos = false
	for _, line in ipairs(selected_lines) do
		if line ~= "" and not line:match("^%s*$") then
			valid_todos = true
			break
		end
	end

	if not valid_todos then
		vim.notify("No valid todos selected", vim.log.levels.WARN)
		return
	end

	local fzf = require("fzf-lua")
	local fzf_opts = H.picker_default_opts()
	fzf_opts.fzf_opts = { ["--multi"] = true }
	fzf_opts.actions = {
		["default"] = function(selections)
			if #selections > 0 then
				H.apply_tags_to_lines(selected_lines, selections, start_line)
			else
				vim.notify("No tags selected", vim.log.levels.WARN)
			end
		end,
	}
	fzf.fzf_exec(existing_tags, fzf_opts)
end

--- Moves all done tasks from todo files to their corresponding done files
---@return nil
function Todox.archive_done_tasks()
	local bufname = vim.api.nvim_buf_get_name(0)

	-- Check if we're in any of the configured todo files
	for _, todo_file in ipairs(Todox.config.todo_files) do
		if bufname == todo_file then
			H.move_done_tasks_for_file(todo_file)
			return
		end
	end

	vim.notify("No todo file is open", vim.log.levels.WARN)
end

--- Opens a todo file. If multiple todo files are defined, shows a picker.
---@return nil
function Todox.open_todo()
	local active_files = H.get_active_todo_files()
	if #active_files == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(active_files[1]))
		return
	elseif #active_files == 0 then
		vim.notify("No todo files found", vim.log.levels.ERROR)
		return
	end

	if not H.ensure_picker() then
		return
	end

	local fzf = require("fzf-lua")
	local fzf_opts = H.picker_default_opts()
	fzf_opts.actions = {
		["default"] = require("fzf-lua").actions.file_edit,
	}
	fzf.fzf_exec(active_files, fzf_opts)
end

--- Opens a done file. If in a todo file, opens the associated done file.
---@return nil
function Todox.open_done()
	-- Check if we're in a todo file
	local current_todo_file = H.get_current_todo_file()
	if current_todo_file then
		-- If we're in a todo file, open its corresponding done file
		local done_file = H.get_done_file_path(current_todo_file)
		vim.cmd("edit " .. vim.fn.fnameescape(done_file))
		return
	end

	-- Get active todo files (existing only)
	local active_files = H.get_active_todo_files()
	if #active_files == 0 then
		vim.notify("No todo files found", vim.log.levels.ERROR)
		return
	end

	if not H.ensure_picker() then
		return
	end

	-- Create a list of done files from active todo files
	local done_files = {}
	for _, todo_file in ipairs(active_files) do
		local done_file = H.get_done_file_path(todo_file)
		table.insert(done_files, done_file)
	end

	local fzf = require("fzf-lua")
	local fzf_opts = H.picker_default_opts()
	fzf_opts["file_icons"] = true
	fzf_opts.actions = {
		["default"] = require("fzf-lua").actions.file_edit,
	}
	fzf.fzf_exec(done_files, fzf_opts)
end

----------------------------------------
-- Helper Functions
----------------------------------------

--- Gets the done file path corresponding to a todo file path
---@param todo_file string
---@return string
function H.get_done_file_path(todo_file)
	local ext_pos = todo_file:find("%.[^/\\%.]*$")
	if ext_pos then
		return todo_file:sub(1, ext_pos - 1) .. ".done" .. todo_file:sub(ext_pos)
	else
		return todo_file .. ".done"
	end
end

--- Reads the lines from a file.
---@param filepath string
---@return string[]
function H.read_lines(filepath)
	return vim.fn.readfile(filepath)
end

--- Writes the lines to a file.
---@param filepath string
---@param lines table
---@return nil
function H.write_lines(filepath, lines)
	vim.fn.writefile(lines, filepath)
end

--- Updates the buffer if it is open.
---@param filepath string
---@param lines string[]
---@return nil
function H.update_buffer_if_open(filepath, lines)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local bufname = vim.api.nvim_buf_get_name(buf)
		if bufname == filepath and vim.api.nvim_buf_is_loaded(buf) then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		end
	end
end

--- Check if a path is relative
---@param path string The path to check
---@return boolean
function H.is_relative_path(path)
	return path:match("^%.") ~= nil
end

--- Expands a path to handle home directory references like ~ or $HOME
---@param path string The path to expand
---@return string The expanded path
function H.expand_path(path)
	local expanded_path = vim.fn.expand(path)

	if H.is_relative_path(expanded_path) then
		expanded_path = vim.fn.fnamemodify(expanded_path, ":p")
	end
	return expanded_path
end

--- Get the list of active todo files (existing files only)
---@return string[] List of existing todo files
function H.get_active_todo_files()
	local active_files = {}

	for _, file_path in ipairs(Todox.config.todo_files) do
		local expanded_path = H.expand_path(file_path)
		if vim.fn.filereadable(expanded_path) == 1 then
			table.insert(active_files, expanded_path)
		end
	end

	return active_files
end

--- Checks if a required module is available
---@param module_name string Name of the module to check
---@param error_message string|nil Message to show if module is not available
---@return boolean has_module True if module is available
function H.ensure_module(module_name, error_message)
	local has_module, _ = pcall(require, module_name)
	if not has_module and error_message then
		vim.notify(error_message, vim.log.levels.ERROR)
	end
	return has_module
end

--- Checks if fzf-lua is available
---@param error_message string|nil Message to show if picker is not available
---@return boolean has_picker True if picker is available
function H.ensure_picker(error_message)
	return H.ensure_module("fzf-lua", error_message or "fzf-lua is required for this operation")
end

--- Get the range of lines in the current visual selection or current line
---@return integer, integer
function H.get_line_range()
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local visual_line = vim.fn.line("v")

	local start_line = math.min(cursor_line, visual_line)
	local end_line = math.max(cursor_line, visual_line)

	return start_line - 1, end_line
end

--- Gets the current todo file based on buffer name or nil if none is found
---@return string|nil
function H.get_current_todo_file()
	local bufname = vim.api.nvim_buf_get_name(0)
	local active_files = H.get_active_todo_files()

	-- Check if we're currently in one of the active todo files
	for _, todo_file in ipairs(active_files) do
		if bufname == todo_file then
			return todo_file
		end
	end

	-- Check if any todo file is open in any buffer
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local buf_name = vim.api.nvim_buf_get_name(buf)
		for _, todo_file in ipairs(active_files) do
			if buf_name == todo_file then
				return todo_file
			end
		end
	end

	return nil
end

--- Merge default options for FZF Picker with user provided opts.
---@return {}
function H.picker_default_opts()
	local fzf_default_opts = {
		winopts = {
			width = 0.4,
			height = 0.2,
			preview = {
				hidden = "hidden",
			},
		},
	}

	local fzf_opts = vim.tbl_deep_extend("force", fzf_default_opts, Todox.config.picker.opts or {})
	return fzf_opts
end

--- Sorts the tasks in the open buffer by a given function.
---@param sort_func function Function to use for sorting
---@return nil
function H.sort_tasks_by(sort_func)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	table.sort(lines, sort_func)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

--- Sorts the tasks in the open buffer by a given function and adds separators between groups.
---@param sort_func function Function to compare two items for sorting
---@param group_func function Function to determine the group of an item
---@return nil
function H.sort_tasks_with_separators(sort_func, group_func)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	-- Sort the lines
	table.sort(lines, sort_func)
	-- Add separators between groupsanother
	local result = {}
	local current_group = nil
	for i, line in ipairs(lines) do
		-- Skip empty lines
		if line:match("^%s*$") then
			goto continue
		end
		local group = group_func(line)
		-- Add separator when group changes
		if i > 1 and group ~= current_group then
			table.insert(result, "")
		end
		table.insert(result, line)
		current_group = group
		::continue::
	end
	vim.api.nvim_buf_set_lines(0, 0, -1, false, result)
end

--- Move done tasks from a todo file to its corresponding done file
---@param todo_file string Path to the todo file
---@return nil
function H.move_done_tasks_for_file(todo_file)
	local done_file = H.get_done_file_path(todo_file)
	local todo_lines = H.read_lines(todo_file)
	local done_lines = H.read_lines(done_file)
	local remaining_todo_lines = {}

	for _, line in ipairs(todo_lines) do
		if line:match("^x ") then
			table.insert(done_lines, line)
		else
			table.insert(remaining_todo_lines, line)
		end
	end

	local current_buf = vim.api.nvim_get_current_buf()
	local current_bufname = vim.api.nvim_buf_get_name(current_buf)
	local in_todo_buffer = (current_bufname == todo_file)

	-- If we're in the todo file, update it directly through the buffer
	if in_todo_buffer then
		vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, remaining_todo_lines)
		vim.cmd("silent write") -- Save the buffer
		-- Write done tasks to done file
		H.write_lines(done_file, done_lines)
	else
		-- We're not in the todo buffer, just write to files
		H.write_lines(todo_file, remaining_todo_lines)
		H.write_lines(done_file, done_lines)

		-- Tell Vim to check if files have changed
		vim.cmd("checktime")
	end
end

--- Capture a new todo with a specific file
---@param todo_file string Path to the todo file
---@return nil
function H.capture_todo_with_file(todo_file)
	vim.ui.input({ prompt = "New Todo: " }, function(input)
		if not input then
			return
		end

		local date = os.date("%Y-%m-%d")
		local new_todo = date .. " " .. input
		local bufname = vim.api.nvim_buf_get_name(0)

		if bufname == todo_file then
			-- We're in the todo file, update the buffer directly
			local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
			table.insert(lines, 1, new_todo) -- Insert at the beginning
			vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
		else
			-- Add to the file and update the buffer if open
			local lines = H.read_lines(todo_file)
			table.insert(lines, 1, new_todo) -- Insert at the beginning
			H.update_buffer_if_open(todo_file, lines)
			H.write_lines(todo_file, lines)
			vim.notify("Todo added to " .. todo_file)
		end
	end)
end

--- Inserts project tags at the right position in a line
---@param line string The line to modify
---@param tags string[] The tags to insert
---@return string The modified line
function H.insert_project_tags(line, tags)
	if #tags == 0 then
		return line
	end

	-- First, check for existing tags to avoid duplicates
	local existing = {}
	for tag in line:gmatch("%+(%w+)") do
		existing[tag] = true
	end

	-- Filter out tags that already exist
	local new_tags = {}
	for _, tag in ipairs(tags) do
		if not existing[tag] then
			table.insert(new_tags, "+" .. tag)
		end
	end

	if #new_tags == 0 then
		return line -- No new tags to add
	end

	-- The formatted tags we want to insert
	local tag_str = " " .. table.concat(new_tags, " ") .. " "

	local context_pos = line:find(" @%w+")
	local metadata_pos = line:find(" %w+:%S+")

	-- Find the earliest special element
	local insert_pos = nil
	if context_pos and metadata_pos then
		insert_pos = math.min(context_pos, metadata_pos)
	elseif context_pos then
		insert_pos = context_pos
	elseif metadata_pos then
		insert_pos = metadata_pos
	end

	local result
	if insert_pos then
		result = line:sub(1, insert_pos) .. tag_str .. line:sub(insert_pos + 1)
	else
		-- If none found, append to the end
		result = line .. tag_str
	end
	return string.gsub(result, "%s+", " ")
end

--- Apply project tags to selected lines
---@param lines string[] The lines to modify
---@param tags string[] The tags to apply
---@param start_pos number The starting position in the buffer
---@return nil
function H.apply_tags_to_lines(lines, tags, start_pos)
	if #tags == 0 then
		return
	end

	local updated_lines = {}

	for i, line in ipairs(lines) do
		-- Only process non-empty lines
		if line ~= "" and not line:match("^%s*$") then
			updated_lines[i] = H.insert_project_tags(line, tags)
		else
			updated_lines[i] = line
		end
	end

	-- Update the buffer with the modified lines
	vim.api.nvim_buf_set_lines(0, start_pos, start_pos + #lines, false, updated_lines)

	-- Notify the user
	local tag_names = table.concat(
		vim.tbl_map(function(tag)
			return "+" .. tag
		end, tags),
		", "
	)
	vim.notify("Added project tags: " .. tag_names, vim.log.levels.INFO)
end

--- Check for todotxt TreeSitter syntax parser
---@return nil
function H.check_todotxt_syntax()
	local has_treesitter, ts = pcall(require, "nvim-treesitter.parsers")
	if not has_treesitter then
		vim.notify(
			"nvim-treesitter is not installed. Syntax highlighting for todo.txt files will be limited.",
			vim.log.levels.WARN
		)
		return
	end

	if not ts.has_parser("todotxt") then
		vim.notify(
			"Treesitter parser for todotxt is not installed. " .. "For syntax highlighting run :TSInstall todotxt",
			vim.log.levels.WARN
		)
	end
end

--- Update lines with new priority
---@param selected_lines string[] Lines to update
---@param priority_value string Priority value to set
---@param start_row integer Starting row in buffer
---@return nil
function H.update_lines_with_priority(selected_lines, priority_value, start_row, end_row)
	local modified_lines = {}

	for i, line in ipairs(selected_lines) do
		if line:match("^%s*$") then
			modified_lines[i] = line
		else
			local current_priority = line:match("^%((%a)%)")
			local new_line

			if current_priority then
				if priority_value == "" then
					new_line = line:gsub("^%(%a%)%s*", "")
				else
					new_line = line:gsub("^%(%a%)%s*", "(" .. priority_value .. ") ")
				end
			else
				if priority_value ~= "" then
					new_line = "(" .. priority_value .. ") " .. line
				else
					new_line = line
				end
			end

			modified_lines[i] = new_line
		end
	end

	vim.api.nvim_buf_set_lines(0, start_row, end_row, false, modified_lines)

	-- Show notification
	local priority_display = priority_value == "" and "None" or "(" .. priority_value .. ")"
	local count_message = #selected_lines > 1 and " for " .. #selected_lines .. " tasks" or ""
	vim.notify("Set priority to " .. priority_display .. count_message, vim.log.levels.INFO)
end

--- Set up file types for todo.txt files
---@param todo_files string[] List of todo files
---@return nil
function H.setup_filetypes(todo_files)
	local filename_mappings = {}
	for _, todo_file in ipairs(todo_files) do
		local todo_filename = vim.fn.fnamemodify(todo_file, ":t")
		filename_mappings[todo_filename] = "todotxt"

		-- Also register the done file
		local done_file = H.get_done_file_path(todo_file)
		local done_filename = vim.fn.fnamemodify(done_file, ":t")
		filename_mappings[done_filename] = "todotxt"
	end
	-- Register the filetype mappings
	vim.filetype.add({ filename = filename_mappings })
end

--- Create todo files if they don't exist
---@param todo_files string[] List of todo files
---@return nil
function H.create_missing_files(todo_files)
	for _, todo_file in ipairs(todo_files) do
		-- Skip relative paths - don't create them
		if H.is_relative_path(todo_file) then
			goto continue
		end

		if vim.fn.filereadable(todo_file) == 0 then
			vim.fn.writefile({}, todo_file)
		end

		local done_file = H.get_done_file_path(todo_file)
		if vim.fn.filereadable(done_file) == 0 then
			vim.fn.writefile({}, done_file)
		end

		::continue::
	end
end

--- Extract existing project tags from all lines
---@return string[] List of unique project tags
function H.extract_project_tags()
	local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local existing_tags = {}
	local tag_set = {}

	for _, line in ipairs(all_lines) do
		for tag in line:gmatch("%+(%w+)") do
			if not tag_set[tag] then
				tag_set[tag] = true
				table.insert(existing_tags, tag)
			end
		end
	end

	-- Sort tags alphabetically
	table.sort(existing_tags)
	return existing_tags
end

return Todox
