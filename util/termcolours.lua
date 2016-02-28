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
local m_floor = math.floor;
local type = type;
local setmetatable = setmetatable;
local pairs = pairs;

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

local function gray(n)
	return m_floor(n*3/32)+0xe8;
end
local function color(r,g,b)
	if r == g and g == b then
		return gray(r);
	end
	r = m_floor(r*3/128);
	g = m_floor(g*3/128);
	b = m_floor(b*3/128);
	return 0x10 + ( r * 36 ) + ( g * 6 ) + ( b );
end
local function hex2rgb(hex)
	local r = tonumber(hex:sub(1,2),16);
	local g = tonumber(hex:sub(3,4),16);
	local b = tonumber(hex:sub(5,6),16);
	return r,g,b;
end

setmetatable(stylemap, { __index = function(_, style)
	if type(style) == "string" and style:find("%x%x%x%x%x%x") == 1 then
		local g = style:sub(7) == " background" and "48;5;" or "38;5;";
		return g .. color(hex2rgb(style));
	end
end } );

local csscolors = {
	red = "ff0000"; fuchsia = "ff00ff"; green = "008000"; white = "ffffff";
	lime = "00ff00"; yellow = "ffff00"; purple = "800080"; blue = "0000ff";
	aqua = "00ffff"; olive  = "808000"; black  = "000000"; navy = "000080";
	teal = "008080"; silver = "c0c0c0"; maroon = "800000"; gray = "808080";
}
for color, rgb in pairs(csscolors) do
	stylemap[color] = stylemap[color] or stylemap[rgb];
	color, rgb = color .. " background", rgb .. " background"
	stylemap[color] = stylemap[color] or stylemap[rgb];
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
