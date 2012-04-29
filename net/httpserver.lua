-- COMPAT w/pre-0.9
local log = require "util.logger".init("net.httpserver");
local traceback = debug.traceback;

module "httpserver"

function fail()
	log("error", "Attempt to use legacy HTTP API. For more info see http://prosody.im/doc/developers/legacy_http");
	log("error", "Legacy HTTP API usage, %s", traceback("", 2));
end

new, new_from_config = fail, fail;
set_default_handler = fail;

return _M;
