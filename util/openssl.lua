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
local ssl_config_mt = { __index = ssl_config };

function config.new()
	return setmetatable({
		req = {
			distinguished_name = "distinguished_name",
			req_extensions = "certrequest",
			x509_extensions = "selfsigned",
			prompt = "no",
		},
		distinguished_name = {
			countryName = "GB",
			-- stateOrProvinceName = "",
			localityName = "The Internet",
			organizationName = "Your Organisation",
			organizationalUnitName = "XMPP Department",
			commonName = "example.com",
			emailAddress = "xmpp@example.com",
		},
		certrequest = {
			basicConstraints = "CA:FALSE",
			keyUsage = "digitalSignature,keyEncipherment",
			extendedKeyUsage = "serverAuth,clientAuth",
			subjectAltName = "@subject_alternative_name",
		},
		selfsigned = {
			basicConstraints = "CA:TRUE",
			subjectAltName = "@subject_alternative_name",
		},
		subject_alternative_name = {
			DNS = {},
			otherName = {},
		},
	}, ssl_config_mt);
end

local DN_order = {
	"countryName";
	"stateOrProvinceName";
	"localityName";
	"streetAddress";
	"organizationName";
	"organizationalUnitName";
	"commonName";
	"emailAddress";
}
_M._DN_order = DN_order;
function ssl_config:serialize()
	local s = "";
	for k, t in pairs(self) do
		s = s .. ("[%s]\n"):format(k);
		if k == "subject_alternative_name" then
			for san, n in pairs(t) do
				for i = 1, #n do
					s = s .. s_format("%s.%d = %s\n", san, i -1, n[i]);
				end
			end
		elseif k == "distinguished_name" then
			for i, k in ipairs(t[1] and t or DN_order) do
				local v = t[k];
				if v then
					s = s .. ("%s = %s\n"):format(k, v);
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

_M.util = {
	utf8string = utf8string,
	ia5string = ia5string,
};

function ssl_config:add_dNSName(host)
	t_insert(self.subject_alternative_name.DNS, idna_to_ascii(host));
end

function ssl_config:add_sRVName(host, service)
	t_insert(self.subject_alternative_name.otherName,
		s_format("%s;%s", oid_dnssrv, ia5string("_" .. service .. "." .. idna_to_ascii(host))));
end

function ssl_config:add_xmppAddr(host)
	t_insert(self.subject_alternative_name.otherName,
		s_format("%s;%s", oid_xmppaddr, utf8string(host)));
end

function ssl_config:from_prosody(hosts, config, certhosts)
	-- TODO Decide if this should go elsewhere
	local found_matching_hosts = false;
	for i = 1, #certhosts do
		local certhost = certhosts[i];
		for name in pairs(hosts) do
			if name == certhost or name:sub(-1-#certhost) == "." .. certhost then
				found_matching_hosts = true;
				self:add_dNSName(name);
				--print(name .. "#component_module: " .. (config.get(name, "component_module") or "nil"));
				if config.get(name, "component_module") == nil then
					self:add_sRVName(name, "xmpp-client");
				end
				--print(name .. "#anonymous_login: " .. tostring(config.get(name, "anonymous_login")));
				if not (config.get(name, "anonymous_login") or
						config.get(name, "authentication") == "anonymous") then
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
		return "'" .. tostring(s):gsub("'",[['\'']]) .. "'";
	end

	local function serialize(command, args)
		local commandline = { "openssl", command };
		for k, v in pairs(args) do
			if type(k) == "string" then
				t_insert(commandline, ("-%s"):format(k));
				if v ~= true then
					t_insert(commandline, shell_escape(v));
				end
			end
		end
		for _, v in ipairs(args) do
			t_insert(commandline, shell_escape(v));
		end
		return t_concat(commandline, " ");
	end

	local os_execute = os.execute;
	setmetatable(_M, {
		__index = function(_, command)
			return function(opts)
				local ret = os_execute(serialize(command, type(opts) == "table" and opts or {}));
				return ret == true or ret == 0;
			end;
		end;
	});
end

return _M;
