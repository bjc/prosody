
local base64 = require "base64"
local md5 = require "md5"
local crypto = require "crypto"
local log = require "util.logger".init("sasl");
local tostring = tostring;
local st = require "util.stanza";
local generate_uuid = require "util.uuid".generate;
local s_match = string.match;
local gmatch = string.gmatch
local math = require "math"
local type = type
local error = error
local print = print

module "sasl"

local function new_plain(onAuth, onSuccess, onFail, onWrite)
	local object = { mechanism = "PLAIN", onAuth = onAuth, onSuccess = onSuccess, onFail = onFail,
	 				onWrite = onWrite}
	local challenge = base64.encode("");
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


--[[
SERVER:
nonce="3145176401",qop="auth",charset=utf-8,algorithm=md5-sess

CLIENT: username="tobiasfar",nonce="3145176401",cnonce="pJiW7hzeZLvOSAf7gBzwTzLWe4obYOVDlnNESzQCzGg=",nc=00000001,digest-uri="xmpp/jabber.org",qop=auth,response=99a93ba75235136e6403c3a2ba37089d,charset=utf-8	

username="tobias",nonce="4406697386",cnonce="wUnT7vYrOB0V8D/lKd5bhpaNCk+hLJwc8T4CBCqp7WM=",nc=00000001,digest-uri="xmpp/luaetta.ath.cx",qop=auth,response=d202b8a1bdf8204816fb23c5f87b6b63,charset=utf-8

SERVER:
rspauth=ab66d28c260e97da577ce3aac46a8991
]]--
local function new_digest_md5(onAuth, onSuccess, onFail, onWrite)
	local function H(s)
		return md5.sum(s)
	end
	
	local function KD(k, s)
		return H(k..":"..s)
	end
	
	local function HEX(n)
		return md5.sumhexa(n)
	end

	local function HMAC(k, s)
		return crypto.hmac.digest("md5", s, k, true)
	end

	local function serialize(message)
		local data = ""
		
		if type(message) ~= "table" then error("serialize needs an argument of type table.") end
		
		-- testing all possible values
		if message["nonce"] then data = data..[[nonce="]]..message.nonce..[[",]] end
		if message["qop"] then data = data..[[qop="]]..message.qop..[[",]] end
		if message["charset"] then data = data..[[charset=]]..message.charset.."," end
		if message["algorithm"] then data = data..[[algorithm=]]..message.algorithm.."," end
		if message["rspauth"] then data = data..[[rspauth=]]..message.algorith.."," end
		data = data:gsub(",$", "")
		return data
	end
	
	local function parse(data)
		message = {}
		for k, v in gmatch(data, [[([%w%-]+)="?([%w%-%/%.]+)"?,?]]) do
			message[k] = v
		end
		return message
	end

	local object = { mechanism = "DIGEST-MD5", onAuth = onAuth, onSuccess = onSuccess, onFail = onFail,
	 				onWrite = onWrite }
	
	--TODO: something better than math.random would be nice, maybe OpenSSL's random number generator
	object.nonce = math.random(0, 9)
	for i = 1, 9 do object.nonce = object.nonce..math.random(0, 9) end
	object.step = 1
	object.nonce_count = {}
	local challenge = base64.encode(serialize({	nonce = object.nonce, 
												qop = "auth",
												charset = "utf-8",
												algorithm = "md5-sess"} ));
	object.onWrite(st.stanza("challenge", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):text(challenge))
	object.feed = 	function(self, stanza)
						if stanza.name ~= "response" and stanza.name ~= "auth" then self.onFail("invalid-stanza-tag") end
						if stanza.attr.xmlns ~= "urn:ietf:params:xml:ns:xmpp-sasl" then self.onFail("invalid-stanza-namespace") end
						if stanza.name == "auth" then return end
						self.step = self.step + 1
						if (self.step == 2) then
							local response = parse(base64.decode(stanza[1]))
							-- check for replay attack
							if response["nonce-count"] then
								if self.nonce_count[response["nonce-count"]] then self.onFail("not-authorized") end
							end
							
							-- check for username, it's REQUIRED by RFC 2831
							if not response["username"] then
								self.onFail("malformed-request")
							end
							
							-- check for nonce, ...
							if not response["nonce"] then
								self.onFail("malformed-request")
							else
								-- check if it's the right nonce
								if response["nonce"] ~= self.nonce then self.onFail("malformed-request") end
							end
							
							if not response["cnonce"] then self.onFail("malformed-request") end
							if not response["qop"] then response["qop"] = "auth" end
							
							local hostname = ""
							local protocol = ""
							if response["digest-uri"] then
								protocol, hostname = response["digest-uri"]:match("(%w+)/(.*)$")
							else
								error("No digest-uri")
							end
														
							-- compare response_value with own calculation
							local A1-- = H(response["username"]..":"..realm-value, ":", passwd } ),
							        --   ":", nonce-value, ":", cnonce-value)
							local A2
							
							--local response_value = HEX(KD(HEX(H(A1)), response["nonce"]..":"..response["nonce-count"]..":"..response["cnonce-value"]..":"..response["qop"]..":"..HEX(H(A2))))
							
							if response["qop"] == "auth" then
							
							else
							
							end
							
							--local response_value = HEX(KD(HEX(H(A1)), response["nonce"]..":"..response["nonce-count"]..":"..response["cnonce-value"]..":"..response["qop"]..":"..HEX(H(A2))))
							
						end
						--[[
						local authorization = s_match(response, "([^&%z]+)")
						local authentication = s_match(response, "%z([^&%z]+)%z")
						local password = s_match(response, "%z[^&%z]+%z([^&%z]+)")
						if self.onAuth(authentication, password) == true then
							self.onWrite(st.stanza("success", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}))
							self.onSuccess(authentication)
						else
							self.onWrite(st.stanza("failure", {xmlns = "urn:ietf:params:xml:ns:xmpp-sasl"}):tag("temporary-auth-failure"));
						end]]--
					end
	return object
end

function new(mechanism, onAuth, onSuccess, onFail, onWrite)
	local object
	if mechanism == "PLAIN" then object = new_plain(onAuth, onSuccess, onFail, onWrite)
	elseif mechanism == "DIGEST-MD5" then object = new_digest_md5(onAuth, onSuccess, onFail, onWrite)
	else
		log("debug", "Unsupported SASL mechanism: "..tostring(mechanism));
		onFail("unsupported-mechanism")
	end
	return object
end

return _M;