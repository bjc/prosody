
local match = string.match;

module "jid"

function split(jid)
	if not jid then return nil; end
	local node = match(jid, "^([^@]+)@");
	local server = (node and match(jid, ".-@([^@/]+)")) or match(jid, "^([^@/]+)");
	local resource = match(jid, "/(.+)$");
	return node, server, resource;
end

return _M;