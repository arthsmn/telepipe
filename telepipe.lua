--[[
- Shell builtins
	- cd
- Shortcut
	- Ctrl+P → previous command
		- Ctrl+N → next command (after previous)
	- Ctrl+Shift+C → kill running process (oh how the turntables turn)
- New view where each command is a list entry?
	- dunno how I feel about this, it could very easily get cumbersome and i kinda like the current deal, it could end up becoming quite complicated for no fucking reason
]]--

-- SECTION: Helper functions

local lib = require "telepipelib"

function lib.fmtdir(path)
	return path:gsub("^" .. os.getenv "HOME", "~", 1)
end

-- Simple class implementation without inheritance.
local function newclass(init)
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
}

local accels = {
	["win.close-stdin"] = { "<Ctrl>D" },
	["win.focus-cmdbar"] = { "<Ctrl>K" },
}
for k, v in pairs(accels) do
	app:set_accels_for_action(k, v)
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

local runner = newclass(function(self)
	self.pwd = os.getenv "HOME"
	self.outputqueue = ""
	self.history = {}
	self.textview = Gtk.TextView {
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
		on_clicked = function()
			self:chdir()
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
		visible = false,
		direction = "UP",
	}
	self.historybutton:set_create_popup_func(function()
		self:createpopup()
	end)
	self.entry = Gtk.Entry {
		placeholder_text = "Run a command…",
		hexpand = true,
		on_activate = function()
			local text = self.entry.text
			self.entry.text = ""
			self:send(text)
		end,
	}
	local box = Gtk.Box {
		orientation = "HORIZONTAL",
		extra_css_classes = { "linked" },
		margin_top = 6,
		margin_bottom = 6,
		margin_start = 6,
		margin_end = 6,
		self.chdirbutton,
		self.killbutton,
		self.entry,
		self.historybutton,
	}
	self.toolbarview = Adw.ToolbarView {
		content = self.scrolledwin,
		bottom_bar_style = "RAISED_BORDER",
	}
	self.toolbarview:add_bottom_bar(box)
	runners[self.toolbarview] = self
end)

function runner:createpopup()
	local histbox = Gtk.ListBox {
		selection_mode = "NONE",
		valign = "END",
		width_request = 300,
	}
	for i, command in ipairs(self.history) do
		local box = Gtk.Box {
			orientation = "HORIZONTAL",
			spacing = 6,
			margin_top = 6,
			margin_bottom = 6,
			margin_start = 6,
			margin_end = 6,
			Gtk.Label {
				label = command,
				hexpand = true,
				ellipsize = "END",
			},
		}
		local lbox = Gtk.Box {
			orientation = "HORIZONTAL",
			extra_css_classes = { "linked" },
		}
		lbox:append(Gtk.Button {
			icon_name = "edit-redo-symbolic",
			tooltip_text = "Run command again",
			on_clicked = function()
				table.remove(self.history, i)
				self:exec(command)
				self.historybutton.popover:popdown()
				self.historybutton.popover = nil
			end,
		})
		lbox:append(Gtk.Button {
			icon_name = "edit-copy-symbolic",
			tooltip_text = "Copy command to clipboard",
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
			tooltip_text = "Remove from history",
			on_clicked = function()
				table.remove(self.history, i)
				self.historybutton.visible = #self.history > 0
				self.historybutton.popover:popdown()
				self.historybutton.popover = nil
			end,
		})
		box:append(lbox)
		histbox:append(box)
	end
	local scrolled = Gtk.ScrolledWindow {
		child = histbox,
		max_content_height = 300,
		hscrollbar_policy = "NEVER",
		propagate_natural_height = true,
		on_map = function(self)
			self.vadjustment.value = self.vadjustment.upper
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

function runner:chdir()
	if self.subproc then return end
	local filedialog = Gtk.FileDialog {
		initial_folder = Gio.File.new_for_path(self.pwd)
	}
	Gio.Async.start(function()
		local dir = filedialog:async_select_folder(app.active_window)
		if dir then
			self.pwd = dir:get_path()
			self:ensurenewlines()
			local message = "working directory	⇒	%s\n"
			self:print(message:format(self:getpwdlabel()))
		end
		self:updatetitle()
	end)() --Call wrapped async context.
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
		self:updatetitle()
	end)() -- Call wrapped async context.
end

function runner:exec(command)
	if #command < 1 then return end
	local prefix = command:sub(1, 1)
	local dopipein = prefix == ">" or prefix == "|"
	local dopipeout = prefix == "<" or prefix == "|"
	self:ensurenewlines()
	if dopipein then
		self.entry.sensitive = false
		self:putstring "pasting to "
	else
		self.entry.placeholder_text = "Send to running command…"
	end
	self:putstring("⇒	" .. command)
	self:print "\n"
	table.insert(self.history, command)
	self.commandname = command
	if dopipein or dopipeout then
		command = command:sub(2)
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
	if not self.subproc then return self:exec(line) end
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
		stdin:async_close()
	end)() -- Call wrapped async context.
end

-- SECTION: Application window

local function add_new_action(map, name, cb)
	local action = Gio.SimpleAction.new(name)
	action.enabled = true
	action.on_activate = cb
	map:add_action(action)
	return action
end

local window = newclass(function(self)
	self.windowtitle = Adw.WindowTitle.new("Telepipe", "")

	local newbutton = Gtk.Button {
		icon_name = "tab-new-symbolic",
		on_clicked = function()
			self:newtab()
		end,
	}

	self.tabview = Adw.TabView()
	function self.tabview.on_page_attached(tabview, page)
		local r = runners[page.child]
		if not r then return end
		self.toolbarview.top_bar_style = "RAISED_BORDER"
		function r.settitle(r, title, subtitle, icon)
			page.title = title or subtitle
			if icon then
				page.icon = Gio.Icon.new_for_string(icon)
			else
				page.icon = nil
			end
			if tabview.selected_page == page then
				self.windowtitle.subtitle = subtitle
			end
		end
		local title, subtitle = r:gettitle()
		page.title = title or subtitle
		self.windowtitle.subtitle = subtitle
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
				self.windowtitle.title = "Telepipe"
				self.windowtitle.subtitle = ""
				self.toolbarview.top_bar_style = "FLAT"
			end
		end
		return true
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
--				end_packs = {},
			},
			self.tabbar,
		},
	}

	self.win = Adw.ApplicationWindow {
		application = app,
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

	add_new_action(self.win, "close-stdin", function()
		term:close()
	end)

	add_new_action(self.win, "focus-cmdbar", function()
		local r = get_focused_runner()
		if not r then return end
		r:grab()
	end)

	if lib.get_is_devel() then
		self.win:add_css_class "devel"
	end
	windows[self.win] = self
	self.win:present()
end)

function window:newtab()
	local r = runner()
	local page = self.tabview:add_page(r.toolbarview)
	self.tabview:set_selected_page(page)
end

-- SECTION: App startup

function app:on_activate()
	if not app.active_window then return end
	app.active_window:present()
end

function app:on_startup()
	window()
end

return app:run()
