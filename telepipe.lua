--[[
- Split async handling of stdout and stderr.
- Queue up changes to the text view and have them be flushed regularly as well as when each of the pipes close.
- Commands should run interactively when no input is piped in.
	- 'exec' will need to be rewritten to be "send", which will exec a command if none is running, otherwise write the line to stdin of running command
- Get project up and running normally so it doesn't have to run in a terminal
	- can finally unpin the terminal, roflmao whatttt
- Will need to implement some shell builtins
	- Maybe just use a GUI thing for cd
	- Ctrl+D → close process inputfd if open
	- Ctrl+P → previous command
		- Ctrl+N → next command (after previous)
	- Ctrl+Shift+C → kill running process (oh how the turntables turn)
- New view where each command is a list entry?
	- dunno how I feel about this, it could very easily get cumbersome and i kinda like the current deal, it could end up becoming quite complicated for no fucking reason
- Tabs
]]--

-- SECTION: Helper functions

local lib = require "telepipelib"

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

-- SECTION: Command runner class

local runner = newclass(function(self)
	self.pwd = os.getenv "HOME"
	self.outputqueue = ""
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
end)

function runner:assertcallbacks()
	assert(type(self.on_chdir) == "function")
	assert(type(self.on_close) == "function")
	assert(type(self.on_finish) == "function")
end

function runner:getpwdlabel()
	return self.pwd:gsub("^" .. os.getenv "HOME", "~", 1)
end

function runner:chdir()
	local filedialog = Gtk.FileDialog {
		initial_folder = Gio.File.new_for_path(self.pwd)
	}
	Gio.Async.start(function()
		local dir = filedialog:async_select_folder(app.active_window)
		if dir then
			self.pwd = dir:get_path()
		end
		self:on_chdir()
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

-- FIXME:
function runner:handlepipe(pipe, callback, copyafter)
	Gio.Async.start(function()
		local text = ""
		repeat
			local bytes = pipe:async_read_bytes(4096)
			if not bytes.data or #bytes.data == 0 then break end
			text = text .. bytes.data
			local prefix, suffix = text:match "(.*)(\n[^\n]*)"
			callback(prefix)
			text = suffix
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
		local fmtstring = "copied %d line(s) to clipboard."
		self:print(fmtstring:format(self.copyqueuelines))
	else
		self:print "nothing to copy; clipboard has not been modified."
	end
	self.copyqueuelines = nil
	self.copyqueue = nil
end

function runner:waitend()
	if not self.subproc then return end
	Gio.Async.start(function()
		self.subproc:async_wait()
		self:on_finish()
		local status = self.subproc:get_status()
		if status ~= 0 then
			self:print(("exited with status code %d\n"):format(status))
		end
		self.subproc = nil
	end)() -- Call wrapped async context.
end

function runner:exec(command)
	if #command < 1 then return end
	self:assertcallbacks()
	local prefix = command:sub(1, 1)
	local dopipein = prefix == ">" or prefix == "|"
	local dopipeout = prefix == "<" or prefix == "|"
	self:ensurenewlines()
	if dopipein then
		self:putstring "pasting to "
	end
	self:putstring("⇒	" .. command)
	self:print "\n"
	if dopipein or dopipeout then
		command = command:sub(2)
	end
	local launcher = Gio.SubprocessLauncher.new {
		"STDIN_PIPE", "STDOUT_PIPE", "STDERR_PIPE",
	}
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
	if dopipein then self:paste() end
	local function copycb(text)
		self.copyqueuelines = self.copyqueuelines + 1
		self.copyqueue = self.copyqueue .. text
	end
	local function printcb(text)
		self:print(text)
	end
	local stdout = self.subproc:get_stdout_pipe()
	if dopipeout then
		self.copyqueuelines = 0
		self.copyqueue = ""
		self:handlepipe(stdout, copycb, true)
	else
		self:handlepipe(stdout, printcb)
	end
	local stderr = self.subproc:get_stderr_pipe()
	self:handlepipe(stderr, printcb)
	self:waitend()
end

function runner:kill()
	if not self.subproc then return end
	self.subproc:force_exit()
	self:on_finish()
end

function runner:send(line)
	if not self.subproc then return self:exec(line) end
	local stdin = self.subproc:get_stdin_pipe()
	if stdin:is_closed() or stdin:is_closing() then return end
	stdin = Gio.DataOutputStream.new(stdin)
	-- Make sure the running process receives this as a new line.
	stdin:put_string(line .. "\n")
	self:print(line .. "\n")
	-- self:flush()
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
		local stdin = self.subproc:get_stdin_pipe()
		stdin = Gio.DataOutputStream.new(stdin)
		stdin:put_string(inputtext)
		stdin:async_flush()
		stdin:async_close()
		self:on_close()
	end)() -- Call wrapped async context.
end

function runner:close()
	if not self.subproc then return end
	Gio.Async.start(function()
		local stdin = self.subproc:get_stdin_pipe()
		if stdin:is_closed() or stdin:is_closing() then return end
		stdin:async_close()
		self:on_close()
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

local function newwin()
	local term = runner()
	local windowtitle = Adw.WindowTitle.new("Telepipe", term:getpwdlabel())
	function term:on_chdir()
		windowtitle.subtitle = self:getpwdlabel()
	end

	local chdirbutton = Gtk.Button {
		icon_name = "folder-open-symbolic",
		on_clicked = function()
			term:chdir()
		end,
	}
	local killbutton = Gtk.Button {
		icon_name = "edit-delete-symbolic",
		tooltip_text = "Stop running command",
		extra_css_classes = { "destructive-action" },
		visible = false,
		on_clicked = function()
			term:kill()
		end,
	}

	local entry = Gtk.Entry {
		margin_top = 6,
		margin_bottom = 6,
		margin_start = 6,
		margin_end = 6,
		placeholder_text = "Run a command…",
		on_activate = function(self)
			killbutton.visible = true
			local line = self.text
			self.text = ""
			self.placeholder_text = "Send to running command…"
			term:send(line)
		end,
	}
	function term:on_close()
		self.textview:grab_focus()
		entry.sensitive = false
		entry.placeholder_text = "Waiting for command to finish…"
	end
	function term:on_finish()
		killbutton.visible = false
		entry.sensitive = true
		entry.placeholder_text = "Run a command…"
		if not entry.has_focus then
			entry:grab_focus_without_selecting()
		end
	end

	local tbview = Adw.ToolbarView {
		content = term.scrolledwin,
		top_bar_style = "RAISED_BORDER",
		bottom_bar_style = "RAISED_BORDER",
		top_bars = {
			Adw.HeaderBar {
				title_widget = windowtitle,
				start_packs = { chdirbutton },
				end_packs = { killbutton },
			},
		},
	}
	tbview:add_bottom_bar(entry)

	local window = Adw.ApplicationWindow {
		application = app,
		content = tbview,
		width_request = 480,
		height_request = 360,
	}
	if lib.get_is_devel() then
		window:add_css_class "devel"
	end

	add_new_action(window, "close-stdin", function()
		term:close()
	end)

	add_new_action(window, "focus-cmdbar", function()
		entry:grab_focus_without_selecting()
	end)

	entry:grab_focus()
	window:present()
end

function app:on_activate()
	if not app.active_window then return end
	app.active_window:present()
end

function app:on_startup()
	newwin()
end

return app:run()
