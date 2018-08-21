local st = require "util.stanza"
local jid_split = require "util.jid".split;

local mod_pep = module:depends("pep");

module:add_feature("vcard-temp");
module:add_feature("urn:xmpp:pep-vcard-conversion:0");

-- Simple translations
-- <foo><text>hey</text></foo> -> <FOO>hey</FOO>
local simple_map = {
	nickname = "text";
	title = "text";
	role = "text";
	categories = "text";
	note = "text";
	url = "uri";
	bday = "date";
}

module:hook("iq-get/bare/vcard-temp:vCard", function (event)
	local origin, stanza = event.origin, event.stanza;
	local pep_service = mod_pep.get_pep_service(jid_split(stanza.attr.to) or origin.username);
	local ok, id, vcard4_item = pep_service:get_last_item("urn:xmpp:vcard4", stanza.attr.from);

	local vcard_temp = st.stanza("vCard", { xmlns = "vcard-temp" });
	if ok and vcard4_item then
		local vcard4 = vcard4_item.tags[1];

		local fn = vcard4:get_child("fn");
		vcard_temp:text_tag("FN", fn and fn:get_child_text("text"));

		local v4n = vcard4:get_child("n");
		vcard_temp:tag("N")
			:text_tag("FAMILY", v4n and v4n:get_child_text("surname"))
			:text_tag("GIVEN", v4n and v4n:get_child_text("given"))
			:text_tag("MIDDLE", v4n and v4n:get_child_text("additional"))
			:text_tag("PREFIX", v4n and v4n:get_child_text("prefix"))
			:text_tag("SUFFIX", v4n and v4n:get_child_text("suffix"))
			:up();

		for tag in vcard4:childtags() do
			local typ = simple_map[tag.name];
			if typ then
				local text = tag:get_child_text(typ);
				if text then
					vcard_temp:text_tag(tag.name:upper(), text);
				end
			elseif tag.name == "email" then
				local text = tag:get_child_text("text");
				if text then
					vcard_temp:tag("EMAIL")
						:text_tag("USERID", text)
						:tag("INTERNET"):up();
					if tag:find"parameters/type/text#" == "home" then
						vcard_temp:tag("HOME"):up();
					elseif tag:find"parameters/type/text#" == "work" then
						vcard_temp:tag("WORK"):up();
					end
					vcard_temp:up();
				end
			elseif tag.name == "tel" then
				local text = tag:get_child_text("uri");
				if text then
					if text:sub(1, 4) == "tel:" then
						text = text:sub(5)
					end
					vcard_temp:tag("TEL"):text_tag("NUMBER", text);
					if tag:find"parameters/type/text#" == "home" then
						vcard_temp:tag("HOME"):up();
					elseif tag:find"parameters/type/text#" == "work" then
						vcard_temp:tag("WORK"):up();
					end
					vcard_temp:up();
				end
			elseif tag.name == "adr" then
				vcard_temp:tag("ADR")
					:text_tag("POBOX", tag:get_child_text("pobox"))
					:text_tag("EXTADD", tag:get_child_text("ext"))
					:text_tag("STREET", tag:get_child_text("street"))
					:text_tag("LOCALITY", tag:get_child_text("locality"))
					:text_tag("REGION", tag:get_child_text("region"))
					:text_tag("PCODE", tag:get_child_text("code"))
					:text_tag("CTRY", tag:get_child_text("country"));
				if tag:find"parameters/type/text#" == "home" then
					vcard_temp:tag("HOME"):up();
				elseif tag:find"parameters/type/text#" == "work" then
					vcard_temp:tag("WORK"):up();
				end
				vcard_temp:up();
			end
		end
	end

	local meta_ok, avatar_meta = pep_service:get_items("urn:xmpp:avatar:metadata", stanza.attr.from);
	local data_ok, avatar_data = pep_service:get_items("urn:xmpp:avatar:data", stanza.attr.from);
	if meta_ok and data_ok then
		for _, hash in ipairs(avatar_meta) do
			local meta = avatar_meta[hash];
			local data = avatar_data[hash];
			local info = meta.tags[1]:get_child("info");
			vcard_temp:tag("PHOTO")
				:text_tag("TYPE", info and info.attr.type)
				:text_tag("BINVAL", data.tags[1]:get_text())
				:up();
		end
	end

	origin.send(st.reply(stanza):add_child(vcard_temp));
	return true;
end);

local function inject_xep153(event)
	local origin, stanza = event.origin, event.stanza;
	local username = origin.username;
	if not username then return end
	local pep = mod_pep.get_pep_service(username);

	stanza:remove_children("x", "vcard-temp:x:update");
	local x_update = st.stanza("x", { xmlns = "vcard-temp:x:update" });
	local ok, avatar_hash = pep:get_last_item("urn:xmpp:avatar:metadata", true);
	if ok and avatar_hash then
		x_update:text_tag("photo", avatar_hash);
	end
	stanza:add_direct_child(x_update);
end

module:hook("pre-presence/full", inject_xep153, 1);
module:hook("pre-presence/bare", inject_xep153, 1);
module:hook("pre-presence/host", inject_xep153, 1);
