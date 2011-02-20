-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local t_insert      =  table.insert;
local t_concat      =  table.concat;
local t_remove      =  table.remove;
local t_concat      =  table.concat;
local s_format      = string.format;
local s_match       =  string.match;
local tostring      =      tostring;
local setmetatable  =  setmetatable;
local getmetatable  =  getmetatable;
local pairs         =         pairs;
local ipairs        =        ipairs;
local type          =          type;
local next          =          next;
local print         =         print;
local unpack        =        unpack;
local s_gsub        =   string.gsub;
local s_char        =   string.char;
local s_find        =   string.find;
local os            =            os;

local do_pretty_printing = not os.getenv("WINDIR");
local getstyle, getstring;
if do_pretty_printing then
	local ok, termcolours = pcall(require, "util.termcolours");
	if ok then
		getstyle, getstring = termcolours.getstyle, termcolours.getstring;
	else
		do_pretty_printing = nil;
	end
end

local xmlns_stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas";

module "stanza"

stanza_mt = { __type = "stanza" };
stanza_mt.__index = stanza_mt;
local stanza_mt = stanza_mt;

function stanza(name, attr)
	local stanza = { name = name, attr = attr or {}, tags = {} };
	return setmetatable(stanza, stanza_mt);
end
local stanza = stanza;

function stanza_mt:query(xmlns)
	return self:tag("query", { xmlns = xmlns });
end

function stanza_mt:body(text, attr)
	return self:tag("body", attr):text(text);
end

function stanza_mt:tag(name, attrs)
	local s = stanza(name, attrs);
	local last_add = self.last_add;
	if not last_add then last_add = {}; self.last_add = last_add; end
	(last_add[#last_add] or self):add_direct_child(s);
	t_insert(last_add, s);
	return self;
end

function stanza_mt:text(text)
	local last_add = self.last_add;
	(last_add and last_add[#last_add] or self):add_direct_child(text);
	return self;
end

function stanza_mt:up()
	local last_add = self.last_add;
	if last_add then t_remove(last_add); end
	return self;
end

function stanza_mt:reset()
	self.last_add = nil;
	return self;
end

function stanza_mt:add_direct_child(child)
	if type(child) == "table" then
		t_insert(self.tags, child);
	end
	t_insert(self, child);
end

function stanza_mt:add_child(child)
	local last_add = self.last_add;
	(last_add and last_add[#last_add] or self):add_direct_child(child);
	return self;
end

function stanza_mt:get_child(name, xmlns)
	for _, child in ipairs(self.tags) do
		if (not name or child.name == name)
			and ((not xmlns and self.attr.xmlns == child.attr.xmlns)
				or child.attr.xmlns == xmlns) then
			
			return child;
		end
	end
end

function stanza_mt:get_child_text(name, xmlns)
	local tag = self:get_child(name, xmlns);
	if tag then
		return tag:get_text();
	end
	return nil;
end

function stanza_mt:child_with_name(name)
	for _, child in ipairs(self.tags) do
		if child.name == name then return child; end
	end
end

function stanza_mt:child_with_ns(ns)
	for _, child in ipairs(self.tags) do
		if child.attr.xmlns == ns then return child; end
	end
end

function stanza_mt:children()
	local i = 0;
	return function (a)
			i = i + 1
			return a[i];
		end, self, i;
end

function stanza_mt:childtags(name, xmlns)
	xmlns = xmlns or self.attr.xmlns;
	local tags = self.tags;
	local start_i, max_i = 1, #tags;
	return function ()
		for i = start_i, max_i do
			local v = tags[i];
			if (not name or v.name == name)
			and (not xmlns or xmlns == v.attr.xmlns) then
				start_i = i+1;
				return v;
			end
		end
	end;
end

function stanza_mt:maptags(callback)
	local tags, curr_tag = self.tags, 1;
	local n_children, n_tags = #self, #tags;
	
	local i = 1;
	while curr_tag <= n_tags do
		if self[i] == tags[curr_tag] then
			local ret = callback(self[i]);
			if ret == nil then
				t_remove(self, i);
				t_remove(tags, curr_tag);
				n_children = n_children - 1;
				n_tags = n_tags - 1;
			else
				self[i] = ret;
				tags[i] = ret;
			end
			i = i + 1;
			curr_tag = curr_tag + 1;
		end
	end
	return self;
end

local xml_escape
do
	local escape_table = { ["'"] = "&apos;", ["\""] = "&quot;", ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" };
	function xml_escape(str) return (s_gsub(str, "['&<>\"]", escape_table)); end
	_M.xml_escape = xml_escape;
end

local function _dostring(t, buf, self, xml_escape, parentns)
	local nsid = 0;
	local name = t.name
	t_insert(buf, "<"..name);
	for k, v in pairs(t.attr) do
		if s_find(k, "\1", 1, true) then
			local ns, attrk = s_match(k, "^([^\1]*)\1?(.*)$");
			nsid = nsid + 1;
			t_insert(buf, " xmlns:ns"..nsid.."='"..xml_escape(ns).."' ".."ns"..nsid..":"..attrk.."='"..xml_escape(v).."'");
		elseif not(k == "xmlns" and v == parentns) then
			t_insert(buf, " "..k.."='"..xml_escape(v).."'");
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
				self(child, buf, self, xml_escape, t.attr.xmlns);
			else
				t_insert(buf, xml_escape(child));
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
	local attr_string = "";
	if t.attr then
		for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(" %s='%s'", k, xml_escape(tostring(v))); end end
	end
	return s_format("<%s%s>", t.name, attr_string);
end

function stanza_mt.get_text(t)
	if #t.tags == 0 then
		return t_concat(t);
	end
end

function stanza_mt.get_error(stanza)
	local type, condition, text;
	
	local error_tag = stanza:get_child("error");
	if not error_tag then
		return nil, nil, nil;
	end
	type = error_tag.attr.type;
	
	for child in error_tag:childtags() do
		if child.attr.xmlns == xmlns_stanzas then
			if not text and child.name == "text" then
				text = child:get_text();
			elseif not condition then
				condition = child.name;
			end
			if condition and text then
				break;
			end
		end
	end
	return type, condition or "undefined-condition", text;
end

function stanza_mt.__add(s1, s2)
	return s1:add_direct_child(s2);
end


do
	local id = 0;
	function new_id()
		id = id + 1;
		return "lx"..id;
	end
end

function preserialize(stanza)
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

function deserialize(stanza)
	-- Set metatable
	if stanza then
		local attr = stanza.attr;
		for i=1,#attr do attr[i] = nil; end
		local attrx = {};
		for att in pairs(attr) do
			if s_find(att, "|", 1, true) and not s_find(att, "\1", 1, true) then
				local ns,na = s_match(att, "^([^|]+)|(.+)$");
				attrx[ns.."\1"..na] = attr[att];
				attr[att] = nil;
			end
		end
		for a,v in pairs(attrx) do
			attr[a] = v;
		end
		setmetatable(stanza, stanza_mt);
		for _, child in ipairs(stanza) do
			if type(child) == "table" then
				deserialize(child);
			end
		end
		if not stanza.tags then
			-- Rebuild tags
			local tags = {};
			for _, child in ipairs(stanza) do
				if type(child) == "table" then
					t_insert(tags, child);
				end
			end
			stanza.tags = tags;
		end
	end
	
	return stanza;
end

local function _clone(stanza)
	local attr, tags = {}, {};
	for k,v in pairs(stanza.attr) do attr[k] = v; end
	local new = { name = stanza.name, attr = attr, tags = tags };
	for i=1,#stanza do
		local child = stanza[i];
		if child.name then
			child = _clone(child);
			t_insert(tags, child);
		end
		t_insert(new, child);
	end
	return setmetatable(new, stanza_mt);
end
clone = _clone;

function message(attr, body)
	if not body then
		return stanza("message", attr);
	else
		return stanza("message", attr):tag("body"):text(body):up();
	end
end
function iq(attr)
	if attr and not attr.id then attr.id = new_id(); end
	return stanza("iq", attr or { id = new_id() });
end

function reply(orig)
	return stanza(orig.name, orig.attr and { to = orig.attr.from, from = orig.attr.to, id = orig.attr.id, type = ((orig.name == "iq" and "result") or orig.attr.type) });
end

do
	local xmpp_stanzas_attr = { xmlns = xmlns_stanzas };
	function error_reply(orig, type, condition, message)
		local t = reply(orig);
		t.attr.type = "error";
		t:tag("error", {type = type}) --COMPAT: Some day xmlns:stanzas goes here
			:tag(condition, xmpp_stanzas_attr):up();
		if (message) then t:tag("text", xmpp_stanzas_attr):text(message):up(); end
		return t; -- stanza ready for adding app-specific errors
	end
end

function presence(attr)
	return stanza("presence", attr);
end

if do_pretty_printing then
	local style_attrk = getstyle("yellow");
	local style_attrv = getstyle("red");
	local style_tagname = getstyle("red");
	local style_punc = getstyle("magenta");
	
	local attr_format = " "..getstring(style_attrk, "%s")..getstring(style_punc, "=")..getstring(style_attrv, "'%s'");
	local top_tag_format = getstring(style_punc, "<")..getstring(style_tagname, "%s").."%s"..getstring(style_punc, ">");
	--local tag_format = getstring(style_punc, "<")..getstring(style_tagname, "%s").."%s"..getstring(style_punc, ">").."%s"..getstring(style_punc, "</")..getstring(style_tagname, "%s")..getstring(style_punc, ">");
	local tag_format = top_tag_format.."%s"..getstring(style_punc, "</")..getstring(style_tagname, "%s")..getstring(style_punc, ">");
	function stanza_mt.pretty_print(t)
		local children_text = "";
		for n, child in ipairs(t) do
			if type(child) == "string" then
				children_text = children_text .. xml_escape(child);
			else
				children_text = children_text .. child:pretty_print();
			end
		end

		local attr_string = "";
		if t.attr then
			for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(attr_format, k, tostring(v)); end end
		end
		return s_format(tag_format, t.name, attr_string, children_text, t.name);
	end
	
	function stanza_mt.pretty_top_tag(t)
		local attr_string = "";
		if t.attr then
			for k, v in pairs(t.attr) do if type(k) == "string" then attr_string = attr_string .. s_format(attr_format, k, tostring(v)); end end
		end
		return s_format(top_tag_format, t.name, attr_string);
	end
else
	-- Sorry, fresh out of colours for you guys ;)
	stanza_mt.pretty_print = stanza_mt.__tostring;
	stanza_mt.pretty_top_tag = stanza_mt.top_tag;
end

return _M;
