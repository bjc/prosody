local saslprep = require "util.encodings".stringprep.saslprep;
local nodeprep = require "util.encodings".stringprep.nodeprep;
local jid = require "util.jid";
local json = require "util.json";
local log = require "util.logger".init("sasl");
local _ENV = nil;


local function oauthbearer(self, message)
	if not message then
		return "failure", "malformed-request";
	end

	if message == "\001" then
		return "failure", "not-authorized";
	end

	local gs2_authzid, kvpairs = message:match("n,a=([^,]+),(.+)$");
	if not gs2_authzid then
		return "failure", "malformed-request";
	end

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

	local username = jid.prepped_split(gs2_authzid);

	if not username or username == "" then
		return "failure", "malformed-request", "Expected authorization identity in the username@hostname format";
	end

	-- SASLprep username
	username = saslprep(username);

	if not username or username == "" then
		log("debug", "Username violates SASLprep.");
		return "failure", "malformed-request", "Invalid username.";
	end

	local _nodeprep = self.profile.nodeprep;
	if _nodeprep ~= false then
		username = (_nodeprep or nodeprep)(username);
		if not username or username == "" then
			return "failure", "malformed-request", "Invalid username or password."
		end
	end

	self.username = username;

	local token = auth_header:match("^Bearer (.+)$");

	local correct, state, token_info = self.profile.oauthbearer(self, username, token, self.realm);

	if state == false then
		return "failure", "account-disabled";
	elseif state == nil or not correct then
		-- For token-level errors, RFC 7628 demands use of a JSON-encoded
		-- challenge response upon failure. We relay additional info from
		-- the auth backend if available.
		return "challenge", json.encode({
			status = token_info and token_info.status or "invalid_token";
			scope = token_info and token_info.scope or nil;
			["openid-configuration"] = token_info and token_info.oidc_discovery_url or nil;
		});
	end

	self.resource = token_info.resource;
	self.role = token_info.role;
	self.token_info = token_info;

	return "success";
end

local function init(registerMechanism)
	registerMechanism("OAUTHBEARER", {"oauthbearer"}, oauthbearer);
end

return {
	init = init;
}
