-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local match, sub = string.match, string.sub;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local nameprep = require "util.encodings".stringprep.nameprep;
local resourceprep = require "util.encodings".stringprep.resourceprep;

local escapes = {
	[" "] = "\\20"; ['"'] = "\\22";
	["&"] = "\\26"; ["'"] = "\\27";
	["/"] = "\\2f"; [":"] = "\\3a";
	["<"] = "\\3c"; [">"] = "\\3e";
	["@"] = "\\40"; ["\\"] = "\\5c";
};
local unescapes = {};
for k,v in pairs(escapes) do unescapes[v] = k; end

local _ENV = nil;

local function split(jid)
	if not jid then return; end
	local node, nodepos = match(jid, "^([^@/]+)@()");
	local host, hostpos = match(jid, "^([^@/]+)()", nodepos)
	if node and not host then return nil, nil, nil; end
	local resource = match(jid, "^/(.+)$", hostpos);
	if (not host) or ((not resource) and #jid >= hostpos) then return nil, nil, nil; end
	return node, host, resource;
end

local function bare(jid)
	local node, host = _split(jid);
	if node and host then
		return node.."@"..host;
	end
	return host;
end

local function prepped_split(jid)
	local node, host, resource = split(jid);
	if host then
		if sub(host, -1, -1) == "." then -- Strip empty root label
			host = sub(host, 1, -2);
		end
		host = nameprep(host);
		if not host then return; end
		if node then
			node = nodeprep(node);
			if not node then return; end
		end
		if resource then
			resource = resourceprep(resource);
			if not resource then return; end
		end
		return node, host, resource;
	end
end

local function join(node, host, resource)
	if not host then return end
	if node and resource then
		return node.."@"..host.."/"..resource;
	elseif node then
		return node.."@"..host;
	elseif resource then
		return host.."/"..resource;
	end
	return host;
end

local function prep(jid)
	local node, host, resource = prepped_split(jid);
	return join(node, host, resource);
end

local function compare(jid, acl)
	-- compare jid to single acl rule
	-- TODO compare to table of rules?
	local jid_node, jid_host, jid_resource = split(jid);
	local acl_node, acl_host, acl_resource = split(acl);
	if ((acl_node ~= nil and acl_node == jid_node) or acl_node == nil) and
		((acl_host ~= nil and acl_host == jid_host) or acl_host == nil) and
		((acl_resource ~= nil and acl_resource == jid_resource) or acl_resource == nil) then
		return true
	end
	return false
end

local function escape(s) return s and (s:gsub(".", escapes)); end
local function unescape(s) return s and (s:gsub("\\%x%x", unescapes)); end

return {
	split = split;
	bare = bare;
	prepped_split = prepped_split;
	join = join;
	prep = prep;
	compare = compare;
	escape = escape;
	unescape = unescape;
};
