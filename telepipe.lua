--[[ telepipe.lua (graphical command-line shell)
Copyright © 2026 Victoria Lacroix

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <https://www.gnu.org/licenses/>. ]]--

-- SECTION: Helper functions

local lib = require "telepipelib"

local _ = lib.gettext

local app_id = lib.get_app_id()
local app_title = _ "Telepipe"

-- Replace's the user's $HOME with the tilde "~" character, a common convention when displaying paths.
function lib.fmtdir(path)
	return path:gsub("^" .. os.getenv "HOME", "~", 1)
end

function lib.expanddir(path)
	return path:gsub("^~", os.getenv "HOME", 1)
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
	resource_base_path = "/ca/vtrlx/Telepipe", -- Needs to be hardcoded.
	flags = { "HANDLES_COMMAND_LINE" },
}

app:add_main_option("new-window", string.byte "n", "IN_MAIN", "NONE", "Create a new window.")

local accels = {
	["win.focus-cmdbar"] = { "<Ctrl>K" },
	["win.new-tab"] = { "<Ctrl>T" },
	["win.close-tab"] = { "<Ctrl>W" },
	["win.new-win"] = { "<Ctrl>N" },
	["win.open-folder"] = { "<Ctrl>D" },
	["win.search"] = { "<Ctrl>F" },
	["win.signal-kill"] = { "<Ctrl><Alt>C" },
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

-- SECTION: GResources

do -- Load and register GResource.
	local resource, err = Gio.Resource.load "/app/data/telepipe.gresource"
	if resource then
		Gio.resources_register(resource)
	else
		print("Failed to load resource", err)
	end
end -- Load and register GResource.

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

-- SECTION: Custom styling

do
	local styleman = Adw.StyleManager.get_default()
	local display = Gdk.Display.get_default()
	local provider = Gtk.CssProvider()
	provider:load_from_string [[
		/* Even without actions, images will become more opque on hover. This prevents that from happening. */
		image.nohover:hover {
			opacity: 0.7;
		}
	]]
	Gtk.StyleContext.add_provider_for_display(display, provider, 1000000)
end

-- SECTION: Command runner class

local runnermenu = Gio.Menu()
runnermenu:append(_ "Stop Running Command", "win.signal-kill")
runnermenu:append(_ "Close Command Input", "win.signal-endinput")

local runner = lib.newclass(function(self, pwd)
	self.pwd = pwd or os.getenv "HOME"
	self.outputqueue = ""
	local factory = Gtk.SignalListItemFactory {
		on_setup = function(_, ...) self:setupitem(...) end,
		on_bind = function(_, ...) self:binditem(...) end,
		on_unbind = function(_, ...) self:unbinditem(...) end,
		on_teardown = function(_, ...) self:teardownitem(...) end,
	}
	self.history = Gtk.StringList()
	self.listitems = {}
	self.histview = Gtk.ListView {
		valign = "END",
		width_request = 300,
		factory = factory,
		model = Gtk.NoSelection {
			model = self.history,
		},
	}
	self.matches = {}
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
	function self.buffer.on_changed()
		if self.searchbar.search_mode_enabled then
			self:findall(self.searchentry.text)
		end
	end
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

	-- Search stuff. Lots of stuff going on here.
	self.searchentry = Gtk.Text {
		placeholder_text = _ "Find in output…",
		hexpand = true,
		on_activate = function()
			self:searchnext(self.searchentry.text)
		end,
	}
	function self.searchentry.on_notify.text()
		if not self.searchbar.search_mode_enabled then return end
		if #self.searchentry.text == 0 then
			self.matchlabel.label = ""
			self.searchclearbutton.visible = false
			return
		end
		self:findall(self.searchentry.text)
		self.searchclearbutton.visible = true
	end
	self.searchclearbutton = Gtk.Button {
		css_name = "image",
		icon_name = "tp-clear-symbolic",
		margin_start = 12,
		visible = false,
		on_clicked = function()
			self.searchentry.text = ""
			self.searchentry:grab_focus()
		end,
	}
	self.matchlabel = Gtk.Label {
		extra_css_classes = { "numeric" },
		halign = "END",
		hexpand = false,
		margin_start = 6,
		margin_end = 6,
	}
	function self.matchlabel.on_notify.text()
		self.matchlabel.visible = #self.matchlabel.text > 0
	end
	local searchentrybox = Gtk.Box {
		orientation = "HORIZONTAL",
		css_name = "entry",
		Gtk.Image {
			extra_css_classes = { "nohover" },
			icon_name = "tp-search-symbolic",
		},
		self.searchentry,
		self.searchclearbutton,
		self.matchlabel,
	}
	local prevmatchbutton = Gtk.Button {
		icon_name = "tp-up-symbolic",
		tooltip_text = _ "Go to previous match",
		on_clicked = function()
			self:searchprev(self.searchentry.text)
		end,
	}
	local nextmatchbutton = Gtk.Button {
		icon_name = "tp-down-symbolic",
		tooltip_text = _ "Go to next match",
		on_clicked = function()
			self:searchnext(self.searchentry.text)
		end,
	}
	local searchbox = Gtk.Box {
		orientation = "HORIZONTAL",
		extra_css_classes = { "linked" },
		searchentrybox,
		prevmatchbutton,
		nextmatchbutton,
	}
	local searchclamp = Adw.Clamp {
		orientation = "HORIZONTAL",
		child = searchbox,
		maximum_size = 600,
	}
	self.searchbar = Gtk.SearchBar {
		child = searchclamp,
		search_mode_enabled = false,
		show_close_button = true,
	}
	self.searchbar:connect_entry(self.searchentry)
	self.chdirbutton = Gtk.Button {
		icon_name = "tp-folder-symbolic",
		tooltip_text = _ "Select working directory…",
		on_clicked = function()
			self:trychdir()
		end,
	}
	local menupopover = Gtk.PopoverMenu.new_from_model(runnermenu)
	menupopover.halign = "START"
	self.menubutton = Gtk.MenuButton {
		icon_name = "tp-signal-symbolic",
		direction = "UP",
		tooltip_text = _ "Signal to running command…",
		popover = menupopover,
		visible = false,
	}
	self.historybutton = Gtk.MenuButton {
		tooltip_text = "Command history",
		icon_name = "tp-history-symbolic",
		visible = false,
		direction = "UP",
		popover = Gtk.Popover {
			halign = "END",
			child = Gtk.ScrolledWindow {
				child = self.histview,
				max_content_height = 300,
				propagate_natural_height = true,
				hscrollbar_policy = "NEVER",
			},
		}
	}
	function self.historybutton.popover.child.child.on_map()
		-- This isn't ideal, but there are no good options here.
		self.histview.width_request = math.max(300,
			math.floor(self.entry.width * 0.75))
		scrolled = self.historybutton.popover.child.child
		GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
			scrolled.vadjustment.value = scrolled.vadjustment.upper
		end)
	end
	self.sendbutton = Gtk.Button {
		extra_css_classes = { "suggested-action" },
		icon_name = "tp-run-symbolic",
		tooltip_text = _ "Run command",
		sensitive = false,
		on_clicked = function()
			self:doactivate()
		end,
	}
	self.entry = Gtk.Text {
		extra_css_classes = { "numeric" },
		placeholder_text = _ "Run a command…",
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
		icon_name = "tp-clear-symbolic",
		css_name = "image",
		can_focus = false,
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
		self.menubutton,
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
		bottom_bars = { self.searchbar, box },
	}
	runners[self.toolbarview] = self
end)

function runner:doactivate()
	-- Blank lines are allowed for running apps.
	if not self.subproc and #self.entry.text == 0 then return end
	local text = self.entry.text
	self.entry.text = ""
	self:send(text)
end

function runner:grab()
	self.entry:set_position(-1)
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
			local message = _ "working directory ⇒	%s\n"
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
	local bound, insert
	local first, second = self:gettextiters()
	-- If the buffer has a selection that extends to the end of the buffer, it needs to be preserved, so mark it.
	if self.buffer:get_has_selection() and second:is_end() then
		bound = self.buffer:create_mark(nil, first, true)
		insert = self.buffer:create_mark(nil, second, true)
	end
	local enditer = self.buffer:get_end_iter()
	self.buffer:insert(enditer, text, -1)
	-- If marks were made to preserve selection, then reselect now and delete those marks.
	if bound and insert then
		first = self.buffer:get_iter_at_mark(bound)
		second = self.buffer:get_iter_at_mark(insert)
		self:selecttext(first, second)
		self.buffer:delete_mark(bound)
		self.buffer:delete_mark(insert)
	end
end

function runner:flush()
	if #self.outputqueue < 1 then return end
	if not self.outputqueue:match "[^\n]" then return end
	local newlines = self.outputqueue:match "\n*$"
	local output = self.outputqueue:sub(1, -#newlines - 1)
	local bel = "\u{07}"
	if output:match(bel) then
		self.tabpage.needs_attention = true
	end
	output = output:gsub(bel, "")
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

function runner:ensurenewlines(n)
	self:flush()
	if not n then n = 2 end
	local pattern = ""
	for i = 1, n do pattern = pattern .. "\n" end
	while #self.buffer.text > 0 and self.buffer.text:sub(-n, -1) ~= pattern do
		self:putstring "\n"
	end
	self.outputqueue = self.outputqueue:match "[^\n].*" or ""
end

function runner:handlepipe(pipe, callback, copyafter)
	Gio.Async.start(function()
		repeat
			-- This is technically a broken implementation. Telepipe uses UTF-8 to encode text, so the last byte(s) of the returned array may be an incomplete code point. In practice, this doesn't matter as the next read happens nearly-instantly because this async context has maximum io_priority and so the broken code point is fixed in the next write.
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
		self:ensurenewlines(1)
		self:print(_ "copied output to clipboard.\n")
	else
		self:ensurenewlines(1)
		self:print(_ "nothing to copy; clipboard has not been modified.")
	end
	self.copyqueue = nil
end

function runner:waitend(async)
	if not self.subproc then return end
	Gio.Async.start(function()
		self.subproc:async_wait()
		local status = self.subproc:get_status()
		if status ~= 0 then
			self:ensurenewlines(1)
			self:print((_ "exited with status code %d\n"):format(status))
		end
		self.commandname = nil
		self.subproc = nil
		self.chdirbutton.visible = true
		self.historybutton.visible = self.history.n_items > 0
		self.menubutton.visible = false
		self.entry.sensitive = true
		self.entry.placeholder_text = _ "Run a command…"
		self.sendbutton.icon_name = "tp-run-symbolic"
		self.sendbutton.tooltip_text = _ "Run command"
		if #self.entry.text > 0 then self.sendbutton.sensitive = true end
		self:updatetitle()
		self.entry:grab_focus_without_selecting()
	end)() -- Call wrapped async context.
end

function runner:removehistory(command)
	repeat
		local index = self.history:find(command)
		if index >= self.history.n_items or index < 0 then break end
		self.history:remove(index)
	until false
	if self.history.n_items == 0 then
		self.historybutton.visible = false
		self.historybutton.popover:popdown()
	end
end

function runner:inserthistory(command)
	self:removehistory(command)
	self.history:append(command)
	if self.history.n_items > 0 then
		self.historybutton.visible = true
	end
end

function runner:setupitem(listitem)
	local label = Gtk.Label {
		extra_css_classes = { "numeric" },
		halign = "START",
		hexpand = true,
		margin_start = 6,
		margin_end = 24,
		selectable = true,
		wrap = true,
		wrap_mode = "WORD_CHAR",
	}

	-- It is normally a better idea to bind signal handlers in the ::bind signal, after an item is bound. However, LuaGObject kind of makes it a bit of a nightmare to unbind signals. Someone should fix that.
	local transferbutton = Gtk.Button {
		icon_name = "tp-transfer-symbolic",
		tooltip_text = _ "Copy command to command entry",
		valign = "CENTER",
		on_clicked = function()
			local command = listitem.item.string
			self.historybutton.popover:popdown()
			self.historybutton.active = false
			self.entry.text = command
			self:grab()
		end,
	}
	local deletebutton = Gtk.Button {
		icon_name = "tp-delete-symbolic",
		extra_css_classes = { "destructive-action" },
		tooltip_text = _ "Remove from history",
		valign = "CENTER",
		on_clicked = function()
			local command = listitem.item.string
			local index = self.history:find(command)
			self:removehistory(command)
			GLib.timeout_add(20, GLib.PRIORITY_DEFAULT, function()
				if index >= self.history.n_items then
					index = self.history.n_items - 1
				end
				if index >= 0 then
					self.histview:scroll_to(index)
				end
			end)
		end,
	}

	listitem.child = Gtk.Box {
		orientation = "HORIZONTAL",
		halign = "FILL",
		spacing = 12,
		margin_top = 6,
		margin_bottom = 6,
		margin_start = 6,
		margin_end = 6,
		label,
		Gtk.Box {
			orientation = "HORIZONTAL",
			spacing = 12,
			margin_start = 12,
			margin_end = 12,
			halign = "END",
			transferbutton,
			deletebutton,
		},
	}
end

function runner:binditem(listitem)
	-- Because the label is the box's first child, it's easy to find.
	listitem.child.children[1].label = listitem.item.string
end

function runner:unbinditem(listitem)
	-- Same as in :binditem().
	listitem.child.children[1].label = ""
end

function runner:teardownitem(listitem)
	-- Everything just gets GC'd at this point, so no need to do anything.
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
		self.historybutton.visible = self.history.n_items > 0
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
		self.entry.placeholder_text = _ "Send to running command…"
		self.sendbutton.tooltip_text = _ "Send to running command"
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
	self.menubutton.visible = true
	self.sendbutton.icon_name = "tp-send-symbolic"
	self.sendbutton.tooltip_text = _ "Send to running command"
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

function runner:getbound()
	return self.buffer:get_selection_bound()
end

function runner:getinsert()
	return self.buffer:get_insert()
end

function runner:gettextiters()
	local first = self.buffer:get_iter_at_mark(self:getbound())
	local second = self.buffer:get_iter_at_mark(self:getinsert())
	first:order(second)
	return first, second
end

function runner:selecttext(first, second)
	assert(first, second)
	first:order(second)
	-- Gtk.TextBuffer expects the bound, followed by the insert.
	self.buffer:select_range(second, first)
end

function runner:scrollselection()
	local buf, tv = self.buffer, self.textview
	self.textview:scroll_to_mark(self:getbound(), 0.4999, false, 0.0, 0.0)
	self.textview:scroll_to_mark(self:getinsert(), 0.2, false, 0.0, 0.0)
end

function runner:selectrange(bound, insert)
	assert(type(bound) == "number")
	assert(type(insert) == "number")
	local first = self.buffer:get_start_iter()
	first:forward_chars(bound - 1)
	local second = self.buffer:get_start_iter()
	second:forward_chars(insert - 1)
	self:selecttext(first, second)
end

-- Search functions.

function runner:beginsearch()
	if self.searchbar.search_mode_enabled then
		self.searchentry:grab_focus_without_selecting()
		return
	end
	-- Replace the search entry if the current selection doesn't match
	if self.buffer:get_has_selection() then
		self.searchentry.text = self.buffer:get_slice(self:gettextiters())
	else
		self.searchentry.text = ""
	end
	self.searchbar.search_mode_enabled = true
	if #self.searchentry.text > 0 then
		self:findall(self.searchentry.text)
	else
		self.matchlabel.label = ""
	end
	self.searchentry:grab_focus_without_selecting()
end

function runner:setmatches(total, current)
	if type(current) == "number" and type(total) == "number" then
		self.matchlabel.label = (_ "%d of %d"):format(current, total)
	elseif total == 0 then
		self.matchlabel.label = _ "no matches"
	elseif type(total) == "number" then
		self.matchlabel.label = ("%d"):format(total)
	elseif type(total) == "string" then
		self.matchlabel.label = total
	else
		self.matchlabel.label = ""
	end
end

function runner:findall(pattern)
	if #pattern == 0 then return end
	local byteindices = {}
	local text = self.buffer.text
	local len = #text
	local init = 1
	while init <= len do
		local i, j = text:find(pattern, init, true)
		if not i or not j then break end
		table.insert(byteindices, { i, j })
		init = j + 1
	end
	-- clear the table without reassigning
	while #self.matches > 0 do table.remove(self.matches) end
	local utftotal = 0
	init = 1
	for _, t in ipairs(byteindices) do
		local i = t[1]
		local j = t[2]
		local ulen1 = utf8.len(text, init, i, true)
		local ulen2 = utf8.len(text, i, j, true)
		assert(ulen1 and ulen2)
		ulen1 = utftotal + ulen1
		utftotal = ulen1
		ulen2 = utftotal + ulen2
		utftotal = ulen2 - 1
		table.insert(self.matches, { ulen1, ulen2 })
		init = j + 1
	end
	self:setmatches(#self.matches)
end

function runner:searchprev(...)
	self:findall(...)
	if #self.matches == 0 then return end
	local first, _ = self:gettextiters()
	local cursorpos = first:get_offset() + 1
	for i = 1, #self.matches do
		local idx = #self.matches - i + 1
		local m = self.matches[idx]
		if cursorpos >= m[2] then
			self:selectrange(m[1], m[2])
			self:scrollselection()
			self:setmatches(#self.matches, idx)
			return
		end
	end
	-- Wrap to end.
	local m = self.matches[#self.matches]
	self:selectrange(m[1], m[2])
	self:scrollselection()
	self:setmatches(#self.matches, #self.matches)
end

function runner:searchnext(...)
	self:findall(...)
	if #self.matches == 0 then return end
	local _, first = self:gettextiters()
	local cursorpos = first:get_offset()
	for i, m in ipairs(self.matches) do
		if m[1] > cursorpos then
			self:selectrange(m[1], m[2])
			self:scrollselection()
			self:setmatches(#self.matches, i)
			return
		end
	end
	-- Wrap to start.
	self:selectrange(self.matches[1][1], self.matches[1][2])
	self:scrollselection()
	self:setmatches(#self.matches, 1)
end

-- Built-in runner functions. If a command matches any of these names, it'll instead call a built-in.
runner.builtin = {}

function runner.builtin:cd(dir)
	if not dir or #dir == 0 then dir = os.getenv "HOME" end
	dir = lib.expanddir(dir)
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
	self:print(_ [[
Telepipe is a command-line shell. Run command-line applications as you would normally.

Add a > at the start of a command to paste your clipboard's contents into the command's input. Add a < at the start of a command to copy its output to the clipboard. Add a | at the start of a command to do both, pasting the clipboard as input and copying the output back to the clipboard.

Telepipe's built-in commands are
• cd [directory]
	Changes the current working directory to the given path.
• exit
	Closes the current tab. If no tabs remain, closes the current window.
• help
	Print this help text.

THIS SOFTWARE IS EXPERIMENTAL. Expected features may not exist or may be subject to change. Many command-line programs will behave unusually, though in some cases this may be remedied using certain parameters or flags. Programs requiring the terminal will not function at all, and may output odd-looking text—avoid using these applications in Telepipe.

Visit Telepipe's code repository at https://github.com/vtrlx/telepipe/ for more information or to submit an issue.
]])
end

-- SECTION: Application menus

local appmenu = Gio.Menu()
appmenu:append(_ "New Window", "win.new-win")
appmenu:append(_ "Search Command Output", "win.search")
appmenu:append(_ "Open Working Directory", "win.open-folder")
appmenu:append(_ "Keyboard Shortcuts", "win.shortcuts")
appmenu:append(_ "About " .. app_title, "win.about")

local function shortcuts(parent)
	local cut = Adw.ShortcutsItem.new_from_action
	local shortdlg = Adw.ShortcutsDialog {
		Adw.ShortcutsSection {
			title = "Window",
			cut(_ "New Tab", "win.new-tab"),
			cut(_ "New Window", "win.new-win"),
			cut(_ "Show Keyboard Shortcuts", "win.shortcuts"),
		},
		Adw.ShortcutsSection {
			title = "Runner tab",
			cut(_ "Search Command Output", "win.search"),
			cut(_ "Show Working Directory in Files", "win.open-folder"),
			cut(_ "Stop Current Command", "win.signal-kill"),
			cut(_ "Close Command Input", "win.signal-endinput"),
			cut(_ "Focus Command Entry", "win.focus-cmdbar"),
			cut(_ "Close Current Tab", "win.close-tab"),
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

	aboutdlg:add_link(_ "Contact the Developer", "mailto:victoria@vtrlx.ca?subject=Telepipe")

	aboutdlg:present(parent)
end

-- SECTION: Application window

local window
window = lib.newclass(function(self)
	self.windowtitle = Adw.WindowTitle.new(app_title, "")

	local newbutton = Gtk.Button {
		icon_name = "tp-newtab-symbolic",
		tooltip_text = _ "New Tab",
		on_clicked = function()
			self:newtab()
		end,
	}

	local menupopover = Gtk.PopoverMenu.new_from_model(appmenu)
	menupopover.halign = "END"
	local menubutton = Gtk.MenuButton {
		direction = "DOWN",
		icon_name = "tp-menu-symbolic",
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
		self.search.enabled = true
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
			local body = _ "This tab cannot be closed because the command %q is running. Close anyway?"
			local name = r.commandname
			if #name > 20 then
				commandname = utf8.char(utf8.codepoint(name, 1, 20))
			end
			body = body:format(name)
			local dlg = Adw.AlertDialog.new(_ "Stop Current Command?", body)
			dlg:add_response("close", _ "Keep Running")
			dlg:set_response_appearance("close", "DEFAULT")
			dlg:add_response("discard", _ "Stop and Close Tab")
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
				self.search.enabled = false
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
		width_request = 360,
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
			local dlg = Adw.AlertDialog.new(_ "Stop Running Commands?", _ "There are commands running in this window. Close anway?")
			dlg:add_response("cancel", _ "Keep Open")
			dlg:set_response_appearance("cancel", "DEFAULT")
			dlg:add_response("discard", _ "Stop All and Close")
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

	lib.addnewaction(self.win, "signal-kill", function()
		local r = get_focused_runner()
		if not r then return end
		r:kill()
	end)

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

	self.search = lib.addnewaction(self.win, "search", function()
		local r = get_focused_runner()
		if not r then return end
		r:beginsearch()
	end)
	self.search.enabled = false

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
	r:print(_ [[
Welcome to Telepipe. Type "help" in the command entry below (without quotation marks) then press the Enter key for more information on using this program.
]])
end

return app:run { lib.get_cli_args() }
