module:set_global();

local dns = require "prosody.net.adns";
local async = require "prosody.util.async";
local encodings = require "prosody.util.encodings";
local hashes = require "prosody.util.hashes";
local promise = require "prosody.util.promise";
local x509 = require "prosody.util.x509";

local idna_to_ascii = encodings.idna.to_ascii;
local sha256 = hashes.sha256;
local sha512 = hashes.sha512;

local use_dane = module:get_option_boolean("use_dane", nil);
if use_dane == nil then
	module:log("warn", "DANE support incomplete, add use_dane = true in the global section to support outgoing s2s connections");
elseif use_dane == false then
	module:log("debug", "DANE support disabled with use_dane = false, disabling.")
	return
end

local function ensure_secure(r)
	assert(r.secure, "insecure");
	return r;
end

local lazy_tlsa_mt = {
	__index = function(t, i)
		if i == 1 then
			local h = sha256(t[0]);
			t[1] = h;
			return h;
		elseif i == 2 then
			local h = sha512(t[0]);
			t[1] = h;
			return h;
		end
	end;
}
local function lazy_hash(t)
	return setmetatable(t, lazy_tlsa_mt);
end

module:hook("s2s-check-certificate", function(event)
	local session, host, cert = event.session, event.host, event.cert;
	local log = session.log or module._log;

	if not host or not cert or session.direction ~= "incoming" then
		return
	end

	local by_select_match = {
		[0] = lazy_hash {
			-- cert
			[0] = x509.pem2der(cert:pem());

		};
	}
	if cert.pubkey then
		by_select_match[1] = lazy_hash {
			-- spki
			[0] = x509.pem2der(cert:pubkey());
		};
	end

	local resolver = dns.resolver();

	local dns_domain = idna_to_ascii(host);

	local function fetch_tlsa(res)
		local tlsas = {};
		for _, rr in ipairs(res) do
			table.insert(tlsas, resolver:lookup_promise(("_%d._tcp.%s"):format(rr.srv.port, rr.srv.target), "TLSA"):next(ensure_secure));
		end
		return promise.all(tlsas);
	end

	local ret = async.wait_for(promise.all({
		resolver:lookup_promise("_xmpps-server._tcp." .. dns_domain, "SRV"):next(ensure_secure):next(fetch_tlsa);
		resolver:lookup_promise("_xmpp-server._tcp." .. dns_domain, "SRV"):next(ensure_secure):next(fetch_tlsa);
	}));

	if not ret then
		return
	end

	local found_supported = false;
	for _, by_proto in ipairs(ret) do
		for _, by_srv in ipairs(by_proto) do
			for _, by_target in ipairs(by_srv) do
				for _, rr in ipairs(by_target) do
					if rr.tlsa.use == 3 and by_select_match[rr.tlsa.select] and rr.tlsa.match <= 2 then
						found_supported = true;
						if rr.tlsa.data == by_select_match[rr.tlsa.select][rr.tlsa.match] then
							module:log("debug", "%s matches", rr)
							session.cert_chain_status = "valid";
							session.cert_identity_status = "valid";
							return true;
						end
					else
						log("debug", "Unsupported DANE TLSA record: %s", rr);
					end
				end
			end
		end
	end

	if found_supported then
		session.cert_chain_status = "invalid";
		session.cert_identity_status = nil;
		return true;
	end

end, 800);
