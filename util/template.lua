
local st = require "util.stanza";
local lxp = require "lxp";
local setmetatable = setmetatable;
local pairs = pairs;
local ipairs = ipairs;
local error = error;
local loadstring = loadstring;
local debug = debug;

module("template")

local parse_xml = (function()
	local ns_prefixes = {
		["http://www.w3.org/XML/1998/namespace"] = "xml";
	};
	local ns_separator = "\1";
	local ns_pattern = "^([^"..ns_separator.."]*)"..ns_separator.."?(.*)$";
	return function(xml)
		local handler = {};
		local stanza = st.stanza("root");
		function handler:StartElement(tagname, attr)
			local curr_ns,name = tagname:match(ns_pattern);
			if name == "" then
				curr_ns, name = "", curr_ns;
			end
			if curr_ns ~= "" then
				attr.xmlns = curr_ns;
			end
			for i=1,#attr do
				local k = attr[i];
				attr[i] = nil;
				local ns, nm = k:match(ns_pattern);
				if nm ~= "" then
					ns = ns_prefixes[ns]; 
					if ns then 
						attr[ns..":"..nm] = attr[k];
						attr[k] = nil;
					end
				end
			end
			stanza:tag(name, attr);
		end
		function handler:CharacterData(data)
			data = data:gsub("^%s*", ""):gsub("%s*$", "");
			stanza:text(data);
		end
		function handler:EndElement(tagname)
			stanza:up();
		end
		local parser = lxp.new(handler, "\1");
		local ok, err, line, col = parser:parse(xml);
		if ok then ok, err, line, col = parser:parse(); end
		--parser:close();
		if ok then
			return stanza.tags[1];
		else
			return ok, err.." (line "..line..", col "..col..")";
		end
	end;
end)();

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
local stanza_mt = st.stanza_mt;
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
