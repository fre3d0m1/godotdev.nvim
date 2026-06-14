local M = {}

local function find_project_root()
	local file = vim.api.nvim_buf_get_name(0)
	local start_path = file ~= "" and vim.fs.dirname(file) or vim.uv.cwd()
	local project_file = vim.fs.find("project.godot", {
		upward = true,
		path = start_path,
	})[1]

	if not project_file then
		return nil
	end

	return vim.fs.normalize(vim.fs.dirname(project_file))
end

local function normalize_scene_arg(scene)
	local root = find_project_root()
	if not root or type(scene) ~= "string" or scene == "" then
		return nil
	end

	if scene:match("^res://") then
		return scene
	end

	-- 1. Enforce absolute paths
	local abs_scene = vim.fs.normalize(vim.fn.fnamemodify(scene, ":p"))
	local abs_root = vim.fs.normalize(vim.fn.fnamemodify(root, ":p"))

	-- 2. Clean up double slashes that happen on secondary Windows drives (e.g., D:// to D:/)
	abs_scene = abs_scene:gsub("//+", "/")
	abs_root = abs_root:gsub("//+", "/")

	-- 3. Force uppercase drive letters (d: -> D:)
	if abs_scene:match("^%a:") then
		abs_scene = abs_scene:sub(1, 1):upper() .. abs_scene:sub(2)
	end
	if abs_root:match("^%a:") then
		abs_root = abs_root:sub(1, 1):upper() .. abs_root:sub(2)
	end

	-- Remove any trailing slashes so comparisons are perfectly clean
	if abs_scene:sub(-1) == "/" and #abs_scene > 3 then abs_scene = abs_scene:sub(1, -2) end
	if abs_root:sub(-1) == "/" and #abs_root > 3 then abs_root = abs_root:sub(1, -2) end

	-- 4. Check for direct match
	if abs_scene == abs_root then
		return "res://"
	end

	-- 5. Escape paths to keep Lua's regex pattern engine from tripping over special characters
	local escaped_root = abs_root:gsub("([^%w])", "%%%1")

	-- Ensure the file is actually under the root directory tree
	if not abs_scene:match("^" .. escaped_root .. "/") then
		return nil
	end

	-- 6. Safely extract the relative path
	local relative = abs_scene:gsub("^" .. escaped_root .. "/", "")

	return "res://" .. relative
end

local function current_scene_arg()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" or not file:match("%.tscn$") then
		return nil
	end

	return normalize_scene_arg(file)
end

local function telescope_modules()
	local ok, pickers = pcall(require, "telescope.pickers")
	local ok_finders, finders = pcall(require, "telescope.finders")
	local ok_config, telescope_config = pcall(require, "telescope.config")
	local ok_actions, actions = pcall(require, "telescope.actions")
	local ok_state, action_state = pcall(require, "telescope.actions.state")
	if not (ok and ok_finders and ok_config and ok_actions and ok_state) then
		return nil
	end

	return {
		pickers = pickers,
		finders = finders,
		config = telescope_config,
		actions = actions,
		action_state = action_state,
	}
end

local function project_scene_args()
	local root = find_project_root()
	if not root then
		return nil
	end

	local matches = vim.fn.globpath(root, "**/*.tscn", false, true)
	local scenes = {}

	for _, path in ipairs(matches) do
		local normalized = normalize_scene_arg(vim.fs.normalize(path))
		if normalized then
			table.insert(scenes, normalized)
		end
	end

	table.sort(scenes)
	return scenes
end

local function scenes_for_script()
	local file = vim.api.nvim_buf_get_name(0)
	if file == "" or not (file:match("%.gd$") or file:match("%.cs$")) then
		return nil
	end

	local script = normalize_scene_arg(file)
	local root = find_project_root()
	if not script or not root then
		return nil
	end

	local matches = vim.fn.globpath(root, "**/*.tscn", false, true)
	local scenes = {}

	for _, path in ipairs(matches) do
		local lines = vim.fn.readfile(path)
		local content = table.concat(lines, "\n"):gsub("\r", "")
		if content:find(script, 1, true) then
			local normalized = normalize_scene_arg(path)
			if normalized then
				table.insert(scenes, normalized)
			end
		end
	end

	table.sort(scenes)
	return scenes
end

local function pick_scene_list(scenes, title)
	local telescope = telescope_modules()
	if not telescope then
		vim.notify("Telescope is required for scene selection", vim.log.levels.ERROR)
		return false
	end

	telescope.pickers
	    .new({}, {
		    prompt_title = title,
		    finder = telescope.finders.new_table({
			    results = scenes,
		    }),
		    sorter = telescope.config.values.generic_sorter({}),
		    attach_mappings = function(prompt_bufnr)
			    telescope.actions.select_default:replace(function()
				    local selection = telescope.action_state.get_selected_entry()
				    telescope.actions.close(prompt_bufnr)
				    if selection and selection[1] then
					    M.run_scene(selection[1])
				    end
			    end)
			    return true
		    end,
	    })
	    :find()

	return true
end

local cache_path = vim.fn.stdpath("cache") .. "/godotdev_exe_cache.txt"

local function get_godot_executable(callback)
	-- 1. Check permanent cache

	vim.notify("Godot executable not cached.", vim.log.levels.WARN)

	-- 2. Use Neovim's built-in file completion to safely select the executable
	vim.schedule(function()
		vim.ui.input({
			prompt = "Path to Godot executable: ",
			default = vim.fn.expand("$HOME/"),
			completion = "file", -- Enforces safe file auto-completion instead of raw text
		}, function(choice)
			if not choice or choice == "" then
				vim.notify("No path provided.", vim.log.levels.ERROR)
				callback(nil)
				return
			end

			-- Clean up any trailing spaces or tildes
			choice = vim.fs.normalize(vim.trim(choice))

			-- Ensure it's a file, NOT a directory, before calling executable()
			if vim.fn.isdirectory(choice) == 1 then
				vim.notify("Path is a directory, not an executable file.", vim.log.levels.ERROR)
				callback(nil)
				return
			end

			if vim.fn.executable(choice) == 1 then
				local write_file = io.open(cache_path, "w")
				if write_file then
					write_file:write(choice)
					write_file:close()
				end
				vim.notify("Godot path saved permanently!", vim.log.levels.INFO)
				callback(choice)
			else
				vim.notify("File is not executable. Check your permissions.", vim.log.levels.ERROR)
				callback(nil)
			end
		end)
	end)
end

local function run_godot(args)
	local root = find_project_root()
	if not root then
		vim.notify("project.godot not found", vim.log.levels.ERROR)
		return false
	end
	root = vim.fn.fnamemodify(root, ":p")

	root = vim.fs.normalize(root)

	while root:sub(-1):match("[/\\]") and #root > 3 do
		root = root:sub(1, -2)
	end

	local file = io.open(cache_path, "r")
	if file then
		local cached_exe = file:read("*l")
		file:close()
		if cached_exe and cached_exe ~= "" and vim.fn.executable(cached_exe) == 1 then
			cached_exe = vim.fs.normalize(cached_exe)

			local cmd = { cached_exe, "--path", root }
			vim.list_extend(cmd, args or {})

			local run_console = require("godotdev.run_console")
			if run_console.is_enabled() then
				return run_console.start(cmd, root)
			end

			local uv = vim.uv or vim.loop
			local handle

			handle, _ = uv.spawn(cached_exe, {
				args = cmd_args,
				cwd = root,
				detached = true,
			}, function(code, signal)
				if handle then handle:close() end
			end)

			if not handle then
				vim.notify("Libuv process spawn failed on Windows.", vim.log.levels.ERROR)
				return false
			end

			handle:unref()
		else
			vim.system(cmd, { detach = true, text = true }, function(result)
				if result.code == 0 then return end
				vim.schedule(function()
					local stderr = vim.trim(result.stderr or "")
					vim.notify(stderr ~= "" and stderr or "Failed to start Godot",
						vim.log.levels.ERROR)
				end)
			end)
			return true
		end
	end
end

function M.get_exe()
	get_godot_executable(function(path)
		if path then
			vim.notify("Godot executable path is set to: " .. path, vim.log.levels.INFO)
		else
			vim.notify("No valid Godot executable is selected.", vim.log.levels.WARN)
		end
	end)
end

function M.run_project()
	return run_godot()
end

function M.run_current_scene()
	local scene = current_scene_arg()
	if scene then
		return run_godot({ scene })
	end

	local scenes = scenes_for_script()
	if scenes and #scenes == 1 then
		return run_godot({ scenes[1] })
	end

	if scenes and #scenes > 1 then
		return pick_scene_list(scenes, "Scenes using current script")
	end

	vim.notify(
		"Current buffer is not a .tscn scene or a .gd/.cs script attached to a scene in this Godot project",
		vim.log.levels.ERROR
	)
	return false
end

function M.run_scene(scene)
	local normalized = normalize_scene_arg(scene)
	if not normalized then
		vim.notify("Scene must be inside the current Godot project", vim.log.levels.ERROR)
		return false
	end

	return run_godot({ normalized })
end

function M.pick_scene()
	local root = find_project_root()
	if not root then
		vim.notify("project.godot not found", vim.log.levels.ERROR)
		return false
	end

	local scenes = project_scene_args()
	if not scenes or #scenes == 0 then
		vim.notify("No .tscn scenes found in the current Godot project", vim.log.levels.WARN)
		return false
	end

	return pick_scene_list(scenes, "Godot Scenes")
end

function M.setup()
	if vim.fn.exists(":GodotRunProject") ~= 2 then
		vim.api.nvim_create_user_command("GodotRunProject", function()
			M.run_project()
		end, { desc = "Run the current Godot project" })
	end

	if vim.fn.exists(":GodotRunCurrentScene") ~= 2 then
		vim.api.nvim_create_user_command("GodotRunCurrentScene", function()
			M.run_current_scene()
		end, { desc = "Run the current Godot scene" })
	end

	if vim.fn.exists(":GodotRunScene") ~= 2 then
		vim.api.nvim_create_user_command("GodotRunScene", function(opts)
			M.run_scene(opts.args)
		end, {
			nargs = 1,
			complete = "file",
			desc = "Run a specific Godot scene",
		})
	end

	if vim.fn.exists(":GodotRunScenePicker") ~= 2 then
		vim.api.nvim_create_user_command("GodotRunScenePicker", function()
			M.pick_scene()
		end, {
			desc = "Pick and run a Godot scene using Telescope",
		})
	end

	if vim.fn.exists(":GodotGetExe") ~= 2 then
		vim.api.nvim_create_user_command("GodotGetExe", function()
			M.get_exe()
		end, { desc = "Get path to Godot executable" })
	end
end

return M
