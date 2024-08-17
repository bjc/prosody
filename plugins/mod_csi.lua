local statsmanager = require "prosody.core.statsmanager";
local st = require "prosody.util.stanza";
local xmlns_csi = "urn:xmpp:csi:0";
local csi_feature = st.stanza("csi", { xmlns = xmlns_csi });

local change = module:metric("counter", "changes", "events", "CSI state changes", {"csi_state"});
local count = module:metric("gauge", "state", "sessions", "", { "state" });

module:hook("stream-features", function (event)
	if event.origin.username then
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

module:hook_global("stats-update", function()
	local sessions = prosody.hosts[module.host].sessions;
	if not sessions then return end
	statsmanager.cork();
	-- Can't do :clear() on host-scoped measures?
	count:with_labels("active"):set(0);
	count:with_labels("inactive"):set(0);
	count:with_labels("flushing"):set(0);
	for user, user_session in pairs(sessions) do
		for resource, session in pairs(user_session.sessions) do
			if session.state == "inactive" or session.state == "active" or session.state == "flushing" then
				count:with_labels(session.state):add(1);
			end
		end
	end
	statsmanager.uncork();
end);
