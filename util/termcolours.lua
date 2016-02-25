-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
--
-- luacheck: ignore 213/i


local t_concat, t_insert = table.concat, table.insert;
local char, format = string.char, string.format;
local tonumber = tonumber;
local ipairs = ipairs;
local io_write = io.write;

local windows;
if os.getenv("WINDIR") then
	windows = require "util.windows";
end
local orig_color = windows and windows.get_consolecolor and windows.get_consolecolor();

local _ENV = nil;

local stylemap = {
			reset = 0; bright = 1, dim = 2, underscore = 4, blink = 5, reverse = 7, hidden = 8;
			black = 30; red = 31; green = 32; yellow = 33; blue = 34; magenta = 35; cyan = 36; white = 37;
			["black background"] = 40; ["red background"] = 41; ["green background"] = 42; ["yellow background"] = 43; ["blue background"] = 44; ["magenta background"] = 45; ["cyan background"] = 46; ["white background"] = 47;
			bold = 1, dark = 2, underline = 4, underlined = 4, normal = 0;
		}

local winstylemap = {
	["0"] = orig_color, -- reset
	["1"] = 7+8, -- bold
	["1;33"] = 2+4+8, -- bold yellow
	["1;31"] = 4+8 -- bold red
}

local cssmap = {
	[1] = "font-weight: bold", [2] = "opacity: 0.5", [4] = "text-decoration: underline", [8] = "visibility: hidden",
	[30] = "color:black", [31] = "color:red", [32]="color:green", [33]="color:#FFD700",
	[34] = "color:blue", [35] = "color: magenta", [36] = "color:cyan", [37] = "color: white",
	[40] = "background-color:black", [41] = "background-color:red", [42]="background-color:green",
	[43]="background-color:yellow",	[44] = "background-color:blue", [45] = "background-color: magenta",
	[46] = "background-color:cyan", [47] = "background-color: white";
};

local fmt_string = char(0x1B).."[%sm%s"..char(0x1B).."[0m";
local function getstring(style, text)
	if style then
		return format(fmt_string, style, text);
	else
		return text;
	end
end

local function getstyle(...)
	local styles, result = { ... }, {};
	for i, style in ipairs(styles) do
		style = stylemap[style];
		if style then
			t_insert(result, style);
		end
	end
	return t_concat(result, ";");
end

local last = "0";
local function setstyle(style)
	style = style or "0";
	if style ~= last then
		io_write("\27["..style.."m");
		last = style;
	end
end

if windows then
	function setstyle(style)
		style = style or "0";
		if style ~= last then
			windows.set_consolecolor(winstylemap[style] or orig_color);
			last = style;
		end
	end
	if not orig_color then
		function setstyle() end
	end
end

local function ansi2css(ansi_codes)
	if ansi_codes == "0" then return "</span>"; end
	local css = {};
	for code in ansi_codes:gmatch("[^;]+") do
		t_insert(css, cssmap[tonumber(code)]);
	end
	return "</span><span style='"..t_concat(css, ";").."'>";
end

local function tohtml(input)
	return input:gsub("\027%[(.-)m", ansi2css);
end

return {
	getstring = getstring;
	getstyle = getstyle;
	setstyle = setstyle;
	tohtml = tohtml;
};
