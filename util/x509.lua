-- Prosody IM
-- Copyright (C) 2010 Matthew Wild
-- Copyright (C) 2010 Paul Aurich
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- TODO: I feel a fair amount of this logic should be integrated into Luasec,
-- so that everyone isn't re-inventing the wheel.  Dependencies on
-- IDN libraries complicate that.


-- [TLS-CERTS] - http://tools.ietf.org/html/rfc6125
-- [XMPP-CORE] - http://tools.ietf.org/html/rfc6120
-- [SRV-ID]    - http://tools.ietf.org/html/rfc4985
-- [IDNA]      - http://tools.ietf.org/html/rfc5890
-- [LDAP]      - http://tools.ietf.org/html/rfc4519
-- [PKIX]      - http://tools.ietf.org/html/rfc5280

local nameprep = require "util.encodings".stringprep.nameprep;
local idna_to_ascii = require "util.encodings".idna.to_ascii;
local log = require "util.logger".init("x509");
local pairs, ipairs = pairs, ipairs;
local s_format = string.format;
local t_insert = table.insert;
local t_concat = table.concat;

module "x509"

local oid_commonname = "2.5.4.3"; -- [LDAP] 2.3
local oid_subjectaltname = "2.5.29.17"; -- [PKIX] 4.2.1.6
local oid_xmppaddr = "1.3.6.1.5.5.7.8.5"; -- [XMPP-CORE]
local oid_dnssrv   = "1.3.6.1.5.5.7.8.7"; -- [SRV-ID]

-- Compare a hostname (possibly international) with asserted names
-- extracted from a certificate.
-- This function follows the rules laid out in
-- sections 6.4.1 and 6.4.2 of [TLS-CERTS]
--
-- A wildcard ("*") all by itself is allowed only as the left-most label
local function compare_dnsname(host, asserted_names)
	-- TODO: Sufficient normalization?  Review relevant specs.
	local norm_host = idna_to_ascii(host)
	if norm_host == nil then
		log("info", "Host %s failed IDNA ToASCII operation", host)
		return false
	end

	norm_host = norm_host:lower()

	local host_chopped = norm_host:gsub("^[^.]+%.", "") -- everything after the first label

	for i=1,#asserted_names do
		local name = asserted_names[i]
		if norm_host == name:lower() then
			log("debug", "Cert dNSName %s matched hostname", name);
			return true
		end

		-- Allow the left most label to be a "*"
		if name:match("^%*%.") then
			local rest_name = name:gsub("^[^.]+%.", "")
			if host_chopped == rest_name:lower() then
				log("debug", "Cert dNSName %s matched hostname", name);
				return true
			end
		end
	end

	return false
end

-- Compare an XMPP domain name with the asserted id-on-xmppAddr
-- identities extracted from a certificate.  Both are UTF8 strings.
--
-- Per [XMPP-CORE], matches against asserted identities don't include
-- wildcards, so we just do a normalize on both and then a string comparison
--
-- TODO: Support for full JIDs?
local function compare_xmppaddr(host, asserted_names)
	local norm_host = nameprep(host)

	for i=1,#asserted_names do
		local name = asserted_names[i]

		-- We only want to match against bare domains right now, not
		-- those crazy full-er JIDs.
		if name:match("[@/]") then
			log("debug", "Ignoring xmppAddr %s because it's not a bare domain", name)
		else
			local norm_name = nameprep(name)
			if norm_name == nil then
				log("info", "Ignoring xmppAddr %s, failed nameprep!", name)
			else
				if norm_host == norm_name then
					log("debug", "Cert xmppAddr %s matched hostname", name)
					return true
				end
			end
		end
	end

	return false
end

-- Compare a host + service against the asserted id-on-dnsSRV (SRV-ID)
-- identities extracted from a certificate.
--
-- Per [SRV-ID], the asserted identities will be encoded in ASCII via ToASCII.
-- Comparison is done case-insensitively, and a wildcard ("*") all by itself
-- is allowed only as the left-most non-service label.
local function compare_srvname(host, service, asserted_names)
	local norm_host = idna_to_ascii(host)
	if norm_host == nil then
		log("info", "Host %s failed IDNA ToASCII operation", host);
		return false
	end

	-- Service names start with a "_"
	if service:match("^_") == nil then service = "_"..service end

	norm_host = norm_host:lower();
	local host_chopped = norm_host:gsub("^[^.]+%.", "") -- everything after the first label

	for i=1,#asserted_names do
		local asserted_service, name = asserted_names[i]:match("^(_[^.]+)%.(.*)");
		if service == asserted_service then
			if norm_host == name:lower() then
				log("debug", "Cert SRVName %s matched hostname", name);
				return true;
			end

			-- Allow the left most label to be a "*"
			if name:match("^%*%.") then
				local rest_name = name:gsub("^[^.]+%.", "")
				if host_chopped == rest_name:lower() then
					log("debug", "Cert SRVName %s matched hostname", name)
					return true
				end
			end
			if norm_host == name:lower() then
				log("debug", "Cert SRVName %s matched hostname", name);
				return true
			end
		end
	end

	return false
end

function verify_identity(host, service, cert)
	local ext = cert:extensions()
	if ext[oid_subjectaltname] then
		local sans = ext[oid_subjectaltname];

		-- Per [TLS-CERTS] 6.3, 6.4.4, "a client MUST NOT seek a match for a
		-- reference identifier if the presented identifiers include a DNS-ID
		-- SRV-ID, URI-ID, or any application-specific identifier types"
		local had_supported_altnames = false

		if sans[oid_xmppaddr] then
			had_supported_altnames = true
			if compare_xmppaddr(host, sans[oid_xmppaddr]) then return true end
		end

		if sans[oid_dnssrv] then
			had_supported_altnames = true
			-- Only check srvNames if the caller specified a service
			if service and compare_srvname(host, service, sans[oid_dnssrv]) then return true end
		end

		if sans["dNSName"] then
			had_supported_altnames = true
			if compare_dnsname(host, sans["dNSName"]) then return true end
		end

		-- We don't need URIs, but [TLS-CERTS] is clear.
		if sans["uniformResourceIdentifier"] then
			had_supported_altnames = true
		end

		if had_supported_altnames then return false end
	end

	-- Extract a common name from the certificate, and check it as if it were
	-- a dNSName subjectAltName (wildcards may apply for, and receive,
	-- cat treats)
	--
	-- Per [TLS-CERTS] 1.8, a CN-ID is the Common Name from a cert subject
	-- which has one and only one Common Name
	local subject = cert:subject()
	local cn = nil
	for i=1,#subject do
		local dn = subject[i]
		if dn["oid"] == oid_commonname then
			if cn then
				log("info", "Certificate has multiple common names")
				return false
			end

			cn = dn["value"];
		end
	end

	if cn then
		-- Per [TLS-CERTS] 6.4.4, follow the comparison rules for dNSName SANs.
		return compare_dnsname(host, { cn })
	end

	-- If all else fails, well, why should we be any different?
	return false
end

return _M;
