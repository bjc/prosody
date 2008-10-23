
require "util.datamanager"

local datamanager = datamanager;
local t_insert = table.insert;

module "offlinemessage"

function new(user, host, stanza)
	local offlinedata = datamanager.load(user, host, "offlinemsg") or {};
	t_insert(offlinedata, stanza);
	return datamanager.store(user, host, "offlinemsg", offlinedata);
end

return _M;