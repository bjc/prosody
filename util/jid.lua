
local match = string.match;

module "jid"

function split(jid)
	return match(jid, "^([^@]+)@([^/]+)/?(.*)$");
end
