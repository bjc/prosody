module:set_global();

local cert_verify_identity = require "util.x509".verify_identity;
local NULL = {};
local log = module._log;

module:hook("s2s-check-certificate", function(event)
	local session, host, cert = event.session, event.host, event.cert;
	local conn = session.conn:socket();
	local log = session.log or log;

	if not cert then
		log("warn", "No certificate provided by %s", host or "unknown host");
		return;
	end

	local chain_valid, errors;
	if conn.getpeerverification then
		chain_valid, errors = conn:getpeerverification();
	elseif conn.getpeerchainvalid then -- COMPAT mw/luasec-hg
		chain_valid, errors = conn:getpeerchainvalid();
		errors = (not chain_valid) and { { errors } } or nil;
	else
		chain_valid, errors = false, { { "Chain verification not supported by this version of LuaSec" } };
	end
	-- Is there any interest in printing out all/the number of errors here?
	if not chain_valid then
		log("debug", "certificate chain validation result: invalid");
		for depth, t in pairs(errors or NULL) do
			log("debug", "certificate error(s) at depth %d: %s", depth-1, table.concat(t, ", "))
		end
		session.cert_chain_status = "invalid";
	else
		log("debug", "certificate chain validation result: valid");
		session.cert_chain_status = "valid";

		-- We'll go ahead and verify the asserted identity if the
		-- connecting server specified one.
		if host then
			if cert_verify_identity(host, "xmpp-server", cert) then
				session.cert_identity_status = "valid"
			else
				session.cert_identity_status = "invalid"
			end
			log("debug", "certificate identity validation result: %s", session.cert_identity_status);
		end
	end
end, 509);

