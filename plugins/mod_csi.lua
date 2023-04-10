local st = require "prosody.util.stanza";
local xmlns_csi = "urn:xmpp:csi:0";
local csi_feature = st.stanza("csi", { xmlns = xmlns_csi });

local change = module:metric("counter", "changes", "events", "CSI state changes", {"csi_state"});

local csi_handler_available = nil;
module:hook("stream-features", function (event)
	if event.origin.username and csi_handler_available then
		event.features:add_child(csi_feature);
	end
end);

function refire_event(name)
	return function (event)
		if event.origin.username then
			event.origin.state = event.stanza.name;
			change:with_labels(event.stanza.name):add(1);
			module:fire_event(name, event);
			return true;
		end
	end;
end

module:hook("stanza/"..xmlns_csi..":active", refire_event("csi-client-active"));
module:hook("stanza/"..xmlns_csi..":inactive", refire_event("csi-client-inactive"));
