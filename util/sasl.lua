
local base64 = require "base64"
local md5 = require "md5"
--local crypto = require "crypto"
local log = require "util.logger".init("sasl");
local tostring = tostring;
local st = require "util.stanza";
local generate_uuid = require "util.uuid".generate;
local s_match = string.match;
local gmatch = string.gmatch
local string = string
local math = require "math"
local type = type
local error = error
local print = print

module "sasl"

local function new_plain(realm, password_handler)
	local object = { mechanism = "PLAIN", realm = realm, password_handler = password_handler}
	object.feed = 	function(self, message)
						--print(message:gsub("%W", function (c) return string.format("\\%d", string.byte(c)) end));

						if message == "" or message == nil then return "failure", "malformed-request" end
						local response = message
						local authorization = s_match(response, "([^&%z]+)")
						local authentication = s_match(response, "%z([^&%z]+)%z")
						local password = s_match(response, "%z[^&%z]+%z([^&%z]+)")
						
						local password_encoding, correct_password = self.password_handler(authentication.."@"..self.realm, "PLAIN")
						
						local claimed_password = ""
						if password_encoding == nil then claimed_password = password
						else claimed_password = password_encoding(password) end
						
						self.username = authentication
						if claimed_password == correct_password then
							log("debug", "success")
							return "success", nil
						else
							log("debug", "failure")
							return "failure", "not-authorized"
						end
					end
	return object
end

local function new_digest_md5(onAuth, onSuccess, onFail, onWrite)
	--TODO maybe support for authzid

	local function serialize(message)
		local data = ""
		
		if type(message) ~= "table" then error("serialize needs an argument of type table.") end
		
		-- testing all possible values
		if message["nonce"] then data = data..[[nonce="]]..message.nonce..[[",]] end
		if message["qop"] then data = data..[[qop="]]..message.qop..[[",]] end
		if message["charset"] then data = data..[[charset=]]..message.charset.."," end
		if message["algorithm"] then data = data..[[algorithm=]]..message.algorithm.."," end
		if message["realm"] then data = data..[[realm="]]..message.realm..[[",]] end
		if message["rspauth"] then data = data..[[rspauth=]]..message.rspauth.."," end
		data = data:gsub(",$", "")
		return data
	end
	
	local function parse(data)
		message = {}
		log("debug", "parse-message: "..data)
		for k, v in gmatch(data, [[([%w%-]+)="?([%w%-%/%.%+=]+)"?,?]]) do
			message[k] = v
		log("debug", "               "..k.." = "..v)
		end
		return message
	end

	local object = { mechanism = "DIGEST-MD5", onAuth = onAuth, onSuccess = onSuccess, onFail = onFail,
	 				onWrite = onWrite }
	
	--TODO: something better than math.random would be nice, maybe OpenSSL's random number generator
	object.nonce = generate_uuid()
	log("debug", "SASL nonce: "..object.nonce)
	object.step = 1
	object.nonce_count = {}
	local challenge = base64.encode(serialize({	nonce = object.nonce, 
												qop = "auth",
												charset = "utf-8",
												algorithm = "md5-sess"} ));
	object.onWrite(st.stanza("challenge", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):text(challenge))
	object.feed = 	function(self, stanza)
						log("debug", "SASL step: "..self.step)
						if stanza.name ~= "response" and stanza.name ~= "auth" then self.onFail("invalid-stanza-tag") end
						if stanza.attr.xmlns ~= "urn:ietf:params:xml:ns:xmpp-sasl" then self.onFail("invalid-stanza-namespace") end
						if stanza.name == "auth" then return end
						self.step = self.step + 1
						if (self.step == 2) then
							local response = parse(base64.decode(stanza[1]))
							-- check for replay attack
							if response["nc"] then
								if self.nonce_count[response["nc"]] then self.onFail("not-authorized") end
							end
							
							-- check for username, it's REQUIRED by RFC 2831
							if not response["username"] then
								self.onFail("malformed-request")
							end
							self["username"] = response["username"] 
							
							-- check for nonce, ...
							if not response["nonce"] then
								self.onFail("malformed-request")
							else
								-- check if it's the right nonce
								if response["nonce"] ~= tostring(self.nonce) then self.onFail("malformed-request") end
							end
							
							if not response["cnonce"] then self.onFail("malformed-request") end
							if not response["qop"] then response["qop"] = "auth" end
							
							if response["realm"] == nil then response["realm"] = "" end
							
							local domain = ""
							local protocol = ""
							if response["digest-uri"] then
								protocol, domain = response["digest-uri"]:match("(%w+)/(.*)$")
							else
								error("No digest-uri")
							end
														
							-- compare response_value with own calculation
							--local A1 = usermanager.get_md5(response["username"], hostname)..":"..response["nonce"]..response["cnonce"]
							
							--FIXME actual username and password here :P
							local X = "tobias:"..response["realm"]..":tobias"
							local Y = md5.sum(X)
							local A1 = Y..":"..response["nonce"]..":"..response["cnonce"]--:authzid
							local A2 = "AUTHENTICATE:"..protocol.."/"..domain
							
							local HA1 = md5.sumhexa(A1)
							local HA2 = md5.sumhexa(A2)
							
							local KD = HA1..":"..response["nonce"]..":"..response["nc"]..":"..response["cnonce"]..":"..response["qop"]..":"..HA2
							local response_value = md5.sumhexa(KD)
							
							log("debug", "response_value: "..response_value);
							log("debug", "response:       "..response["response"]);
							if response_value == response["response"] then
								-- calculate rspauth
								A2 = ":"..protocol.."/"..domain
								
								HA1 = md5.sumhexa(A1)
								HA2 = md5.sumhexa(A2)

								KD = HA1..":"..response["nonce"]..":"..response["nc"]..":"..response["cnonce"]..":"..response["qop"]..":"..HA2
								local rspauth = md5.sumhexa(KD)
								
								self.onWrite(st.stanza("challenge", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):text(base64.encode(serialize({rspauth = rspauth}))))
							else
								self.onWrite(st.stanza("response", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}))
								self.onFail()
							end							
						elseif self.step == 3 then
							if stanza.name == "response" then 
								self.onWrite(st.stanza("success", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}))
								self.onSuccess(self.username)
							else 
								self.onFail("Third step isn't a response stanza.")
							end
						end
					end
	return object
end

function new(mechanism, realm, password)
	local object
	if mechanism == "PLAIN" then object = new_plain(realm, password)
	--elseif mechanism == "DIGEST-MD5" then object = new_digest_md5(ream, password)
	else
		log("debug", "Unsupported SASL mechanism: "..tostring(mechanism));
		return nil
	end
	return object
end

return _M;