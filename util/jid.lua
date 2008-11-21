
local match = string.match;
local tostring = tostring;
local print = print
module "jid"

function split(jid)
	if not jid then return; end
	-- TODO verify JID, and return; if invalid
	local node, nodelen = match(jid, "^([^@]+)@()");
	local host, hostlen = match(jid, "^([^@/]+)()", nodelen)
	if node and not host then return nil, nil, nil; end
	local resource = match(jid, "^/(.+)$", hostlen);
	if (not host) or ((not resource) and #jid >= hostlen) then return nil, nil, nil; end
	return node, host, resource;
end

function bare(jid)
	local node, host = split(jid);
	if node and host then
		return node.."@"..host;
	elseif host then
		return host;
	end
	return nil;
end

return _M;
