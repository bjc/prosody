-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local select = select;
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
local backslash_escapes = {};
for k,v in pairs(escapes) do
	unescapes[v] = k;
	backslash_escapes[v] = v:gsub("\\", escapes)
end

local _ENV = nil;
-- luacheck: std none

local function split(jid)
	if jid == nil then return; end
	local node, nodepos = match(jid, "^([^@/]+)@()");
	local host, hostpos = match(jid, "^([^@/]+)()", nodepos);
	if node ~= nil and host == nil then return nil, nil, nil; end
	local resource = match(jid, "^/(.+)$", hostpos);
	if (host == nil) or ((resource == nil) and #jid >= hostpos) then return nil, nil, nil; end
	return node, host, resource;
end

local function bare(jid)
	local node, host = split(jid);
	if node ~= nil and host ~= nil then
		return node.."@"..host;
	end
	return host;
end

local function prepped_split(jid, strict)
	local node, host, resource = split(jid);
	if host ~= nil and host ~= "." then
		if sub(host, -1, -1) == "." then -- Strip empty root label
			host = sub(host, 1, -2);
		end
		host = nameprep(host, strict);
		if host == nil then return; end
		if node ~= nil then
			node = nodeprep(node, strict);
			if node == nil then return; end
		end
		if resource ~= nil then
			resource = resourceprep(resource, strict);
			if resource == nil then return; end
		end
		return node, host, resource;
	end
end

local function join(node, host, resource)
	if host == nil then return end
	if node ~= nil and resource ~= nil then
		return node.."@"..host.."/"..resource;
	elseif node ~= nil then
		return node.."@"..host;
	elseif resource ~= nil then
		return host.."/"..resource;
	end
	return host;
end

local function prep(jid, strict)
	local node, host, resource = prepped_split(jid, strict);
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

local function node(jid)
	return (select(1, split(jid)));
end

local function host(jid)
	return (select(2, split(jid)));
end

local function resource(jid)
	return (select(3, split(jid)));
end

-- TODO Forbid \20 at start and end of escaped output per XEP-0106 v1.1
local function escape(s) return s and (s:gsub("\\%x%x", backslash_escapes):gsub("[\"&'/:<>@ ]", escapes)); end
local function unescape(s) return s and (s:gsub("\\%x%x", unescapes)); end

return {
	split = split;
	bare = bare;
	prepped_split = prepped_split;
	join = join;
	prep = prep;
	compare = compare;
	node = node;
	host = host;
	resource = resource;
	escape = escape;
	unescape = unescape;
};
