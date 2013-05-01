
local stanza_mt = require "util.stanza".stanza_mt;
local setmetatable = setmetatable;
local pairs = pairs;
local ipairs = ipairs;
local error = error;
local loadstring = loadstring;
local debug = debug;
local t_remove = table.remove;
local parse_xml = require "util.xml".parse;

module("template")

local function trim_xml(stanza)
	for i=#stanza,1,-1 do
		local child = stanza[i];
		if child.name then
			trim_xml(child);
		else
			child = child:gsub("^%s*", ""):gsub("%s*$", "");
			stanza[i] = child;
			if child == "" then t_remove(stanza, i); end
		end
	end
end

local function create_string_string(str)
	str = ("%q"):format(str);
	str = str:gsub("{([^}]*)}", function(s)
		return '"..(data["'..s..'"]or"").."';
	end);
	return str;
end
local function create_attr_string(attr, xmlns)
	local str = '{';
	for name,value in pairs(attr) do
		if name ~= "xmlns" or value ~= xmlns then
			str = str..("[%q]=%s;"):format(name, create_string_string(value));
		end
	end
	return str..'}';
end
local function create_clone_string(stanza, lookup, xmlns)
	if not lookup[stanza] then
		local s = ('setmetatable({name=%q,attr=%s,tags={'):format(stanza.name, create_attr_string(stanza.attr, xmlns));
		-- add tags
		for i,tag in ipairs(stanza.tags) do
			s = s..create_clone_string(tag, lookup, stanza.attr.xmlns)..";";
		end
		s = s..'};';
		-- add children
		for i,child in ipairs(stanza) do
			if child.name then
				s = s..create_clone_string(child, lookup, stanza.attr.xmlns)..";";
			else
				s = s..create_string_string(child)..";"
			end
		end
		s = s..'}, stanza_mt)';
		s = s:gsub('%.%.""', ""):gsub('([=;])""%.%.', "%1"):gsub(';"";', ";"); -- strip empty strings
		local n = #lookup + 1;
		lookup[n] = s;
		lookup[stanza] = "_"..n;
	end
	return lookup[stanza];
end
local function create_cloner(stanza, chunkname)
	local lookup = {};
	local name = create_clone_string(stanza, lookup, "");
	local f = "local setmetatable,stanza_mt=...;return function(data)";
	for i=1,#lookup do
		f = f.."local _"..i.."="..lookup[i]..";";
	end
	f = f.."return "..name..";end";
	local f,err = loadstring(f, chunkname);
	if not f then error(err); end
	return f(setmetatable, stanza_mt);
end

local template_mt = { __tostring = function(t) return t.name end };
local function create_template(templates, text)
	local stanza, err = parse_xml(text);
	if not stanza then error(err); end
	trim_xml(stanza);

	local info = debug.getinfo(3, "Sl");
	info = info and ("template(%s:%d)"):format(info.short_src:match("[^\\/]*$"), info.currentline) or "template(unknown)";

	local template = setmetatable({ apply = create_cloner(stanza, info), name = info, text = text }, template_mt);
	templates[text] = template;
	return template;
end

local templates = setmetatable({}, { __mode = 'k', __index = create_template });
return function(text)
	return templates[text];
end;
