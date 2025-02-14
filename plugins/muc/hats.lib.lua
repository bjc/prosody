local st = require "prosody.util.stanza";
local muc_util = module:require "muc/util";

local hats_compat = module:get_option_boolean("muc_hats_compat", false); -- COMPAT for pre-XEP namespace

local xmlns_hats_legacy = "xmpp:prosody.im/protocol/hats:1";
local xmlns_hats = "urn:xmpp:hats:0";

-- Strip any hats claimed by the client (to prevent spoofing)
muc_util.add_filtered_namespace(xmlns_hats);


module:hook("muc-build-occupant-presence", function (event)
	local bare_jid = event.occupant and event.occupant.bare_jid or event.bare_jid;
	local aff_data = event.room:get_affiliation_data(bare_jid);
	local hats = aff_data and aff_data.hats;
	if not hats then return; end
	local hats_el;
	local legacy_hats_el;
	for hat_id, hat_data in pairs(hats) do
		if hat_data.active then
			if not hats_el then
				hats_el = st.stanza("hats", { xmlns = xmlns_hats });
			end
			hats_el:tag("hat", { uri = hat_id, title = hat_data.title }):up();

			if hats_compat then
				if not legacy_hats_el then
					legacy_hats_el = st.stanza("hats", { xmlns = xmlns_hats_legacy });
				end
				legacy_hats_el:tag("hat", { uri = hat_id, title = hat_data.title }):up();
			end
		end
	end
	if not hats_el then return; end
	event.stanza:add_direct_child(hats_el);

	if legacy_hats_el then
		event.stanza:add_direct_child(legacy_hats_el);
	end
end);
