local todox = {}
local config = {
	todo_files = {}, -- List of todo file paths
	active_file = nil, -- Currently active todo file
}

--- @class Setup
--- @field todo_files string[] List of paths to todo.txt files

--- Gets the done file path corresponding to a todo file path
--- @param todo_file string
--- @return string
local function get_done_file_path(todo_file)
	local ext_pos = todo_file:find("%.[^/\\%.]*$")
	if ext_pos then
		return todo_file:sub(1, ext_pos - 1) .. ".done" .. todo_file:sub(ext_pos)
	else
		return todo_file .. ".done"
	end
end

--- Reads the lines from a file.
--- @param filepath string
--- @return string[]
local read_lines = function(filepath)
	return vim.fn.readfile(filepath)
end

--- Writes the lines to a file.
--- @param filepath string
--- @param lines table
--- @return nil
local write_lines = function(filepath, lines)
	vim.fn.writefile(lines, filepath)
end

--- Updates the buffer if it is open.
--- @param filepath string
--- @param lines string[]
--- @return nil
local update_buffer_if_open = function(filepath, lines)
	-- Check all buffers, not just current
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local bufname = vim.api.nvim_buf_get_name(buf)
		if bufname == filepath then
			if vim.api.nvim_buf_is_loaded(buf) then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			end
		end
	end
end

--- Sorts the tasks in the open buffer by a given function.
--- @param sort_func function Function to use for sorting
--- @return nil
local sort_tasks_by = function(sort_func)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	table.sort(lines, sort_func)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

--- Sorts the tasks in the open buffer by a given function and adds separators between groups.
--- @param sort_func function Function to compare two items for sorting
--- @param group_func function Function to determine the group of an item
--- @return nil
local sort_tasks_with_separators = function(sort_func, group_func)
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

--- Sorts the tasks in the open buffer by priority.
--- @return nil
todox.sort_tasks_by_priority = function()
	sort_tasks_with_separators(function(a, b)
		local priority_a = a:match("^%((%a)%)") or "Z"
		local priority_b = b:match("^%((%a)%)") or "Z"
		return priority_a < priority_b
	end, function(line)
		return line:match("^%((%a)%)") or "Z"
	end)
end

--- Sorts the tasks in the open buffer by date.
--- @return nil
todox.sort_tasks = function()
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

--- Sorts the tasks in the open buffer by project.
--- @return nil
todox.sort_tasks_by_project = function()
	sort_tasks_with_separators(function(a, b)
		local project_a = a:match("%+(%w+)") or ""
		local project_b = b:match("%+(%w+)") or ""
		return project_a < project_b
	end, function(line)
		return line:match("%+(%w+)") or ""
	end)
end

--- Sorts the tasks in the open buffer by context.
--- @return nil
todox.sort_tasks_by_context = function()
	sort_tasks_with_separators(function(a, b)
		local context_a = a:match("@(%w+)") or ""
		local context_b = b:match("@(%w+)") or ""
		return context_a < context_b
	end, function(line)
		return line:match("@(%w+)") or ""
	end)
end

--- Sorts the tasks in the open buffer by due date.
todox.sort_tasks_by_due_date = function()
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

--- Gets the current todo file based on buffer name or nil if none is found
--- @return string|nil
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
			table.insert(lines, new_todo)
			vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
		else
			-- Add to the file and update the buffer if open
			local lines = read_lines(todo_file)
			table.insert(lines, new_todo)
			update_buffer_if_open(todo_file, lines)
			write_lines(todo_file, lines)
		end
	end)
end

--- Moves done tasks from a todo file to its corresponding done file
--- @param todo_file string
--- @return nil
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

--- Captures a new todo entry with the current date.
--- @return nil
todox.capture_todo = function()
	-- Determine the target todo file first
	local todo_file = get_current_todo_file()

	-- If no todo file is currently open, show a picker
	if not todo_file and #config.todo_files > 0 then
		-- Check if telescope is available
		local has_telescope, _ = pcall(require, "telescope")
		if not has_telescope then
			vim.notify("Telescope is required for todo file selection", vim.log.levels.ERROR)
			todo_file = config.active_file -- Fallback to active file if telescope is not available
		else
			local pickers = require("telescope.pickers")
			local finders = require("telescope.finders")
			local conf = require("telescope.config").values
			local actions = require("telescope.actions")
			local action_state = require("telescope.actions.state")

			pickers
				.new({}, {
					prompt_title = "Select Todo File",
					layout_strategy = "center",
					layout_config = {
						width = 0.4,
						height = 0.2,
					},
					finder = finders.new_table({
						results = config.todo_files,
						entry_maker = function(entry)
							local filename = vim.fn.fnamemodify(entry, ":t")
							return {
								value = entry,
								display = filename,
								ordinal = filename,
							}
						end,
					}),
					sorter = conf.generic_sorter({}),
					attach_mappings = function(prompt_bufnr, _)
						actions.select_default:replace(function()
							local selection = action_state.get_selected_entry()
							actions.close(prompt_bufnr)

							if selection then
								-- Continue with todo capture using the selected file
								capture_todo_with_file(selection.value)
							end
						end)
						return true
					end,
				})
				:find()
			return -- Return early as the picker callback will handle the rest
		end
	end

	-- If we reach here, either a todo file was found or we're using the active file as fallback
	if not todo_file then
		todo_file = config.active_file
	end

	capture_todo_with_file(todo_file)
end

--- Sets the priority of the current task using a telescope picker.
--- Supports priorities A-F with descriptive names.
--- @return nil
todox.cycle_priority = function()
	-- Check if telescope is available
	local has_telescope, _ = pcall(require, "telescope")
	if not has_telescope then
		vim.notify("Telescope is required for priority selection", vim.log.levels.ERROR)
		return
	end

	local node = vim.treesitter.get_node()
	if not node then
		return
	end

	local start_row, _ = node:range()
	local line = vim.fn.getline(start_row + 1)
	local current_priority = line:match("^%((%a)%)")

	-- Define priorities with names
	local priorities = {
		{ value = "A", name = "Today" },
		{ value = "B", name = "This Week" },
		{ value = "C", name = "This Month" },
		{ value = "D", name = "Later" },
		{ value = "E", name = "Never" },
		{ value = "", name = "None" },
	}

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Select Priority",
			layout_strategy = "center",
			layout_config = {
				width = 0.4,
				height = 0.4,
			},
			finder = finders.new_table({
				results = priorities,
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
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

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
				return true
			end,
		})
		:find()
end

--- Moves all done tasks from todo files to their corresponding done files.
--- @return nil
todox.move_done_tasks = function()
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
--- @return nil
todox.open_todo = function()
	-- If only one todo file, open it directly
	if #config.todo_files == 1 then
		vim.cmd("edit " .. vim.fn.fnameescape(config.todo_files[1]))
		return
	elseif #config.todo_files == 0 then
		vim.notify("No todo files configured", vim.log.levels.ERROR)
		return
	end

	-- Check if telescope is available
	local has_telescope, _ = pcall(require, "telescope")
	if not has_telescope then
		vim.notify("Telescope is required for todo file selection", vim.log.levels.ERROR)
		-- Fallback to active file if telescope is not available
		if config.active_file then
			vim.cmd("edit " .. vim.fn.fnameescape(config.active_file))
		end
		return
	end

	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	pickers
		.new({}, {
			prompt_title = "Select Todo File",
			layout_strategy = "center",
			layout_config = {
				width = 0.4,
				height = 0.2,
			},
			finder = finders.new_table({
				results = config.todo_files,
				entry_maker = function(entry)
					local filename = vim.fn.fnamemodify(entry, ":t")
					return {
						value = entry,
						display = filename,
						ordinal = filename,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, _)
				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					actions.close(prompt_bufnr)

					if selection then
						-- Open the selected todo file
						vim.cmd("edit " .. vim.fn.fnameescape(selection.value))
					end
				end)
				return true
			end,
		})
		:find()
end

--- Setup function
--- @param opts Setup
todox.setup = function(opts)
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
end

return todox
