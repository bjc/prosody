
local base64 = require "base64"
local log = require "util.logger".init("sasl");
local tostring = tostring;
local st = require "util.stanza";
local s_match = string.match;
module "sasl"


local function new_plain(onAuth, onSuccess, onFail, onWrite)
	local object = { mechanism = "PLAIN", onAuth = onAuth, onSuccess = onSuccess, onFail = onFail,
	 				onWrite = onWrite}
	--local challenge = base64.encode("");
	--onWrite(st.stanza("challenge", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):text(challenge))
	object.feed = 	function(self, stanza)
						if stanza.name ~= "response" and stanza.name ~= "auth" then self.onFail("invalid-stanza-tag") end
						if stanza.attr.xmlns ~= "urn:ietf:params:xml:ns:xmpp-sasl" then self.onFail("invalid-stanza-namespace") end
						local response = base64.decode(stanza[1])
						local authorization = s_match(response, "([^&%z]+)")
						local authentication = s_match(response, "%z([^&%z]+)%z")
						local password = s_match(response, "%z[^&%z]+%z([^&%z]+)")
						if self.onAuth(authentication, password) == true then
							self.onWrite(st.stanza("success", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}))
							self.onSuccess(authentication)
						else
							self.onWrite(st.stanza("failure", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):tag("temporary-auth-failure"));
						end
					end
	return object
end


function new(mechanism, onAuth, onSuccess, onFail, onWrite)
	local object
	if mechanism == "PLAIN" then object = new_plain(onAuth, onSuccess, onFail, onWrite)
	else
		log("debug", "Unsupported SASL mechanism: "..tostring(mechanism));
		onFail("unsupported-mechanism")
	end
	return object
end

return _M;