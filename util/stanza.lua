-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local error         =         error;
local t_insert      =  table.insert;
local t_remove      =  table.remove;
local t_concat      =  table.concat;
local s_match       =  string.match;
local tostring      =      tostring;
local setmetatable  =  setmetatable;
local getmetatable  =  getmetatable;
local pairs         =         pairs;
local ipairs        =        ipairs;
local type          =          type;
local s_gsub        =   string.gsub;
local s_sub         =    string.sub;
local s_find        =   string.find;
local t_move        =    table.move or require "prosody.util.table".move;
local t_create = require"prosody.util.table".create;

local valid_utf8 = require "prosody.util.encodings".utf8.valid;

local do_pretty_printing, termcolours = pcall(require, "prosody.util.termcolours");

local xmlns_stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas";
local xmpp_stanzas_attr = { xmlns = xmlns_stanzas };

local _ENV = nil;
-- luacheck: std none

local stanza_mt = { __name = "stanza" };
stanza_mt.__index = stanza_mt;

-- Basic check for valid XML character data.
-- Disallow control characters.
-- Tab U+09 and newline U+0A are allowed.
-- For attributes, allow the \1 separator between namespace and name.
local function valid_xml_cdata(str, attr)
	return not s_find(str, attr and "[^\1\9\10\13\20-\255]" or "[^\9\10\13\20-\255]");
end

local function check_name(name, name_type)
	if type(name) ~= "string" then
		error("invalid "..name_type.." name: expected string, got "..type(name));
	elseif #name == 0 then
		error("invalid "..name_type.." name: empty string");
	elseif s_find(name, "[<>& '\"]") then
		error("invalid "..name_type.." name: contains invalid characters");
	elseif not valid_xml_cdata(name, name_type == "attribute") then
		error("invalid "..name_type.." name: contains control characters");
	elseif not valid_utf8(name) then
		error("invalid "..name_type.." name: contains invalid utf8");
	end
end

local function check_text(text, text_type)
	if type(text) ~= "string" then
		error("invalid "..text_type.." value: expected string, got "..type(text));
	elseif not valid_xml_cdata(text, false) then
		error("invalid "..text_type.." value: contains control characters");
	elseif not valid_utf8(text) then
		error("invalid "..text_type.." value: contains invalid utf8");
	end
end

local function check_attr(attr)
	if attr ~= nil then
		if type(attr) ~= "table" then
			error("invalid attributes: expected table, got "..type(attr));
		end
		for k, v in pairs(attr) do
			check_name(k, "attribute");
			check_text(v, "attribute");
		end
	end
end

local function new_stanza(name, attr, namespaces)
	check_name(name, "tag");
	check_attr(attr);
	local stanza = { name = name, attr = attr or {}, namespaces = namespaces, tags = {} };
	return setmetatable(stanza, stanza_mt);
end

local function is_stanza(s)
	return getmetatable(s) == stanza_mt;
end

function stanza_mt:query(xmlns)
	return self:tag("query", { xmlns = xmlns });
end

function stanza_mt:body(text, attr)
	return self:text_tag("body", text, attr);
end

function stanza_mt:text_tag(name, text, attr, namespaces)
	return self:tag(name, attr, namespaces):text(text):up();
end

function stanza_mt:tag(name, attr, namespaces)
	local s = new_stanza(name, attr, namespaces);
	local last_add = self.last_add;
	if not last_add then last_add = {}; self.last_add = last_add; end
	(last_add[#last_add] or self):add_direct_child(s);
	t_insert(last_add, s);
	return self;
end

function stanza_mt:text(text)
	if text ~= nil and text ~= "" then
		local last_add = self.last_add;
		(last_add and last_add[#last_add] or self):add_direct_child(text);
	end
	return self;
end

function stanza_mt:up()
	local last_add = self.last_add;
	if last_add then t_remove(last_add); end
	return self;
end

function stanza_mt:at_top()
	return self.last_add == nil or #self.last_add == 0
end

function stanza_mt:reset()
	self.last_add = nil;
	return self;
end

function stanza_mt:add_direct_child(child)
	if is_stanza(child) then
		t_insert(self.tags, child);
		t_insert(self, child);
	else
		check_text(child, "text");
		t_insert(self, child);
	end
end

function stanza_mt:add_child(child)
	local last_add = self.last_add;
	(last_add and last_add[#last_add] or self):add_direct_child(child);
	return self;
end

function stanza_mt:remove_children(name, xmlns)
	xmlns = xmlns or self.attr.xmlns;
	return self:maptags(function (tag)
		if (not name or tag.name == name) and tag.attr.xmlns == xmlns then
			return nil;
		end
		return tag;
	end);
end

function stanza_mt:get_child(name, xmlns)
	for _, child in ipairs(self.tags) do
		if (not name or child.name == name)
			and ((not xmlns and self.attr.xmlns == child.attr.xmlns)
				or child.attr.xmlns == xmlns) then

			return child;
		end
	end
	return nil;
end

function stanza_mt:get_child_text(name, xmlns)
	local tag = self:get_child(name, xmlns);
	if tag then
		return tag:get_text();
	end
	return nil;
end

function stanza_mt:get_child_attr(name, xmlns, attr)
	local tag = self:get_child(name, xmlns);
	if tag then
		return tag.attr[attr];
	end
	return nil;
end

function stanza_mt:child_with_name(name)
	for _, child in ipairs(self.tags) do
		if child.name == name then return child; end
	end
	return nil;
end

function stanza_mt:child_with_ns(ns)
	for _, child in ipairs(self.tags) do
		if child.attr.xmlns == ns then return child; end
	end
	return nil;
end

function stanza_mt:get_child_with_attr(name, xmlns, attr_name, attr_value, normalize)
	for tag in self:childtags(name, xmlns) do
		if (normalize and normalize(tag.attr[attr_name]) or tag.attr[attr_name]) == attr_value then
			return tag;
		end
	end
	return nil;
end

function stanza_mt:children()
	local i = 0;
	return function (a)
			i = i + 1
			return a[i];
		end, self, i;
end

function stanza_mt:childtags(name, xmlns)
	local tags = self.tags;
	local start_i, max_i = 1, #tags;
	return function ()
		for i = start_i, max_i do
			local v = tags[i];
			if (not name or v.name == name)
			and ((not xmlns and self.attr.xmlns == v.attr.xmlns)
				or v.attr.xmlns == xmlns) then
				start_i = i+1;
				return v;
			end
		end
	end;
end

function stanza_mt:maptags(callback)
	local tags, curr_tag = self.tags, 1;
	local n_children, n_tags = #self, #tags;
	local max_iterations = n_children + 1;

	local i = 1;
	while curr_tag <= n_tags and n_tags > 0 do
		if self[i] == tags[curr_tag] then
			local ret = callback(self[i]);
			if ret == nil then
				t_remove(self, i);
				t_remove(tags, curr_tag);
				n_children = n_children - 1;
				n_tags = n_tags - 1;
				i = i - 1;
				curr_tag = curr_tag - 1;
			else
				self[i] = ret;
				tags[curr_tag] = ret;
			end
			curr_tag = curr_tag + 1;
		end
		i = i + 1;
		if i > max_iterations then
			-- COMPAT: Hopefully temporary guard against #981 while we
			-- figure out the root cause
			error("Invalid stanza state! Please report this error.");
		end
	end
	return self;
end

function stanza_mt:find(path)
	local pos = 1;
	local len = #path + 1;

	repeat
		local xmlns, name, text;
		local char = s_sub(path, pos, pos);
		if char == "@" then
			if s_sub(path, pos + 1, pos + 1) == "{" then
				return self.attr[s_gsub(s_sub(path, pos+2), "}", "\1", 1)];
			end
			local prefix, attr = s_match(path, "^([^:]+):(.*)", pos+1);
			if prefix and self.namespaces and self.namespaces[prefix] then
				return self.attr[self.namespaces[prefix] .. "\1" .. attr];
			end
			return self.attr[s_sub(path, pos + 1)];
		elseif char == "{" then
			xmlns, pos = s_match(path, "^([^}]+)}()", pos + 1);
		end
		name, text, pos = s_match(path, "^([^@/#]*)([/#]?)()", pos);
		name = name ~= "" and name or nil;
		if pos == len then
			if text == "#" then
				return self:get_child_text(name, xmlns);
			end
			return self:get_child(name, xmlns);
		end
		self = self:get_child(name, xmlns);
	until not self
end

local function _clone(stanza, only_top)
	local attr = {};
	for k,v in pairs(stanza.attr) do attr[k] = v; end
	local old_namespaces, namespaces = stanza.namespaces;
	if old_namespaces then
		namespaces = {};
		for k,v in pairs(old_namespaces) do namespaces[k] = v; end
	end
	local tags, new;
	if only_top then
		tags = {};
		new = { name = stanza.name, attr = attr, namespaces = namespaces, tags = tags };
	else
		tags = t_create(#stanza.tags, 0);
		new = t_create(#stanza, 4);
		new.name = stanza.name;
		new.attr = attr;
		new.namespaces = namespaces;
		new.tags = tags;
	end

	setmetatable(new, stanza_mt);
	if not only_top then
		t_move(stanza, 1, #stanza, 1, new);
		t_move(stanza.tags, 1, #stanza.tags, 1, tags);
		new:maptags(_clone);
	end
	return new;
end

local function clone(stanza, only_top)
	if not is_stanza(stanza) then
		error("bad argument to clone: expected stanza, got "..type(stanza));
	end
	return _clone(stanza, only_top);
end

local escape_table = { ["'"] = "&apos;", ["\""] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" };
local function xml_escape(str) return (s_gsub(str, "['&<>\"]", escape_table)); end

local function _dostring(t, buf, self, _xml_escape, parentns)
	local nsid = 0;
	local name = t.name
	t_insert(buf, "<"..name);
	for k, v in pairs(t.attr) do
		if s_find(k, "\1", 1, true) then
			local ns, attrk = s_match(k, "^([^\1]*)\1?(.*)$");
			nsid = nsid + 1;
			t_insert(buf, " xmlns:ns"..nsid.."='".._xml_escape(ns).."' ".."ns"..nsid..":"..attrk.."='".._xml_escape(v).."'");
		elseif not(k == "xmlns" and v == parentns) then
			t_insert(buf, " "..k.."='".._xml_escape(v).."'");
		end
	end
	local len = #t;
	if len == 0 then
		t_insert(buf, "/>");
	else
		t_insert(buf, ">");
		for n=1,len do
			local child = t[n];
			if child.name then
				self(child, buf, self, _xml_escape, t.attr.xmlns);
			else
				t_insert(buf, _xml_escape(child));
			end
		end
		t_insert(buf, "</"..name..">");
	end
end
function stanza_mt.__tostring(t)
	local buf = {};
	_dostring(t, buf, _dostring, xml_escape, nil);
	return t_concat(buf);
end

function stanza_mt.top_tag(t)
	local top_tag_clone = clone(t, true);
	return tostring(top_tag_clone):sub(1,-3)..">";
end

function stanza_mt.get_text(t)
	if #t.tags == 0 then
		return t_concat(t);
	end
	return nil;
end

function stanza_mt.get_error(stanza)
	local error_type, condition, text, extra_tag;

	local error_tag = stanza:get_child("error");
	if not error_tag then
		return nil, nil, nil, nil;
	end
	error_type = error_tag.attr.type;

	for _, child in ipairs(error_tag.tags) do
		if child.attr.xmlns == xmlns_stanzas then
			if not text and child.name == "text" then
				text = child:get_text();
			elseif not condition then
				condition = child.name;
			end
		else
			extra_tag = child;
		end
		if condition and text and extra_tag then
			break;
		end
	end
	return error_type, condition or "undefined-condition", text, extra_tag;
end

function stanza_mt.add_error(stanza, error_type, condition, error_message, error_by)
	local extra;
	if type(error_type) == "table" then -- an util.error or similar object
		if type(error_type.extra) == "table" then
			extra = error_type.extra;
		end
		if type(error_type.context) == "table" and type(error_type.context.by) == "string" then error_by = error_type.context.by; end
		error_type, condition, error_message = error_type.type, error_type.condition, error_type.text;
	end
	if stanza.attr.from == error_by then
		error_by = nil;
	end
	stanza:tag("error", {type = error_type, by = error_by}) --COMPAT: Some day xmlns:stanzas goes here
	:tag(condition, xmpp_stanzas_attr);
	if extra and condition == "gone" and type(extra.uri) == "string" then
		stanza:text(extra.uri);
	end
	stanza:up();
	if error_message then stanza:text_tag("text", error_message, xmpp_stanzas_attr); end
	if extra and is_stanza(extra.tag) then
		stanza:add_child(extra.tag);
	elseif extra and extra.namespace and extra.condition then
		stanza:tag(extra.condition, { xmlns = extra.namespace }):up();
	end
	return stanza:up();
end

local function preserialize(stanza)
	local s = { name = stanza.name, attr = stanza.attr };
	for _, child in ipairs(stanza) do
		if type(child) == "table" then
			t_insert(s, preserialize(child));
		else
			t_insert(s, child);
		end
	end
	return s;
end

stanza_mt.__freeze = preserialize;

local function deserialize(serialized)
	-- Set metatable
	if serialized then
		local attr = serialized.attr;
		local attrx = {};
		for att, val in pairs(attr) do
			if type(att) == "string" then
				if s_find(att, "|", 1, true) and not s_find(att, "\1", 1, true) then
					local ns,na = s_match(att, "^([^|]+)|(.+)$");
					attrx[ns.."\1"..na] = val;
				else
					attrx[att] = val;
				end
			end
		end
		local stanza = new_stanza(serialized.name, attrx);
		for _, child in ipairs(serialized) do
			if type(child) == "table" then
				stanza:add_direct_child(deserialize(child));
			elseif type(child) == "string" then
				stanza:add_direct_child(child);
			end
		end
		return stanza;
	end
end

local function message(attr, body)
	if not body then
		return new_stanza("message", attr);
	else
		return new_stanza("message", attr):text_tag("body", body);
	end
end
local function iq(attr)
	if not attr then
		error("iq stanzas require id and type attributes");
	end
	if not attr.id then
		error("iq stanzas require an id attribute");
	end
	if not attr.type then
		error("iq stanzas require a type attribute");
	end
	return new_stanza("iq", attr);
end

local function reply(orig)
	if not is_stanza(orig) then
		error("bad argument to reply: expected stanza, got "..type(orig));
	end
	return new_stanza(orig.name,
		{
			to = orig.attr.from,
			from = orig.attr.to,
			id = orig.attr.id,
			type = ((orig.name == "iq" and "result") or orig.attr.type)
		});
end

local function error_reply(orig, error_type, condition, error_message, error_by)
	if not is_stanza(orig) then
		error("bad argument to error_reply: expected stanza, got "..type(orig));
	elseif orig.attr.type == "error" then
		error("bad argument to error_reply: got stanza of type error which must not be replied to");
	end
	local t = reply(orig);
	t.attr.type = "error";
	t:add_error(error_type, condition, error_message, error_by);
	t.last_add = { t[1] }; -- ready to add application-specific errors
	return t;
end

local function presence(attr)
	return new_stanza("presence", attr);
end

local pretty;
if do_pretty_printing then
	local getstyle, getstring = termcolours.getstyle, termcolours.getstring;

	local blue1 = getstyle("1b3967");
	local blue2 = getstyle("13b5ea");
	local green1 = getstyle("439639");
	local green2 = getstyle("a0ce67");
	local orange1 = getstyle("d9541e");
	local orange2 = getstyle("e96d1f");

	local attr_replace = (
		getstring(green2, "%1") .. -- attr name
		getstring(green1, "%2") .. -- equal
		getstring(orange1, "%3") .. -- quote
		getstring(orange2, "%4") .. -- attr value
		getstring(orange1, "%5") -- quote
	);

	local text_replace = (
		getstring(green1, "%1") .. -- &
		getstring(green2, "%2") .. -- amp
		getstring(green1, "%3") -- ;
	);

	function pretty(s)
		-- Tag soup color
		-- Outer gsub call takes each <tag>, applies colour to the brackets, the
		-- tag name, then applies one inner gsub call to colour the attributes and
		-- another for any text content.
		return (s:gsub("(<[?/]?)([^ >/?]*)(.-)([?/]?>)([^<]*)", function(opening_bracket, tag_name, attrs, closing_bracket, content)
			return getstring(blue1, opening_bracket)..getstring(blue2, tag_name)..
				attrs:gsub("([^=]+)(=)([\"'])(.-)([\"'])", attr_replace) ..
			getstring(blue1, closing_bracket) ..
			content:gsub("(&#?)(%w+)(;)", text_replace);
		end, 100));
	end

	function stanza_mt.pretty_print(t)
		return pretty(tostring(t));
	end

	function stanza_mt.pretty_top_tag(t)
		return pretty(t:top_tag());
	end
else
	-- Sorry, fresh out of colours for you guys ;)
	stanza_mt.pretty_print = stanza_mt.__tostring;
	stanza_mt.pretty_top_tag = stanza_mt.top_tag;
end

function stanza_mt.indent(t, level, indent)
	if #t == 0 or (#t == 1 and type(t[1]) == "string") then
		-- Empty nodes wouldn't have any indentation
		-- Text-only nodes are preserved as to not alter the text content
		-- Optimization: Skip clone of these since we don't alter them
		return t;
	end

	indent = indent or "\t";
	level = level or 1;
	local tag = clone(t, true);

	for child in t:children() do
		if type(child) == "string" then
			-- Already indented text would look weird but let's ignore that for now.
			if child:find("%S") then
				tag:text("\n" .. indent:rep(level));
				tag:text(child);
			end
		elseif is_stanza(child) then
			tag:text("\n" .. indent:rep(level));
			tag:add_direct_child(child:indent(level+1, indent));
		end
	end
	-- before the closing tag
	tag:text("\n" .. indent:rep((level-1)));

	return tag;
end

return {
	stanza_mt = stanza_mt;
	stanza = new_stanza;
	is_stanza = is_stanza;
	preserialize = preserialize;
	deserialize = deserialize;
	clone = clone;
	message = message;
	iq = iq;
	reply = reply;
	error_reply = error_reply;
	presence = presence;
	xml_escape = xml_escape;
	pretty_print = pretty;
};
