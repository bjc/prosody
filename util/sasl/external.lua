local saslprep = require "util.encodings".stringprep.saslprep;

local _ENV = nil;

local function external(self, message)
	message = saslprep(message);
	local state
	self.username, state = self.profile.external(message);

	if state == false then
		return "failure", "account-disabled";
	elseif state == nil  then
		return "failure", "not-authorized";
	elseif state == "expired" then
		return "false", "credentials-expired";
	end

	return "success";
end

local function init(registerMechanism)
	registerMechanism("EXTERNAL", {"external"}, external);
end

return {
	init = init;
}
