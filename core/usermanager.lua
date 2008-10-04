
require "util.datamanager"
local datamanager = datamanager;
local log = require "util.logger".init("usermanager");

module "usermanager"

function validate_credentials(host, username, password)
	log("debug", "User '%s' is being validated", username);
	local credentials = datamanager.load(username, host, "accounts") or {};
	if password == credentials.password then return true; end
	return false;
end

return _M;