-- COMPAT w/pre-0.9
local log = require "util.logger".init("net.connlisteners");
local traceback = debug.traceback;

local _ENV = nil;

local function fail()
	log("error", "Attempt to use legacy connlisteners API. For more info see https://prosody.im/doc/developers/network");
	log("error", "Legacy connlisteners API usage, %s", traceback("", 2));
end

return {
	register = fail;
	register = fail;
	get = fail;
	start = fail;
	-- epic fail
};
