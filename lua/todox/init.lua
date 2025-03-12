--[[
  todox.nvim - A Todo.txt file manager for Neovim
  
  This plugin provides functionality for managing todo.txt files following the Todo.txt format.
  https://github.com/todotxt/todo.txt
]]

local M = {}

---@class TodoxConfig
---@field todo_files string[] List of paths to todo.txt files
---@field active_file string|nil Currently active todo file

-- Default configuration
local config = {
	todo_files = {},
	active_file = nil,
}

-- Constants
local PRIORITIES = {
	{ value = "A", name = "Today" },
	{ value = "B", name = "This Week" },
	{ value = "C", name = "This Month" },
	{ value = "D", name = "Later" },
	{ value = "E", name = "Never" },
	{ value = "", name = "None" },
}

----------------------------------------
-- Helper Functions
----------------------------------------

--- Gets the done file path corresponding to a todo file path
---@param todo_file string
---@return string
local function get_done_file_path(todo_file)
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
local function read_lines(filepath)
	return vim.fn.readfile(filepath)
end

--- Writes the lines to a file.
---@param filepath string
---@param lines table
---@return nil
local function write_lines(filepath, lines)
	vim.fn.writefile(lines, filepath)
end

--- Updates the buffer if it is open.
---@param filepath string
---@param lines string[]
---@return nil
local function update_buffer_if_open(filepath, lines)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local bufname = vim.api.nvim_buf_get_name(buf)
		if bufname == filepath and vim.api.nvim_buf_is_loaded(buf) then
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		end
	end
end

--- Gets the current todo file based on buffer name or nil if none is found
---@return string|nil
local function get_current_todo_file()
	local bufname = vim.api.nvim_buf_get_name(0)

	-- Check if we're currently in one of the todo files
	for _, todo_file in ipairs(config.todo_files) do
		if bufname == todo_file then
			return todo_file
		end
	end

	-- Check if any todo file is open in any buffer
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local buf_name = vim.api.nvim_buf_get_name(buf)
		for _, todo_file in ipairs(config.todo_files) do
			if buf_name == todo_file then
				return todo_file
			end
		end
	end

	return nil
end

--- Checks if Telescope is available
---@param error_message string Message to show if telescope is not available
---@return boolean has_telescope True if telescope is available
local function ensure_telescope(error_message)
	local has_telescope, _ = pcall(require, "telescope")
	if not has_telescope then
		vim.notify(error_message or "Telescope is required for this operation", vim.log.levels.ERROR)
	end
	return has_telescope
end

--- Creates a Telescope picker for selecting from a list of options
---@param opts table Configuration options for the picker
---@param callback function Function to call with the selected value(s)
local function create_picker(opts, callback)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local picker_opts = {
		prompt_title = opts.title or "Select",
		layout_strategy = opts.layout_strategy or "center",
		layout_config = opts.layout_config or {
			width = 0.4,
			height = 0.2,
		},
		finder = finders.new_table({
			results = opts.items,
			entry_maker = opts.entry_maker or function(entry)
				return {
					value = entry,
					display = entry,
					ordinal = entry,
				}
			end,
		}),
		sorter = conf.generic_sorter({}),
		attach_mappings = function(prompt_bufnr, _)
			actions.select_default:replace(function()
				local selection
				local multi_selection = false

				if opts.multi_select then
					local picker = action_state.get_current_picker(prompt_bufnr)
					selection = picker:get_multi_selection()
					multi_selection = #selection > 0
				end

				if not multi_selection then
					selection = action_state.get_selected_entry()
				end

				actions.close(prompt_bufnr)
				callback(selection, multi_selection)
			end)
			return true
		end,
	}

	pickers.new({}, picker_opts):find()
end

----------------------------------------
-- Sorting Functions
----------------------------------------

--- Sorts the tasks in the open buffer by a given function.
---@param sort_func function Function to use for sorting
---@return nil
local function sort_tasks_by(sort_func)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	table.sort(lines, sort_func)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

--- Sorts the tasks in the open buffer by a given function and adds separators between groups.
---@param sort_func function Function to compare two items for sorting
---@param group_func function Function to determine the group of an item
---@return nil
local function sort_tasks_with_separators(sort_func, group_func)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	-- Sort the lines
	table.sort(lines, sort_func)
	-- Add separators between groups
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

----------------------------------------
-- Task Management Functions
----------------------------------------

--- Move done tasks from a todo file to its corresponding done file
---@param todo_file string Path to the todo file
---@return nil
local function move_done_tasks_for_file(todo_file)
	local done_file = get_done_file_path(todo_file)
	local todo_lines = read_lines(todo_file)
	local done_lines = read_lines(done_file)
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
		write_lines(done_file, done_lines)
	else
		-- We're not in the todo buffer, just write to files
		write_lines(todo_file, remaining_todo_lines)
		write_lines(done_file, done_lines)

		-- Tell Vim to check if files have changed
		vim.cmd("checktime")
	end
end

--- Capture a new todo with a specific file
---@param todo_file string Path to the todo file
---@return nil
local function capture_todo_with_file(todo_file)
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
			local lines = read_lines(todo_file)
			table.insert(lines, 1, new_todo) -- Insert at the beginning
			update_buffer_if_open(todo_file, lines)
			write_lines(todo_file, lines)
		end
	end)
end

--- Inserts project tags at the right position in a line
---@param line string The line to modify
---@param tags string[] The tags to insert
---@return string The modified line
local function insert_project_tags(line, tags)
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
local function apply_tags_to_lines(lines, tags, start_pos)
	if #tags == 0 then
		return
	end

	local updated_lines = {}

	for i, line in ipairs(lines) do
		-- Only process non-empty lines
		if line ~= "" and not line:match("^%s*$") then
			updated_lines[i] = insert_project_tags(line, tags)
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
local function check_todotxt_syntax()
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

----------------------------------------
-- Public API
----------------------------------------

--- Sort tasks by date
---@return nil
function M.sort_tasks()
	sort_tasks_by(function(a, b)
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
function M.sort_tasks_by_priority()
	sort_tasks_with_separators(function(a, b)
		local priority_a = a:match("^%((%a)%)") or "Z"
		local priority_b = b:match("^%((%a)%)") or "Z"
		return priority_a < priority_b
	end, function(line)
		return line:match("^%((%a)%)") or "Z"
	end)
end

--- Sort tasks by project
---@return nil
function M.sort_tasks_by_project()
	sort_tasks_with_separators(function(a, b)
		local project_a = a:match("%+(%w+)") or ""
		local project_b = b:match("%+(%w+)") or ""
		return project_a < project_b
	end, function(line)
		return line:match("%+(%w+)") or ""
	end)
end

--- Sort tasks by context
---@return nil
function M.sort_tasks_by_context()
	sort_tasks_with_separators(function(a, b)
		local context_a = a:match("@(%w+)") or ""
		local context_b = b:match("@(%w+)") or ""
		return context_a < context_b
	end, function(line)
		return line:match("@(%w+)") or ""
	end)
end

--- Sort tasks by due date
---@return nil
function M.sort_tasks_by_due_date()
	sort_tasks_with_separators(function(a, b)
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
function M.sort_by(sort_type)
	sort_type = sort_type or "name" -- Default to sorting by date

	if sort_type == "name" then
		M.sort_tasks()
	elseif sort_type == "priority" then
		M.sort_tasks_by_priority()
	elseif sort_type == "project" then
		M.sort_tasks_by_project()
	elseif sort_type == "context" then
		M.sort_tasks_by_context()
	elseif sort_type == "due" then
		M.sort_tasks_by_due_date()
	else
		vim.notify("Unknown sort type: " .. sort_type, vim.log.levels.ERROR)
	end
end

--- Captures a new todo entry with the current date
---@return nil
function M.capture_todo()
	-- Determine the target todo file first
	local todo_file = get_current_todo_file()

	-- If no todo file is currently open, show a picker
	if not todo_file and #config.todo_files > 0 then
		-- Check if telescope is available
		if not ensure_telescope("Telescope is required for todo file selection") then
			todo_file = config.active_file -- Fallback to active file if telescope is not available
		else
			create_picker({
				title = "Select Todo File",
				items = config.todo_files,
				entry_maker = function(entry)
					local filename = vim.fn.fnamemodify(entry, ":t")
					return {
						value = entry,
						display = filename,
						ordinal = filename,
					}
				end,
			}, function(selection)
				if selection then
					capture_todo_with_file(selection.value)
				end
			end)
			return -- Return early as the picker callback will handle the rest
		end
	end

	-- If we reach here, either a todo file was found or we're using the active file as fallback
	if not todo_file then
		todo_file = config.active_file
	end

	capture_todo_with_file(todo_file)
end

--- Toggles the todo state of the current line in a todo.txt file
---@return nil
function M.toggle_todo_state()
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

--- Sets the priority of the current task using a telescope picker
---@return nil
function M.add_priority()
	if not ensure_telescope("Telescope is required for priority selection") then
		return
	end

	local node = vim.treesitter.get_node()
	if not node then
		return
	end

	local start_row, _ = node:range()
	local line = vim.fn.getline(start_row + 1)
	local current_priority = line:match("^%((%a)%)")

	create_picker({
		title = "Select Priority",
		items = PRIORITIES,
		layout_config = {
			width = 0.4,
			height = 0.4,
		},
		entry_maker = function(entry)
			local display
			if entry.value == "" then
				display = entry.name
			else
				display = "(" .. entry.value .. ") " .. entry.name
			end

			return {
				value = entry,
				display = display,
				ordinal = display,
			}
		end,
	}, function(selection)
		if selection == nil then
			return
		end

		local selected_priority = selection.value.value
		local new_line

		if current_priority then
			if selected_priority == "" then
				new_line = line:gsub("^%(%a%)%s*", "")
			else
				new_line = line:gsub("^%(%a%)%s*", "(" .. selected_priority .. ") ")
			end
		else
			if selected_priority ~= "" then
				new_line = "(" .. selected_priority .. ") " .. line
			else
				new_line = line
			end
		end

		vim.fn.setline(start_row + 1, new_line)
	end)
end

--- Adds project tags to the current line or selected lines
---@return nil
function M.add_project_tag()
	if not ensure_telescope("Telescope is required for project tag selection") then
		return
	end

	-- Get all lines from the current buffer
	local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

	-- Extract all existing project tags from the file
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

	-- Check for visual selection or current line
	local start_line, end_line

	-- Get visual selection by directly checking for marks
	if vim.fn.exists("'<") == 1 and vim.fn.exists("'>") == 1 then
		start_line = vim.fn.line("'<") - 1
		end_line = vim.fn.line("'>")
	else
		-- Get the current line
		local cursor = vim.api.nvim_win_get_cursor(0)
		start_line = cursor[1] - 1
		end_line = cursor[1]
	end

	-- Get the selected lines
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

	create_picker({
		title = "Select Project Tags",
		items = existing_tags,
		multi_select = true,
		layout_config = {
			width = 0.5,
			height = 0.6,
		},
		entry_maker = function(entry)
			return {
				value = entry,
				display = "+" .. entry,
				ordinal = entry,
			}
		end,
	}, function(selections, is_multi)
		local selected_tags = {}

		if is_multi then
			for _, selection in ipairs(selections) do
				table.insert(selected_tags, selection.value)
			end
		elseif selections then
			table.insert(selected_tags, selections.value)
		end

		if #selected_tags > 0 then
			apply_tags_to_lines(selected_lines, selected_tags, start_line)
		else
			vim.notify("No tags selected", vim.log.levels.WARN)
		end
	end)
end

--- Moves all done tasks from todo files to their corresponding done files
---@return nil
function M.move_done_tasks()
	local bufname = vim.api.nvim_buf_get_name(0)

	-- First check if we're in any of the configured todo files
	for _, todo_file in ipairs(config.todo_files) do
		if bufname == todo_file then
			move_done_tasks_for_file(todo_file)
			return
		end
	end

	-- Check if the current buffer might be a todo file (even if not in configured list)
	if bufname:match("%.txt$") and vim.fn.filereadable(bufname) == 1 then
		move_done_tasks_for_file(bufname)
		return
	end

	-- If we're not in a todo file, show notification
	vim.notify("No todo file is open", vim.log.levels.WARN)
end

--- Opens a todo file. If multiple todo files are defined, shows a picker.
---@return nil
function M.open_todo()
	-- If only one todo file, open it directly
	if #config.todo_files == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(config.todo_files[1]))
		return
	elseif #config.todo_files == 0 then
		vim.notify("No todo files configured", vim.log.levels.ERROR)
		return
	end

	if not ensure_telescope("Telescope is required for todo file selection") then
		-- Fallback to active file if telescope is not available
		if config.active_file then
			vim.cmd("edit " .. vim.fn.fnameescape(config.active_file))
		end
		return
	end

	create_picker({
		title = "Select Todo File",
		items = config.todo_files,
		entry_maker = function(entry)
			local filename = vim.fn.fnamemodify(entry, ":t")
			return {
				value = entry,
				display = filename,
				ordinal = filename,
			}
		end,
	}, function(selection)
		if selection then
			vim.cmd("edit " .. vim.fn.fnameescape(selection.value))
		end
	end)
end

--- Opens a done file. If in a todo file, opens the associated done file.
---@return nil
function M.open_done()
	-- Check if we're in a todo file
	local current_todo_file = get_current_todo_file()

	if current_todo_file then
		-- If we're in a todo file, open its corresponding done file
		local done_file = get_done_file_path(current_todo_file)
		vim.cmd("edit " .. vim.fn.fnameescape(done_file))
		return
	end

	-- If we're not in a todo file, show a picker for all available done files
	if #config.todo_files == 0 then
		vim.notify("No todo files configured", vim.log.levels.ERROR)
		return
	end

	if not ensure_telescope("Telescope is required for done file selection") then
		return
	end

	-- Create a list of done files from configured todo files
	local done_files = {}
	for _, todo_file in ipairs(config.todo_files) do
		local done_file = get_done_file_path(todo_file)
		table.insert(done_files, done_file)
	end

	create_picker({
		title = "Select Done File",
		items = done_files,
		entry_maker = function(entry)
			local filename = vim.fn.fnamemodify(entry, ":t")
			return {
				value = entry,
				display = filename,
				ordinal = filename,
			}
		end,
	}, function(selection)
		if selection then
			vim.cmd("edit " .. vim.fn.fnameescape(selection.value))
		end
	end)
end

--- Setup function for the plugin
---@param opts TodoxConfig
---@return nil
function M.setup(opts)
	opts = opts or {}

	-- Handle configuration
	if opts.todo_files and #opts.todo_files > 0 then
		config.todo_files = opts.todo_files
		config.active_file = opts.todo_files[1]
	else
		-- Default configuration
		config.todo_files = { vim.env.HOME .. "/Documents/todo.txt" }
		config.active_file = config.todo_files[1]
	end

	-- Set up filetypes for todo files and their corresponding done files
	local filename_mappings = {}
	for _, todo_file in ipairs(config.todo_files) do
		local todo_filename = vim.fn.fnamemodify(todo_file, ":t")
		filename_mappings[todo_filename] = "todotxt"

		-- Also register the done file
		local done_file = get_done_file_path(todo_file)
		local done_filename = vim.fn.fnamemodify(done_file, ":t")
		filename_mappings[done_filename] = "todotxt"
	end

	-- Create files if they don't exist
	for _, todo_file in ipairs(config.todo_files) do
		if vim.fn.filereadable(todo_file) == 0 then
			vim.fn.writefile({}, todo_file)
		end

		local done_file = get_done_file_path(todo_file)
		if vim.fn.filereadable(done_file) == 0 then
			vim.fn.writefile({}, done_file)
		end
	end

	-- Register the filetype mappings
	vim.filetype.add({ filename = filename_mappings })

	check_todotxt_syntax()
end

return M
