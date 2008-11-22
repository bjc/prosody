
local match = string.match;

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

return _M;
