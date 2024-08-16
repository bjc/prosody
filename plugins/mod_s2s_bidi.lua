-- Prosody IM
-- Copyright (C) 2019 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "prosody.util.stanza";

local xmlns_bidi_feature = "urn:xmpp:features:bidi"
local xmlns_bidi = "urn:xmpp:bidi";

local require_encryption = module:get_option_boolean("s2s_require_encryption", true);

local offers_sent = module:metric("counter", "offers_sent", "", "Bidirectional connection offers sent", {});
local offers_recv = module:metric("counter", "offers_recv", "", "Bidirectional connection offers received", {});
local offers_taken = module:metric("counter", "offers_taken", "", "Bidirectional connection offers taken", {});

module:hook("s2s-stream-features", function(event)
	local origin, features = event.origin, event.features;
	if origin.type == "s2sin_unauthed" and (not require_encryption or origin.secure) then
		features:tag("bidi", { xmlns = xmlns_bidi_feature }):up();
		offers_sent:with_labels():add(1);
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
			offers_taken:with_labels():add(1);
		end
	end
end, 200);

module:hook_tag("urn:xmpp:bidi", "bidi", function(session)
	if session.type == "s2sin_unauthed" and (not require_encryption or session.secure) then
		session.log("debug", "Requested bidirectional stream");
		session.outgoing = true;
		offers_recv:with_labels():add(1);
		return true;
	end
end);

