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
--- @param sort_func function
--- @return nil
local sort_tasks_by = function(sort_func)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	table.sort(lines, sort_func)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

--- Toggles the todo state of the current line in a todo.txt file.
--- If the line starts with "x YYYY-MM-DD ", it removes it to mark as not done.
--- Otherwise, it adds "x YYYY-MM-DD " at the beginning to mark as done.
--- @return nil
todox.toggle_todo_state = function()
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

--- Opens the active todo file in a new split.
--- @return nil
todox.open_todo_file = function()
	vim.cmd("split " .. config.active_file)
end

--- Opens a specific todo file from the configured list
--- @return nil
todox.choose_todo_file = function()
	if #config.todo_files <= 1 then
		todox.open_todo_file()
		return
	end

	-- Create a list of file names for easier selection
	local file_names = {}
	for i, path in ipairs(config.todo_files) do
		local name = vim.fn.fnamemodify(path, ":t")
		file_names[i] = name
	end

	vim.ui.select(file_names, {
		prompt = "Select todo file:",
		format_item = function(item)
			return item
		end,
	}, function(choice, idx)
		if choice then
			config.active_file = config.todo_files[idx]
			todox.open_todo_file()
		end
	end)
end

--- Sorts the tasks in the open buffer by priority.
--- @return nil
todox.sort_tasks_by_priority = function()
	sort_tasks_by(function(a, b)
		local priority_a = a:match("^%((%a)%)") or "Z"
		local priority_b = b:match("^%((%a)%)") or "Z"
		return priority_a < priority_b
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
	sort_tasks_by(function(a, b)
		local project_a = a:match("%+%w+") or ""
		local project_b = b:match("%+%w+") or ""
		return project_a < project_b
	end)
end

--- Sorts the tasks in the open buffer by context.
--- @return nil
todox.sort_tasks_by_context = function()
	sort_tasks_by(function(a, b)
		local context_a = a:match("@%w+") or ""
		local context_b = b:match("@%w+") or ""
		return context_a < context_b
	end)
end

--- Sorts the tasks in the open buffer by due date.
todox.sort_tasks_by_due_date = function()
	sort_tasks_by(function(a, b)
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
	end)
end

--- Cycles the priority of the current task between A, B, C, and no priority.
--- @return nil
todox.cycle_priority = function()
	local node = vim.treesitter.get_node()
	if not node then
		return
	end

	local start_row, _ = node:range()
	local line = vim.fn.getline(start_row + 1)

	local current_priority = line:match("^%((%a)%)")
	local new_priority

	if current_priority == "A" then
		new_priority = "(B) "
	elseif current_priority == "B" then
		new_priority = "(C) "
	elseif current_priority == "C" then
		new_priority = ""
	else
		new_priority = "(A)"
	end

	if current_priority then
		line = line:gsub("^%(%a%)%s*", new_priority)
	else
		line = new_priority .. " " .. line
	end

	vim.fn.setline(start_row + 1, line)
end

--- Gets the current todo file based on buffer name or defaults to active file
--- @return string
local function get_current_todo_file()
	local bufname = vim.api.nvim_buf_get_name(0)

	for _, todo_file in ipairs(config.todo_files) do
		if bufname == todo_file then
			return todo_file
		end
	end

	return config.active_file
end

--- Captures a new todo entry with the current date.
--- @return nil
todox.capture_todo = function()
	vim.ui.input({ prompt = "New Todo: " }, function(input)
		if not input then
			return
		end

		local date = os.date("%Y-%m-%d")
		local new_todo = date .. " " .. input
		local todo_file = get_current_todo_file()
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

--- Moves all done tasks from todo files to their corresponding done files.
--- @return nil
todox.move_done_tasks = function()
	local bufname = vim.api.nvim_buf_get_name(0)

	-- If we're in a todo file, just move tasks for that file
	for _, todo_file in ipairs(config.todo_files) do
		if bufname == todo_file then
			move_done_tasks_for_file(todo_file)
			return
		end
	end

	-- If not in a specific todo file, move done tasks for all files
	for _, todo_file in ipairs(config.todo_files) do
		move_done_tasks_for_file(todo_file)
	end
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
