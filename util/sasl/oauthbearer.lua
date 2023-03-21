local json = require "util.json";
local _ENV = nil;


local function oauthbearer(self, message)
	if not message then
		return "failure", "malformed-request";
	end

	if message == "\001" then
		return "failure", "not-authorized";
	end

	local gs2_header, kvpairs = message:match("^(n,[^,]*,)(.+)$");
	if not gs2_header then
		return "failure", "malformed-request";
	end
	local gs2_authzid = gs2_header:match("^[^,]*,a=([^,]*),$");

	local auth_header;
	for k, v in kvpairs:gmatch("([a-zA-Z]+)=([\033-\126 \009\r\n]*)\001") do
		if k == "auth" then
			auth_header = v;
			break;
		end
	end

	if not auth_header then
		return "failure", "malformed-request";
	end

	local token = auth_header:match("^Bearer (.+)$");

	local username, state, token_info = self.profile.oauthbearer(self, token, self.realm, gs2_authzid);

	if state == false then
		return "failure", "account-disabled";
	elseif state == nil or not username then
		-- For token-level errors, RFC 7628 demands use of a JSON-encoded
		-- challenge response upon failure. We relay additional info from
		-- the auth backend if available.
		return "challenge", json.encode({
			status = token_info and token_info.status or "invalid_token";
			scope = token_info and token_info.scope or nil;
			["openid-configuration"] = token_info and token_info.oidc_discovery_url or nil;
		});
	end
	self.username = username;
	self.token_info = token_info;

	return "success";
end

local function init(registerMechanism)
	registerMechanism("OAUTHBEARER", {"oauthbearer"}, oauthbearer);
end

return {
	init = init;
}
