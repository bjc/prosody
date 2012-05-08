local type, tostring, pairs, ipairs = type, tostring, pairs, ipairs;
local t_insert, t_concat = table.insert, table.concat;
local s_format = string.format;

local oid_xmppaddr = "1.3.6.1.5.5.7.8.5"; -- [XMPP-CORE]
local oid_dnssrv   = "1.3.6.1.5.5.7.8.7"; -- [SRV-ID]

local idna_to_ascii = require "util.encodings".idna.to_ascii;

local _M = {};
local config = {};
_M.config = config;

local ssl_config = {};
local ssl_config_mt = {__index=ssl_config};

function config.new()
	return setmetatable({
		req = {
			distinguished_name = "distinguished_name",
			req_extensions = "v3_extensions",
			x509_extensions = "v3_extensions",
			prompt = "no",
		},
		distinguished_name = {
			commonName = "example.com",
			countryName = "GB",
			localityName = "The Internet",
			organizationName = "Your Organisation",
			organizationalUnitName = "XMPP Department",
			emailAddress = "xmpp@example.com",
		},
		v3_extensions = {
			basicConstraints = "CA:FALSE",
			keyUsage = "digitalSignature,keyEncipherment",
			extendedKeyUsage = "serverAuth,clientAuth",
			subjectAltName = "@subject_alternative_name",
		},
		subject_alternative_name = {
			DNS = {},
			otherName = {},
		},
	}, ssl_config_mt);
end

function ssl_config:serialize()
	local s = "";
	for k, t in pairs(self) do
		s = s .. ("[%s]\n"):format(k);
		if k == "subject_alternative_name" then
			for san, n in pairs(t) do
				for i = 1,#n do
					s = s .. s_format("%s.%d = %s\n", san, i -1, n[i]);
				end
			end
		else
			for k, v in pairs(t) do
				s = s .. ("%s = %s\n"):format(k, v);
			end
		end
		s = s .. "\n";
	end
	return s;
end

local function utf8string(s)
	-- This is how we tell openssl not to encode UTF-8 strings as fake Latin1
	return s_format("FORMAT:UTF8,UTF8:%s", s);
end

local function ia5string(s)
	return s_format("IA5STRING:%s", s);
end

local util = {};
_M.util = {
	utf8string = utf8string,
	ia5string = ia5string,
};

local function xmppAddr(t, host)
end

function ssl_config:add_dNSName(host)
	t_insert(self.subject_alternative_name.DNS, idna_to_ascii(host));
end

function ssl_config:add_sRVName(host, service)
	t_insert(self.subject_alternative_name.otherName,
		s_format("%s;%s", oid_dnssrv, ia5string("_" .. service .."." .. idna_to_ascii(host))));
end

function ssl_config:add_xmppAddr(host)
	t_insert(self.subject_alternative_name.otherName,
		s_format("%s;%s", oid_xmppaddr, utf8string(host)));
end

function ssl_config:from_prosody(hosts, config, certhosts, raw)
	-- TODO Decide if this should go elsewhere
	local found_matching_hosts = false;
	for i = 1,#certhosts do
		local certhost = certhosts[i];
		for name, host in pairs(hosts) do
			if name == certhost or name:sub(-1-#certhost) == "."..certhost then
				found_matching_hosts = true;
				self:add_dNSName(name);
				--print(name .. "#component_module: " .. (config.get(name, "core", "component_module") or "nil"));
				if config.get(name, "core", "component_module") == nil then
					self:add_sRVName(name, "xmpp-client");
				end
				--print(name .. "#anonymous_login: " .. tostring(config.get(name, "core", "anonymous_login")));
				if not (config.get(name, "core", "anonymous_login") or
						config.get(name, "core", "authentication") == "anonymous") then
					self:add_sRVName(name, "xmpp-server");
				end
				self:add_xmppAddr(name);
			end
		end
	end
	if not found_matching_hosts then
		return nil, "no-matching-hosts";
	end
end

do -- Lua to shell calls.
	local function shell_escape(s)
		return s:gsub("'",[['\'']]);
	end

	local function serialize(f,o)
		local r = {"openssl", f};
		for k,v in pairs(o) do
			if type(k) == "string" then
				t_insert(r, ("-%s"):format(k));
				if v ~= true then
					t_insert(r, ("'%s'"):format(shell_escape(tostring(v))));
				end
			end
		end
		for k,v in ipairs(o) do
			t_insert(r, ("'%s'"):format(shell_escape(tostring(v))));
		end
		return t_concat(r, " ");
	end

	local os_execute = os.execute;
	setmetatable(_M, {
		__index=function(self,f)
			return function(opts)
				return 0 == os_execute(serialize(f, type(opts) == "table" and opts or {}));
			end;
		end;
	});
end

return _M;
