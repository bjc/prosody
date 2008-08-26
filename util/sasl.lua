require "base64"
sasl = {}

function sasl:new_plain(onAuth, onSuccess, onFail, onWrite)
	local object = { mechanism = "PLAIN", onAuth = onAuth, onSuccess = onSuccess, onFail = onFail,
	 				onWrite = onWrite}
	local challenge = base64.encode("");
	onWrite(stanza.stanza("challenge", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):text(challenge))
	object.feed = 	function(self, stanza)
						if (stanza.name ~= "response") then self.onFail() end
						if (stanza.attr.xmlns ~= "urn:ietf:params:xml:ns:xmpp-sasl") then self.onFail() end
						local response = base64.decode(stanza.tag[1])
						local authorization = string.match(response, [[([^&\0]+)]])
						local authentication = string.match(response, [[\0([^&\0]+)\0]])
						local password = string.match(response, [[\0[^&\0]+\0([^&\0]+)]])
						if self.onAuth(authorization, password) == true then
							self.onWrite(stanza.stanza("success", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}))
							self.onSuccess()
						else
							self.onWrite(stanza.stanza("failure", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):tag("temporary-auth-failure"));
						end
					end
	return object
end

function sasl:new(mechanism, onAuth, onSuccess, onFail, onWrite)
	local object
	if mechanism == "PLAIN" then object = new_plain(onAuth, onSuccess, onFail, onWrite)
	else onFail()
	end
	return object
end

module "sasl"
