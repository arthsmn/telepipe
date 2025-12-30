#!/usr/bin/env lua5.4

--[[
- Commands should run interactively when no input is piped in.
	- 'exec' will need to be rewritten to be "send", which will exec a command if none is running, otherwise write the line to stdin of running command
- Get project up and running normally so it doesn't have to run in a terminal
	- can finally unpin the terminal, roflmao whatttt
- Will need to implement some shell builtins
	- Maybe just use a GUI thing for cd
	- Ctrl+D → close process inputfd if open
	- Ctrl+Shift+C → kill running process (oh how the turntables turn)
- New view where each command is a list entry?
	- dunno how I feel about this, it could very easily get cumbersome and i kinda like the current deal, it could end up becoming quite complicated for no fucking reason
- Tabs
]]--

local LuaGObject = require "LuaGObject"

local Adw = LuaGObject.Adw
local Gdk = LuaGObject.Gdk
local Gio = LuaGObject.Gio
local GLib = LuaGObject.GLib
local GObject = LuaGObject.GObject
local Gtk = LuaGObject.Gtk

local app = Adw.Application {
	application_id = "ca.vtrlx.Telepipe",
}

-- SECTION: Runner

local pwd = os.getenv "HOME"

local function getpwd()
	return pwd
end

local function getpwdpretty()
	return pwd:gsub(os.getenv "HOME", "~")
end

local function chdir(win, on_finish)
	local filedialog = Gtk.FileDialog {
		initial_folder = Gio.File.new_for_path(getpwd()),
	}
	Gio.Async.start(function()
		local dir = filedialog:async_select_folder(win)
		if dir then
			pwd = dir:get_path()
		end
		on_finish()
	end)() -- Call wrapped async context.
end

local subproc

local function exec(command, directory, textbuf, on_finish)
	if #command < 1 then return end
	local textiter = textbuf:get_end_iter()
	textbuf:select_range(textiter, textiter)
	local function print(...)
		for i = 1, select("#", ...) do
			textbuf:insert(textiter, select(i, ...), -1)
			if i < select("#", ...) then textbuf:insert(textiter, "	", -1) end
		end
	end
	local clipboard = Gdk.Display.get_default():get_clipboard()
	local prefix = command:sub(1, 1)
	local dopipein = prefix == ">" or prefix == "|"
	local dopipeout = prefix == "<" or prefix == "|"
	while #textbuf.text > 1 and textbuf.text:sub(-2, -1) ~= "\n\n" do
		print "\n"
	end
	if dopipein then
		print("pasting to ")
	end
	print("⇒", command)
	if dopipein or dopipeout then
		command = command:sub(2)
	end
	local launcher = Gio.SubprocessLauncher.new {
		"STDIN_PIPE", "STDOUT_PIPE", "STDERR_PIPE",
	}
	launcher:set_cwd(getpwd())
	local async = Gio.Async.start(function()
		local stdintext = ""
		if dopipein then
			stdintext = clipboard:async_read_text() or ""
		end
		subproc = launcher:spawnv { os.getenv "SHELL", "-c", command }
		local stdinpipe = subproc:get_stdin_pipe()
		stdinpipe = Gio.DataOutputStream.new(stdinpipe)
		stdinpipe:put_string(stdintext)
		stdinpipe:async_flush()
		stdinpipe:async_close()
		local stdoutpipe = subproc:get_stdout_pipe()
		stdoutpipe = Gio.DataInputStream.new(stdoutpipe)
		local stderrpipe = subproc:get_stderr_pipe()
		stderrpipe = Gio.DataInputStream.new(stderrpipe)
		local stdouttext = ""
		local nlines = 0
		repeat
			local errline
			repeat
				errline = stderrpipe:async_read_line()
				if errline then
					print("\n" .. line)
				end
			until not errline
			local line = stdoutpipe:async_read_line()
			if not line then break end
			nlines = nlines + 1
			if dopipeout then
				stdouttext = stdouttext .. line .. "\n"
			else
				print("\n" .. line)
			end
		until false
		stdoutpipe:async_close()
		stderrpipe:async_close()
		subproc:async_wait_check()
		local status = subproc:get_exit_status()
		if status ~= 0 then
			print("\nexited with status " .. status)
		end
		if dopipeout then
			if #stdouttext > 0 then
				clipboard:set(GObject.Value(GObject.Type.STRING, stdouttext))
				print(("\ncopied %d line(s) to clipboard"):format(nlines))
			else
				print("nothing to copy; clipboard contents are unchanged.")
			end
		end
		subproc = nil
		on_finish()
	end, nil, GLib.PRIORITY_DEFAULT_IDLE)() -- Call async context.
end

local function newwin()
	local textview = Gtk.TextView {
		top_margin = 12,
		bottom_margin = 12,
		left_margin = 18,
		right_margin = 18,
		pixels_above_lines = 2,
		pixels_below_lines = 2,
		pixels_inside_wrap = 0,
		wrap_mode = Gtk.WrapMode.WORD_CHAR,
	}
	local scrolledwin = Gtk.ScrolledWindow {
		child = textview,
		hscrollbar_policy = "NEVER",
	}
	local oldupper = scrolledwin.vadjustment.upper
	function scrolledwin.vadjustment.on_notify.upper()
		local upper = scrolledwin.vadjustment.upper
		if oldupper < upper then
			scrolledwin.vadjustment.value = upper
		end
		oldupper = upper
	end
	local windowtitle = Adw.WindowTitle.new("Telepipe", getpwdpretty())
	local chdirbutton = Gtk.Button {
		icon_name = "folder-open-symbolic",
		on_clicked = function()
			chdir(app.active_window, function()
				windowtitle.subtitle = getpwdpretty()
			end)
		end,
	}
	local killbutton = Gtk.Button {
		icon_name = "edit-delete-symbolic",
		tooltip_text = "Stop running command",
		extra_css_classes = { "destructive-action" },
		visible = false,
		on_clicked = function()
			if not subproc then return end
			subproc:force_exit()
		end,
	}
	local entry = Gtk.Entry {
		margin_top = 6,
		margin_bottom = 6,
		margin_start = 6,
		margin_end = 6,
		placeholder_text = (os.getenv "SHELL"):gsub("[^/]*/", "") .. "$",
		on_activate = function(self)
			textview:grab_focus()
			self.sensitive = false
			killbutton.visible = true
			local text = self.text
			self.text = ""
			exec(text,
				getpwd(),
				textview.buffer,
				function()
					self.sensitive = true
					self:grab_focus()
					killbutton.visible = false
				end)
		end,
	}
	local tbview = Adw.ToolbarView {
		content = scrolledwin,
		top_bar_style = "RAISED_BORDER",
		bottom_bar_style = "RAISED_BORDER",
		top_bars = {
			Adw.HeaderBar {
				title_widget = windowtitle,
				start_packs = { chdirbutton },
				end_packs = { killbutton },
			},
		},
		bottom_bars = { entry },
	}
	local window = Adw.ApplicationWindow {
		application = app,
		content = tbview,
		width_request = 640,
		height_request = 480,
	}
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
