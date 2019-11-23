local st = require "util.stanza";
local xmlns_csi = "urn:xmpp:csi:0";
local csi_feature = st.stanza("csi", { xmlns = xmlns_csi });

module:hook("stream-features", function (event)
	if event.origin.username and prosody.hosts[module.host].events._handlers["csi-client-active"] then
		event.features:add_child(csi_feature);
	end
end);

function refire_event(name)
	return function (event)
		if event.origin.username then
			event.origin.state = event.stanza.name;
			module:fire_event(name, event);
			return true;
		end
	end;
end

module:hook("stanza/"..xmlns_csi..":active", refire_event("csi-client-active"));
module:hook("stanza/"..xmlns_csi..":inactive", refire_event("csi-client-inactive"));

function module.load()
	if prosody.hosts[module.host].events._handlers["csi-client-active"] then
		module:set_status("core", "CSI handler module loaded");
	else
		module:set_status("warn", "No CSI handler module loaded");
	end
end
module:hook("module-loaded", module.load);
module:hook("module-unloaded", module.load);
