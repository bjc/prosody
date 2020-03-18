local st = require "util.stanza";

local xmlns_hats = "xmpp:prosody.im/protocol/hats:1";

module:hook("muc-broadcast-presence", function (event)
	-- Strip any hats claimed by the client (to prevent spoofing)
	event.stanza:remove_children("hats", xmlns_hats);

	local aff_data = event.room:get_affiliation_data(event.occupant.bare_jid);
	local hats = aff_data and aff_data.hats;
	if not hats then return; end
	local hats_el;
	for hat_id, hat_data in pairs(hats) do
		if hat_data.active then
			if not hats_el then
				hats_el = st.stanza("hats", { xmlns = xmlns_hats });
			end
			hats_el:tag("hat", { uri = hat_id, title = hat_data.title }):up();
		end
	end
	if not hats_el then return; end
	event.stanza:add_direct_child(hats_el);
end);
