--[[
- signals
	- replace "Stop running command" button with a menu button that allows the user to send signals (which signals?)
- actions
	- middle click app icon from the dash to open a new window
- app icon
	- electric slabtop typewriter with ">_" written on the paper (will differentiate against other typewriter apps)
- resources (icons)
]]--

-- SECTION: Helper functions

local lib = require "telepipelib"

local app_id = lib.get_app_id()
local app_title = "Telepipe"

-- Replace's the user's $HOME with the tilde "~" character, a common convention when displaying paths.
function lib.fmtdir(path)
	return path:gsub("^" .. os.getenv "HOME", "~", 1)
end

function lib.strip(text)
	return text:gsub("^%s*", ""):gsub("%s*$", "")
end

-- Simple class implementation without inheritance.
function lib.newclass(init)
	local c = {}
	local mt = {}
	c.__index = c
	function mt:__call(...)
		local obj = setmetatable({}, c)
		init(obj, ...)
		return obj
	end
	function c:isa(klass)
		return getmetatable(self) == klass
	end
	return setmetatable(c, mt)
end

-- SECTION: Application

-- This app runs in Flatpak, which puts Lua libraries outside of the standard paths. These lines tell Lua to look for libraries where Flatpak has put them.
package.cpath = "/app/lib/lua/5.5/?.so;" .. package.cpath
package.path = "/app/share/lua/5.5/?.lua;" .. package.path

local LuaGObject = require "LuaGObject"

local Adw = LuaGObject.Adw
local Gdk = LuaGObject.Gdk
local Gio = LuaGObject.Gio
local GLib = LuaGObject.GLib
local GObject = LuaGObject.GObject
local Gtk = LuaGObject.Gtk

local app = Adw.Application {
	application_id = lib.get_app_id(),
	flags = { "HANDLES_COMMAND_LINE" },
}

app:add_main_option("new-window", string.byte "n", "IN_MAIN", "NONE", "Create a new window.")

local accels = {
	["win.focus-cmdbar"] = { "<Ctrl>K" },
	["win.new-tab"] = { "<Ctrl>T" },
	["win.close-tab"] = { "<Ctrl>W" },
	["win.new-win"] = { "<Ctrl>N" },
	["win.open-folder"] = { "<Ctrl>D" },
	["win.signal-endinput"] = { "<Ctrl><Alt>D" },
	["win.shortcuts"] = { "<Ctrl><Shift>question" },
	["win.about"] = { "F1" },
}
for k, v in pairs(accels) do
	app:set_accels_for_action(k, v)
end

function lib.addnewaction(map, name, cb)
	local action = Gio.SimpleAction.new(name)
	action.enabled = true
	action.on_activate = cb
	map:add_action(action)
	return action
end

-- SECTION: Important variables

local windows = {}
local runners = {}

local function get_focused_window()
	if not app.active_window then return end
	return windows[app.active_window]
end

local function get_focused_runner()
	local win = get_focused_window()
	if not win then return end
	local tabview = win.tabview
	if not tabview then return end
	local page = tabview.selected_page
	if not page then return end
	return runners[page.child]
end

-- SECTION: Command runner class

local runner = lib.newclass(function(self, pwd)
	self.pwd = pwd or os.getenv "HOME"
	self.outputqueue = ""
	self.history = {}
	self.textview = Gtk.TextView {
		extra_css_classes = { "numeric" },
		top_margin = 12,
		bottom_margin = 12,
		left_margin = 18,
		right_margin = 18,
		pixels_above_lines = 2,
		pixels_below_lines = 2,
		pixels_inside_wrap = 0,
		wrap_mode = Gtk.WrapMode.WORD_CHAR,
	}
	self.buffer = self.textview.buffer
	self.scrolledwin = Gtk.ScrolledWindow {
		child = self.textview,
		hscrollbar_policy = "NEVER",
	}
	local oldupper = self.scrolledwin.vadjustment.upper
	function self.scrolledwin.vadjustment.on_notify.upper()
		local upper = self.scrolledwin.vadjustment.upper
		if oldupper < upper then
			GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
				self.scrolledwin.vadjustment.value = upper
			end)
		end
		oldupper = upper
	end
	self.chdirbutton = Gtk.Button {
		icon_name = "folder-open-symbolic",
		tooltip_text = "Select working directory",
		on_clicked = function()
			self:trychdir()
		end,
	}
	self.killbutton = Gtk.Button {
		icon_name = "edit-delete-symbolic",
		tooltip_text = "Stop running command",
		extra_css_classes = { "destructive-action" },
		visible = false,
		on_clicked = function()
			self:kill()
		end,
	}
	self.historybutton = Gtk.MenuButton {
		tooltip_text = "Command history",
		visible = false,
		direction = "UP",
	}
	self.historybutton:set_create_popup_func(function()
		self:createpopup()
	end)
	self.sendbutton = Gtk.Button {
		extra_css_classes = { "suggested-action" },
		icon_name = "media-playback-start-symbolic",
		tooltip_text = "Run command",
		sensitive = false,
		on_clicked = function()
			self:doactivate()
		end,
	}
	self.entry = Gtk.Text {
		extra_css_classes = { "numeric" },
		placeholder_text = "Run a command…",
		hexpand = true,
		on_changed = function()
			self.sendbutton.sensitive = #self.entry.text > 0
			self.clearbutton.visible = #self.entry.text > 0
		end,
		on_activate = function()
			self:doactivate()
		end,
	}
	self.clearbutton = Gtk.Button {
		icon_name = "edit-clear-symbolic",
		css_name = "image",
		visible = false,
		on_clicked = function()
			self.entry.text = ""
			self:grab()
		end,
	}
	local entrybox = Gtk.Box {
		orientation = "HORIZONTAL",
		css_name = "entry",
		self.entry,
		self.clearbutton,
	}
	local lbox = Gtk.Box {
		orientation = "HORIZONTAL",
		extra_css_classes = { "linked" },
		self.chdirbutton,
		self.killbutton,
		entrybox,
		self.historybutton,
	}
	local box = Gtk.Box {
		orientation = "HORIZONTAL",
		margin_top = 6,
		margin_bottom = 6,
		margin_start = 6,
		margin_end = 6,
		spacing = 6,
		lbox,
		self.sendbutton,
	}
	self.toolbarview = Adw.ToolbarView {
		content = self.scrolledwin,
		bottom_bar_style = "RAISED_BORDER",
	}
	self.toolbarview:add_bottom_bar(box)
	runners[self.toolbarview] = self
end)

function runner:doactivate()
	-- Blank lines are allowed for running apps.
	if not self.subproc and #self.entry.text == 0 then return end
	local text = self.entry.text
	self.entry.text = ""
	self:send(text)
end

function runner:createpopup()
	local maxwidth = app.active_window.width * 0.75
	local histbox = Gtk.ListBox {
		selection_mode = "NONE",
		valign = "END",
		width_request = maxwidth,
	}
	for i, command in ipairs(self.history) do
		local box = Gtk.Box {
			orientation = "HORIZONTAL",
			halign = "FILL",
			spacing = 6,
			margin_top = 6,
			margin_bottom = 6,
			margin_start = 6,
			margin_end = 6,
			Gtk.Label {
				label = command,
				halign = "START",
				hexpand = true,
				margin_start = 6,
				margin_end = 24,
				selectable = true,
				wrap = true,
				wrap_mode = "WORD_CHAR",
			},
		}
		local lbox = Gtk.Box {
			orientation = "HORIZONTAL",
			halign = "END",
			extra_css_classes = { "linked" },
		}
		lbox:append(Gtk.Button {
			icon_name = "edit-redo-symbolic",
			tooltip_text = "Run command again",
			valign = "CENTER",
			on_clicked = function()
				self.historybutton.popover:popdown()
				self.historybutton.popover = nil
				self:tryexec(command)
			end,
		})
		lbox:append(Gtk.Button {
			icon_name = "edit-copy-symbolic",
			tooltip_text = "Copy command to clipboard",
			valign = "CENTER",
			on_clicked = function()
				local clipboard = Gdk.Display.get_default():get_clipboard()
				clipboard:set(GObject.Value(
					GObject.Type.STRING, command))
				self.historybutton.popover:popdown()
				self.historybutton.popover = nil
			end,
		})
		lbox:append(Gtk.Button {
			icon_name = "edit-delete-symbolic",
			extra_css_classes = { "destructive-action" },
			tooltip_text = "Remove from history",
			valign = "CENTER",
			on_clicked = function()
				table.remove(self.history, box.parent:get_index() + 1)
				histbox:remove(box.parent)
				if #self.history == 0 then
					self.historybutton.visible = false
					self.historybutton.popover:popdown()
					self.historybutton.popover = nil
				end
			end,
		})
		box:append(lbox)
		histbox:append(box)
	end
	local scrolled = Gtk.ScrolledWindow {
		child = histbox,
		max_content_height = 300,
		propagate_natural_height = true,
		hscrollbar_policy = "NEVER",
		on_map = function(self)
			GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
				self.vadjustment.value = self.vadjustment.upper
			end)
		end,
	}
	self.historybutton.popover = Gtk.Popover {
		halign = "END",
		child = scrolled,
		on_closed = function()
			self.historybutton.popover = nil
			self.historybutton.active = false
		end,
	}
end

function runner:grab()
	self.entry:grab_focus_without_selecting()
end

function runner:getpwdlabel()
	return lib.fmtdir(self.pwd)
end

function runner:gettitle()
	return self.commandname, self:getpwdlabel(), nil
end

function runner:updatetitle()
	if not self.settitle then return end
	self:settitle(self:gettitle())
end

function runner:trychdir()
	local filedialog = Gtk.FileDialog {
		initial_folder = Gio.File.new_for_path(self.pwd)
	}
	Gio.Async.start(function()
		local dir = filedialog:async_select_folder(app.active_window)
		if dir then
			self:chdir(dir:get_path())
			self:ensurenewlines()
			-- guaranteed to be a dir, so this is safe
			local message = "working directory ⇒	%s\n"
			self:print(message:format(self:getpwdlabel()))
		end
	end)() --Call wrapped async context.
end

function runner:chdir(path)
	if self.subproc then return end
	local dir = Gio.File.new_for_path(path)
	if dir:query_file_type() ~= "DIRECTORY" then
		self:print(("not a directory: %s\n"):format(path))
	else
		self.pwd = dir:get_path()
	end
	self:updatetitle()
end

function runner:showfolder()
	local file = Gio.File.new_for_path(self.pwd)
	local launcher = Gtk.FileLauncher.new(file)
	Gio.Async.start(function()
		launcher:async_launch()
	end)() -- Call wrapped async context.
end

function runner:putstring(text)
	local textiter = self.buffer:get_end_iter()
	self.buffer:insert(textiter, text, -1)
end

function runner:flush()
	if #self.outputqueue < 1 then return end
	if not self.outputqueue:match "[^\n]" then return end
	local newlines = self.outputqueue:match "\n*$"
	local output = self.outputqueue:sub(1, -#newlines - 1)
	if output then
		self:putstring(output)
	end
	self.outputqueue = newlines or ""
end

function runner:print(... items)
	local text = table.concat(items, "	")
	self.outputqueue = self.outputqueue .. text
	local outputcount = #self.outputqueue
	GLib.timeout_add(10, 120, function()
		-- If the output queue length hasn't changed, then flush it.
		if #self.outputqueue == outputcount then
			self:flush()
		end
	end)
end

function runner:ensurenewlines()
	self:flush()
	while #self.buffer.text > 0 and self.buffer.text:sub(-2, -1) ~= "\n\n" do
		self:putstring "\n"
	end
	self.outputqueue = self.outputqueue:match "[^\n].*" or ""
end

function runner:handlepipe(pipe, callback, copyafter)
	Gio.Async.start(function()
		repeat
			local bytes = pipe:async_read_bytes(4096)
			if not bytes.data or #bytes.data == 0 then break end
			callback(bytes.data)
		until false
		pipe:async_close()
		if copyafter then self:copy() end
	end)() -- Call wrapped async context.
end

function runner:copy()
	if not self.copyqueue then
		return
	elseif #self.copyqueue > 0 then
		local clipboard = Gdk.Display.get_default():get_clipboard()
		clipboard:set(GObject.Value(GObject.Type.STRING, self.copyqueue))
		self:print "copied output to clipboard.\n"
	else
		self:print "nothing to copy; clipboard has not been modified."
	end
	self.copyqueue = nil
end

function runner:waitend(async)
	if not self.subproc then return end
	Gio.Async.start(function()
		self.subproc:async_wait()
		local status = self.subproc:get_status()
		if status ~= 0 then
			self:print(("exited with status code %d\n"):format(status))
		end
		self.commandname = nil
		self.subproc = nil
		self.chdirbutton.visible = true
		self.historybutton.visible = #self.history > 0
		self.killbutton.visible = false
		self.entry.sensitive = true
		self.entry.placeholder_text = "Run a command…"
		self.sendbutton.icon_name = "media-playback-start-symbolic"
		self.sendbutton.tooltip_text = "Run command"
		if #self.entry.text > 0 then self.sendbutton.sensitive = true end
		self:updatetitle()
		self.entry:grab_focus_without_selecting()
	end)() -- Call wrapped async context.
end

function runner:inserthistory(command)
	for i = 1, #self.history do
		local index = 1 + #self.history - i
		local c = self.history[index]
		if c == command then
			table.remove(self.history, index)
		end
	end
	table.insert(self.history, command)
end

function runner:tryexec(command)
	command = lib.strip(command)
	if #command == 0 then return end
	local name = command:match "^[^%s]*"
	if runner.builtin[name] then
		self:ensurenewlines()
		self:putstring("⇒	" .. command)
		self:print "\n"
		local param = command:match " (.*)"
		-- The "cd" command has special behaviour for history handling.
		if name ~= "cd" then
			self:inserthistory(command)
		end
		runner.builtin[name](self, param)
		self.historybutton.visible = #self.history > 0
	else
		self:exec(command)
	end
end

function runner:exec(command)
	self:inserthistory(command)
	self:ensurenewlines()
	local prefix = command:sub(1, 1)
	local dopipein = prefix == ">" or prefix == "|"
	local dopipeout = prefix == "<" or prefix == "|"
	if dopipein then
		self.entry.sensitive = false
		self:putstring "pasting to "
	else
		self.entry.placeholder_text = "Send to running command…"
		self.sendbutton.tooltip_text = "Send to running command"
	end
	self:putstring("⇒	" .. command)
	self:print "\n"
	self.commandname = command
	if dopipein or dopipeout then
		command = lib.strip(command:sub(2))
	end
	local launcherargs = { "STDIN_PIPE", "STDOUT_PIPE", "STDERR_PIPE" }
	if not dopipeout then
		-- If the output isn't being copied, then the streams need to be merged.
		launcherargs[3] = "STDERR_MERGE"
	end
	local launcher = Gio.SubprocessLauncher.new(launcherargs)
	launcher:set_cwd(self.pwd)
	launcher:setenv("TERM", "dumb")
	launcher:setenv("PAGER", "cat")
	self.subproc = launcher:spawnv {
		"flatpak-spawn",
		"--host",
		"--watch-bus",
		"--env=TERM=dumb",
		"--env=PAGER=cat",
		os.getenv "SHELL",
		"-c",
		command,
	}
	self.chdirbutton.visible = false
	self.historybutton.visible = false
	self.killbutton.visible = true
	self.sendbutton.icon_name = "send-to-symbolic"
	self.sendbutton.tooltip_text = "Send to running command"
	if dopipein then self:paste() end
	local function copycb(text)
		self.copyqueue = self.copyqueue .. text
	end
	local function printcb(text)
		self:print(text)
	end
	local stdout = self.subproc:get_stdout_pipe()
	if dopipeout then
		self.copyqueue = ""
		self:handlepipe(stdout, copycb, true)
		local stderr = self.subproc:get_stderr_pipe()
		self:handlepipe(stderr, printcb)
	else
		self:handlepipe(stdout, printcb)
	end
	self:updatetitle()
	self:waitend()
end

function runner:kill()
	if not self.subproc then return end
	self.subproc:force_exit()
end

function runner:send(line)
	if not self.subproc then return self:tryexec(line) end
	local stdin = self.subproc:get_stdin_pipe()
	if stdin:is_closed() or stdin:is_closing() then return end
	stdin = Gio.DataOutputStream.new(stdin)
	-- Print the user input before sending it, in case the program exits before the print is registered. Yes, this may matter.
	self:print(line .. "\n")
	self:flush()
	stdin:put_string(line .. "\n")
	-- Make sure further output is prefixed with a line break.
	if self.outputqueue:sub(1, 1) ~= "\n" then
		self.outputqueue = "\n" .. self.outputqueue
	end
end

function runner:paste()
	assert(self.subproc)
	Gio.Async.start(function()
		local clipboard = Gdk.Display.get_default():get_clipboard()
		local inputtext = clipboard:async_read_text()
		if not inputtext or #inputtext < 1 then return end
		self.entry.sensitive = false
		local stdin = self.subproc:get_stdin_pipe()
		stdin = Gio.DataOutputStream.new(stdin)
		stdin:put_string(inputtext)
		stdin:async_flush()
		stdin:async_close()
	end)() -- Call wrapped async context.
end

function runner:close()
	if not self.subproc then return end
	Gio.Async.start(function()
		local stdin = self.subproc:get_stdin_pipe()
		if stdin:is_closed() or stdin:is_closing() then return end
		self.entry.sensitive = false
		self.sendbutton.sensitive = false
		stdin:async_close()
	end)() -- Call wrapped async context.
end

-- Built-in runner functions. If a command matches any of these names, it'll instead call a built-in.
runner.builtin = {}

function runner.builtin:cd(dir)
	if not dir or #dir == 0 then dir = os.getenv "HOME" end
	local current = Gio.File.new_for_path(self.pwd)
	local target = current:resolve_relative_path(dir)
	if target then
		dir = target:get_path()
		self:inserthistory("cd " .. lib.fmtdir(target:get_path()))
	end
	self:chdir(dir)
end

function runner.builtin:exit()
	-- No need to save history or anything, and this is guaranteed to be successful.
	self.tabview:close_page(self.tabpage)
	if self.tabview.n_pages == 0 then
		app.active_window:close()
	end
end

function runner.builtin:help()
	self:print [[
Telepipe is a command-line shell. Run command-line applications as you would normally.
Add a > at the start of a command to paste your clipboard's contents into the command's input. Add a < at the start of a command to copy its output to the clipboard. Add a | at the start of a command to do both, pasting the clipboard as input and copying the output back to the clipboard.
Telepipe's built-in commands are
• cd [directory]
	Changes the current working directory to the given path.
• exit
	Closes the current tab. If no tabs remain, closes the current window.
• help
	Print this help text.
This software is experimental; expected features may not exist or may be subject to change. Many command-line apps will behave unusually, though in some cases this may be remedied using certain parameters or flags. Programs requiring the terminal will not function at all, and may output odd-looking text—avoid these applications.
Visit Telepipe's code repository at https://github.com/vtrlx/telepipe/ for more information or to submit an issue.
]]
end

-- SECTION: Application menus

local appmenu = Gio.Menu()
appmenu:append("New Window", "win.new-win")
appmenu:append("Open Working Directory", "win.open-folder")
appmenu:append("Keyboard Shortcuts", "win.shortcuts")
appmenu:append("About " .. app_title, "win.about")

local function shortcuts(parent)
	local cut = Adw.ShortcutsItem.new_from_action
	local shortdlg = Adw.ShortcutsDialog {
		Adw.ShortcutsSection {
			title = "Window",
			cut("New tab", "win.new-tab"),
			cut("New window", "win.new-win"),
			cut("Show keyboard shortcuts", "win.shortcuts"),
		},
		Adw.ShortcutsSection {
			title = "Runner tab",
			cut("Show working directory in Files", "win.open-folder"),
			cut("Signal end of input", "win.signal-endinput"),
			cut("Focus command entry", "win.focus-cmdbar"),
			cut("Close tab", "win.close-tab"),
		},
	}
	shortdlg:present(parent)
end

local function about(parent)
	local aboutdlg = Adw.AboutDialog {
		application_icon = app_id,
		application_name = app_title,
		copyright = "© 2026 Victoria Lacroix",
		developer_name = "Victoria Lacroix",
		issue_url = "https://github.com/vtrlx/telepipe/issues/new",
		license_type = "GPL_3_0",
		version = lib.get_app_ver(),
		website = "https://www.vtrlx.ca/apps/telepipe/",
	}

	aboutdlg:add_link("Contact the Developer", "mailto:victoria@vtrlx.ca?subject=Telepipe App")

	aboutdlg:present(parent)
end

-- SECTION: Application window

local window
window = lib.newclass(function(self)
	self.windowtitle = Adw.WindowTitle.new(app_title, "")

	local newbutton = Gtk.Button {
		icon_name = "tab-new-symbolic",
		tooltip_text = "New tab",
		on_clicked = function()
			self:newtab()
		end,
	}

	local menupopover = Gtk.PopoverMenu.new_from_model(appmenu)
	menupopover.halign = "END"
	local menubutton = Gtk.MenuButton {
		direction = "DOWN",
		icon_name = "open-menu-symbolic",
		popover = menupopover,
	}

	self.tabview = Adw.TabView()
	function self.tabview.on_page_attached(tabview, page)
		local r = runners[page.child]
		if not r then return end
		r.tabview = self.tabview
		self.toolbarview.top_bar_style = "RAISED_BORDER"
		function r.settitle(r, title, subtitle, icon)
			page.title = title or subtitle
			if icon then
				page.icon = Gio.Icon.new_for_string(icon)
			else
				page.icon = nil
			end
			if tabview.selected_page == page then
				self.win.title = subtitle
				self.windowtitle.subtitle = subtitle
			end
		end
		local title, subtitle = r:gettitle()
		page.title = title or subtitle
		self.windowtitle.subtitle = subtitle
		self.showfolder.enabled = true
	end
	function self.tabview.on_page_detached(tabview, page)
		local r = runners[page.child]
		if not r then return end
		-- Stub it out to remove references to this tab view.
		function r:settitle() end
	end
	function self.tabview.on_notify(tabview, spec)
		if spec.name == "selected-page" and tabview.selected_page then
			local r = runners[self.tabview.selected_page.child]
			r:updatetitle()
			r.entry:grab_focus_without_selecting()
		end
	end
	function self.tabview.on_close_page(tabview, page)
		local r = runners[page.child]
		local do_close = true
		if r and r.subproc then
			do_close = false
		end
		self.tabview:close_page_finish(page, do_close)
		if not do_close then
			local body = "A command %q is running."
			local name = r.commandname
			if #name > 20 then
				commandname = utf8.char(utf8.codepoint(name, 1, 20))
			end
			body = body:format(name)
			local dlg = Adw.AlertDialog.new("Stop running command?", body)
			dlg:add_response("close", "Keep running")
			dlg:set_response_appearance("close", "DEFAULT")
			dlg:add_response("discard", "Stop and close tab")
			dlg:set_response_appearance("discard", "DESTRUCTIVE")
			function dlg.on_response(dlg, response)
				if response == "discard" then
					r:kill()
					runners[page.child] = nil
					self.tabview:close_page(page)
				end
			end
			dlg:choose(app.active_window)
		else
			runners[page.child] = nil
			if self.tabview:get_n_pages() == 0 then
				self.win.title = app_title
				self.windowtitle.title = app_title
				self.windowtitle.subtitle = ""
				self.toolbarview.top_bar_style = "FLAT"
				self.showfolder.enabled = false
			end
		end
		return true
	end
	function self.tabview.on_create_window()
		local win = window()
		return win.tabview
	end

	self.tabbar = Adw.TabBar {
		view = self.tabview,
	}

	self.toolbarview = Adw.ToolbarView {
		content = self.tabview,
		top_bar_style = "FLAT",
		top_bars = {
			Adw.HeaderBar {
				title_widget = self.windowtitle,
				start_packs = { newbutton },
				end_packs = { menubutton },
			},
			self.tabbar,
		},
	}

	self.win = Adw.ApplicationWindow {
		application = app,
		title = app_title,
		content = self.toolbarview,
		default_width = 640,
		default_height = 480,
		width_request = 480,
		height_request = 360,
	}
	function self.win.on_close_request()
		local n_pages = self.tabview:get_n_pages()
		local running = {}
		for i = 1, n_pages do
			local page = self.tabview:get_nth_page(n_pages - i)
			local r = runners[page.child]
			if r and r.subproc then
				table.insert(running, r)
			end
		end
		local function close()
			for _, r in ipairs(running) do
				r:kill()
			end
			Gio.Async.start(function()
				-- Need to wait for the subprocesses to actually finish befor attempting to close the window again.
				for _, r in ipairs(running) do
					if r.subproc then r.subproc:async_wait() end
				end
				-- Give it a tiny wait.
				GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
					self.win:close()
				end)
			end)()
		end
		if #running > 0 then
			local dlg = Adw.AlertDialog.new("Close window?", "There are running commands.")
			dlg:add_response("cancel", "Keep open")
			dlg:set_response_appearance("cancel", "DEFAULT")
			dlg:add_response("discard", "Stop and close")
			dlg:set_response_appearance("discard", "DESTRUCTIVE")
			function dlg:on_response(response)
				if response == "discard" then close() end
			end
			dlg:choose(self.win)
			return true
		else
			windows[self.win] = nil
			-- Explicitly close each runner page to free their resources. Cleaner than hooking into e.g. __gc.
			for i = 1, n_pages do
				local page = self.tabview:get_nth_page(n_pages - i)
				self.tabview:close_page(page)
			end
			return false
		end
	end

	lib.addnewaction(self.win, "signal-endinput", function()
		local r = get_focused_runner()
		if not r then return end
		r:close()
	end)

	lib.addnewaction(self.win, "focus-cmdbar", function()
		local r = get_focused_runner()
		if not r then return end
		r:grab()
	end)

	self.showfolder = lib.addnewaction(self.win, "open-folder", function()
		local r = get_focused_runner()
		if not r then return end
		r:showfolder()
	end)
	self.showfolder.enabled = false

	lib.addnewaction(self.win, "new-tab", function()
		self:newtab()
	end)

	lib.addnewaction(self.win, "new-win", function()
		local win = window()
		win:newtab()
	end)

	lib.addnewaction(self.win, "close-tab", function()
		local page = self.tabview.selected_page
		if not page then return end
		self.tabview:close_page(page)
	end)

	lib.addnewaction(self.win, "shortcuts", function()
		shortcuts(self.win)
	end)

	lib.addnewaction(self.win, "about", function()
		about(self.win)
	end)

	if lib.get_is_devel() then
		self.win:add_css_class "devel"
	end
	windows[self.win] = self
	self.win:present()
end)

function window:newtab()
	local pwd
	local selected = self.tabview.selected_page
	local position = 0
	if selected then
		local current = runners[selected.child]
		pwd = current.pwd
		position = 1 + self.tabview:get_page_position(selected)
	end
	local r = runner(pwd)
	r.tabpage = self.tabview:insert(r.toolbarview, position)
	self.tabview:set_selected_page(r.tabpage)
end

-- SECTION: App startup

function app:on_activate()
	if not app.active_window then return end
	app.active_window:present()
end

-- Handles command-line options. Currently, only serves to open a new Telepipe window in an already-running instance, either from the command-line, by manually selecting the "New Window" action from the dash, or by middle-clicking the app icon in the dash.
function app:on_command_line(cli)
	local opts = cli:get_options_dict()
	if cli:get_is_remote() and opts:contains "new-window" then
		local win = window()
		win:newtab()
	end
	-- Signal that command line options have been handled and that the app should continue starting up.
	cli:set_exit_status(0)
	cli:done()
	return -1
end

function app:on_startup()
	local win = window()
	win:newtab()
	local r = get_focused_runner()
	r:print [[
Welcome to Telepipe. Type "help" in the command entry below (without quotation marks) then press the Enter key for more information on using this program.
]]
end

return app:run { lib.get_cli_args() }
