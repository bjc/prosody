local st = require "util.stanza";
local muc_util = module:require "muc/util";

local xmlns_hats = "xmpp:prosody.im/protocol/hats:1";

-- Strip any hats claimed by the client (to prevent spoofing)
muc_util.add_filtered_namespace(xmlns_hats);


module:hook("muc-build-occupant-presence", function (event)
	local bare_jid = event.occupant and event.occupant.bare_jid or event.bare_jid;
	local aff_data = event.room:get_affiliation_data(bare_jid);
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
