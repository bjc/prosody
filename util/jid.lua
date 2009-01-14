-- Prosody IM v0.2
-- Copyright (C) 2008 Matthew Wild
-- Copyright (C) 2008 Waqas Hussain
-- 
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License
-- as published by the Free Software Foundation; either version 2
-- of the License, or (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--



local match = string.match;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local nameprep = require "util.encodings".stringprep.nameprep;
local resourceprep = require "util.encodings".stringprep.resourceprep;

module "jid"

function split(jid)
	if not jid then return; end
	local node, nodepos = match(jid, "^([^@]+)@()");
	local host, hostpos = match(jid, "^([^@/]+)()", nodepos)
	if node and not host then return nil, nil, nil; end
	local resource = match(jid, "^/(.+)$", hostpos);
	if (not host) or ((not resource) and #jid >= hostpos) then return nil, nil, nil; end
	return node, host, resource;
end

function bare(jid)
	local node, host = split(jid);
	if node and host then
		return node.."@"..host;
	end
	return host;
end

function prepped_split(jid)
	local node, host, resource = split(jid);
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

function prep(jid)
	local node, host, resource = prepped_split(jid);
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

return _M;
