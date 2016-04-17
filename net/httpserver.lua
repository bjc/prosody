-- COMPAT w/pre-0.9
local log = require "util.logger".init("net.httpserver");
local traceback = debug.traceback;

local _ENV = nil;

function fail()
	log("error", "Attempt to use legacy HTTP API. For more info see https://prosody.im/doc/developers/legacy_http");
	log("error", "Legacy HTTP API usage, %s", traceback("", 2));
end

return {
	new = fail;
	new_from_config = fail;
	set_default_handler = fail;
};
