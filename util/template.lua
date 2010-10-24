
local t_insert = table.insert;
local st = require "util.stanza";
local lxp = require "lxp";
local setmetatable = setmetatable;
local pairs = pairs;
local error = error;
local s_gsub = string.gsub;

local print = print;

module("template")

local function process_stanza(stanza, ops)
	-- process attrs
	for key, val in pairs(stanza.attr) do
		if val:match("{[^}]*}") then
			t_insert(ops, {stanza.attr, key, val});
		end
	end
	-- process children
	local i = 1;
	while i <= #stanza do
		local child = stanza[i];
		if child.name then
			process_stanza(child, ops);
		elseif child:match("^{[^}]*}$") then -- text
			t_insert(ops, {stanza, i, child:match("^{([^}]*)}$"), true});
		elseif child:match("{[^}]*}") then -- text
			t_insert(ops, {stanza, i, child});
		end
		i = i + 1;
	end
end

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

local stanza_mt = st.stanza_mt;
local function fast_st_clone(stanza, lookup)
	local stanza_attr = stanza.attr;
	local stanza_tags = stanza.tags;
	local tags, attr = {}, {};
	local clone = { name = stanza.name, attr = attr, tags = tags, last_add = {} };
	for k,v in pairs(stanza_attr) do attr[k] = v; end
	lookup[stanza_attr] = attr;
	for i=1,#stanza_tags do
		local child = stanza_tags[i];
		local new = fast_st_clone(child, lookup);
		tags[i] = new;
		lookup[child] = new;
	end
	for i=1,#stanza do
		local child = stanza[i];
		clone[i] = lookup[child] or child;
	end
	return setmetatable(clone, stanza_mt);
end

local function create_template(text)
	local stanza, err = parse_xml(text);
	if not stanza then error(err); end
	local ops = {};
	process_stanza(stanza, ops);
	
	local template = {};
	local lookup = {};
	function template.apply(data)
		local newstanza = fast_st_clone(stanza, lookup);
		for i=1,#ops do
			local op = ops[i];
			local t, k, v, g = op[1], op[2], op[3], op[4];
			if g then
				lookup[t][k] = data[v];
			else
				lookup[t][k] = s_gsub(v, "{([^}]*)}", data);
			end
		end
		return newstanza;
	end
	return template;
end

local templates = setmetatable({}, { __mode = 'k' });
return function(text)
	local template = templates[text];
	if not template then
		template = create_template(text);
		templates[text] = template;
	end
	return template;
end;
