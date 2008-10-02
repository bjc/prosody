
require "util.datamanager"
local datamanager = datamanager;

module "usermanager"

function validate_credentials(host, username, password)
	local credentials = datamanager.load(username, host, "accounts") or {};
	if password == credentials.password then return true; end
	return false;
end

return _M;