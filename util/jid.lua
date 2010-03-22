-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- 
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--



local match = string.match;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local nameprep = require "util.encodings".stringprep.nameprep;
local resourceprep = require "util.encodings".stringprep.resourceprep;

module "jid"

local function _split(jid)
	if not jid then return; end
	local node, nodepos = match(jid, "^([^@]+)@()");
	local host, hostpos = match(jid, "^([^@/]+)()", nodepos)
	if node and not host then return nil, nil, nil; end
	local resource = match(jid, "^/(.+)$", hostpos);
	if (not host) or ((not resource) and #jid >= hostpos) then return nil, nil, nil; end
	return node, host, resource;
end
split = _split;

function bare(jid)
	local node, host = _split(jid);
	if node and host then
		return node.."@"..host;
	end
	return host;
end

local function _prepped_split(jid)
	local node, host, resource = _split(jid);
	if host then
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
prepped_split = _prepped_split;

function prep(jid)
	local node, host, resource = _prepped_split(jid);
	if host then
		if node then
			host = node .. "@" .. host;
		end
		if resource then
			host = host .. "/" .. resource;
		end
	end
	return host;
end

function join(node, host, resource)
	if node and host and resource then
		return node.."@"..host.."/"..resource;
	elseif node and host then
		return node.."@"..host;
	elseif host and resource then
		return host.."/"..resource;
	elseif host then
		return host;
	end
	return nil; -- Invalid JID
end

return _M;
