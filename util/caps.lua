-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local base64 = require "util.encodings".base64.encode;
local sha1 = require "util.hashes".sha1;

local t_insert, t_sort, t_concat = table.insert, table.sort, table.concat;
local ipairs = ipairs;

local _ENV = nil;

local function calculate_hash(disco_info)
	local identities, features, extensions = {}, {}, {};
	for _, tag in ipairs(disco_info) do
		if tag.name == "identity" then
			t_insert(identities, (tag.attr.category or "").."\0"..(tag.attr.type or "").."\0"..(tag.attr["xml:lang"] or "").."\0"..(tag.attr.name or ""));
		elseif tag.name == "feature" then
			t_insert(features, tag.attr.var or "");
		elseif tag.name == "x" and tag.attr.xmlns == "jabber:x:data" then
			local form = {};
			local FORM_TYPE;
			for _, field in ipairs(tag.tags) do
				if field.name == "field" and field.attr.var then
					local values = {};
					for _, val in ipairs(field.tags) do
						val = #val.tags == 0 and val:get_text();
						if val then t_insert(values, val); end
					end
					t_sort(values);
					if field.attr.var == "FORM_TYPE" then
						FORM_TYPE = values[1];
					elseif #values > 0 then
						t_insert(form, field.attr.var.."\0"..t_concat(values, "<"));
					else
						t_insert(form, field.attr.var);
					end
				end
			end
			t_sort(form);
			form = t_concat(form, "<");
			if FORM_TYPE then form = FORM_TYPE.."\0"..form; end
			t_insert(extensions, form);
		end
	end
	t_sort(identities);
	t_sort(features);
	t_sort(extensions);
	if #identities > 0 then identities = t_concat(identities, "<"):gsub("%z", "/").."<"; else identities = ""; end
	if #features > 0 then features = t_concat(features, "<").."<"; else features = ""; end
	if #extensions > 0 then extensions = t_concat(extensions, "<"):gsub("%z", "<").."<"; else extensions = ""; end
	local S = identities..features..extensions;
	local ver = base64(sha1(S));
	return ver, S;
end

return {
	calculate_hash = calculate_hash;
};
