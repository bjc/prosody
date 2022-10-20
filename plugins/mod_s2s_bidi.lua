-- Prosody IM
-- Copyright (C) 2019 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

local xmlns_bidi_feature = "urn:xmpp:features:bidi"
local xmlns_bidi = "urn:xmpp:bidi";

local require_encryption = module:get_option_boolean("s2s_require_encryption", true);

module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.type == "s2sin_unauthed" and (not require_encryption or origin.secure) then
		features:tag("bidi", { xmlns = xmlns_bidi_feature }):up();
	end
end);

module:hook_tag("http://etherx.jabber.org/streams", "features", function (session, stanza)
	if session.type == "s2sout_unauthed" and (not require_encryption or session.secure) then
		local bidi = stanza:get_child("bidi", xmlns_bidi_feature);
		if bidi then
			session.incoming = true;
			session.log("debug", "Requesting bidirectional stream");
			local request_bidi = st.stanza("bidi", { xmlns = xmlns_bidi });
			module:fire_event("s2sout-stream-features", { origin = session, features = request_bidi });
			session.sends2s(request_bidi);
		end
	end
end, 200);

module:hook_tag("urn:xmpp:bidi", "bidi", function(session)
	if session.type == "s2sin_unauthed" and (not require_encryption or session.secure) then
		session.log("debug", "Requested bidirectional stream");
		session.outgoing = true;
		return true;
	end
end);

