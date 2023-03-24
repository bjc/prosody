local st = require "prosody.util.stanza";
local jid_split = require "prosody.util.jid".split;

local mod_pep = module:depends("pep");

local sha1 = require "prosody.util.hashes".sha1;
local base64_decode = require "prosody.util.encodings".base64.decode;

local vcards = module:open_store("vcard");

module:add_feature("vcard-temp");
module:hook("account-disco-info", function (event)
	event.reply:tag("feature", { var = "urn:xmpp:pep-vcard-conversion:0" }):up();
end);

local function handle_error(origin, stanza, err)
	if err == "forbidden" then
		origin.send(st.error_reply(stanza, "auth", "forbidden"));
	elseif err == "internal-server-error" then
		origin.send(st.error_reply(stanza, "wait", "internal-server-error"));
	else
		origin.send(st.error_reply(stanza, "modify", "undefined-condition", err));
	end
end

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
	local ok, _, vcard4_item = pep_service:get_last_item("urn:xmpp:vcard4", stanza.attr.from);

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
			elseif tag.name == "impp" then
				local uri = tag:get_child_text("uri");
				if uri and uri:sub(1, 5) == "xmpp:" then
					vcard_temp:text_tag("JABBERID", uri:sub(6))
				end
			elseif tag.name == "org" then
				vcard_temp:tag("ORG")
					:text_tag("ORGNAME", tag:get_child_text("text"))
				:up();
			end
		end
	else
		local ok, _, nick_item = pep_service:get_last_item("http://jabber.org/protocol/nick", stanza.attr.from);
		if ok and nick_item then
			local nickname = nick_item:get_child_text("nick", "http://jabber.org/protocol/nick");
			if nickname then
				vcard_temp:text_tag("NICKNAME", nickname);
			end
		end
	end

	local ok, avatar_hash, meta = pep_service:get_last_item("urn:xmpp:avatar:metadata", stanza.attr.from);
	if ok and avatar_hash then

		local info = meta.tags[1]:get_child("info");
		if info then
			vcard_temp:tag("PHOTO");

			if info.attr.type then
				vcard_temp:text_tag("TYPE", info.attr.type);
			end

			if info.attr.url then
				vcard_temp:text_tag("EXTVAL", info.attr.url);
			elseif info.attr.id then
				local data_ok, avatar_data = pep_service:get_items("urn:xmpp:avatar:data", stanza.attr.from, { info.attr.id });
				if data_ok and avatar_data and avatar_data[info.attr.id]  then
					local data = avatar_data[info.attr.id];
					vcard_temp:text_tag("BINVAL", data.tags[1]:get_text());
				end
			end
			vcard_temp:up();
		end
	end

	origin.send(st.reply(stanza):add_child(vcard_temp));
	return true;
end);

local node_defaults = {
	access_model = "open";
	_defaults_only = true;
};

function vcard_to_pep(vcard_temp)
	local avatar = {};

	local vcard4 = st.stanza("item", { xmlns = "http://jabber.org/protocol/pubsub", id = "current" })
		:tag("vcard", { xmlns = 'urn:ietf:params:xml:ns:vcard-4.0' });

	vcard4:tag("fn"):text_tag("text", vcard_temp:get_child_text("FN")):up();

	local N = vcard_temp:get_child("N");

	vcard4:tag("n")
		:text_tag("surname", N and N:get_child_text("FAMILY"))
		:text_tag("given", N and N:get_child_text("GIVEN"))
		:text_tag("additional", N and N:get_child_text("MIDDLE"))
		:text_tag("prefix", N and N:get_child_text("PREFIX"))
		:text_tag("suffix", N and N:get_child_text("SUFFIX"))
	:up();

	for tag in vcard_temp:childtags() do
		local typ = simple_map[tag.name:lower()];
		if typ then
			local text = tag:get_text();
			if text then
				vcard4:tag(tag.name:lower()):text_tag(typ, text):up();
			end
		elseif tag.name == "EMAIL" then
			local text = tag:get_child_text("USERID");
			if text then
				vcard4:tag("email")
				vcard4:text_tag("text", text)
				vcard4:tag("parameters"):tag("type");
				if tag:get_child("HOME") then
					vcard4:text_tag("text", "home");
				elseif tag:get_child("WORK") then
					vcard4:text_tag("text", "work");
				end
				vcard4:up():up():up();
			end
		elseif tag.name == "TEL" then
			local text = tag:get_child_text("NUMBER");
			if text then
				vcard4:tag("tel"):text_tag("uri", "tel:"..text);
			end
			vcard4:tag("parameters"):tag("type");
			if tag:get_child("HOME") then
				vcard4:text_tag("text", "home");
			elseif tag:get_child("WORK") then
				vcard4:text_tag("text", "work");
			end
			vcard4:up():up():up();
		elseif tag.name == "ORG" then
			local text = tag:get_child_text("ORGNAME");
			if text then
				vcard4:tag("org"):text_tag("text", text):up();
			end
		elseif tag.name == "DESC" then
			local text = tag:get_text();
			if text then
				vcard4:tag("note"):text_tag("text", text):up();
			end
			-- <note> gets mapped into <NOTE> in the other direction
		elseif tag.name == "ADR" then
			vcard4:tag("adr")
				:text_tag("pobox", tag:get_child_text("POBOX"))
				:text_tag("ext", tag:get_child_text("EXTADD"))
				:text_tag("street", tag:get_child_text("STREET"))
				:text_tag("locality", tag:get_child_text("LOCALITY"))
				:text_tag("region", tag:get_child_text("REGION"))
				:text_tag("code", tag:get_child_text("PCODE"))
				:text_tag("country", tag:get_child_text("CTRY"));
			vcard4:tag("parameters"):tag("type");
			if tag:get_child("HOME") then
				vcard4:text_tag("text", "home");
			elseif tag:get_child("WORK") then
				vcard4:text_tag("text", "work");
			end
			vcard4:up():up():up();
		elseif tag.name == "JABBERID" then
			vcard4:tag("impp")
				:text_tag("uri", "xmpp:" .. tag:get_text())
			:up();
		elseif tag.name == "PHOTO" then
			local avatar_type = tag:get_child_text("TYPE");
			local avatar_payload = tag:get_child_text("BINVAL");
			-- Can EXTVAL be translated? No way to know the sha1 of the data?

			if avatar_payload then
				local avatar_raw = base64_decode(avatar_payload);
				local avatar_hash = sha1(avatar_raw, true);

				avatar.hash = avatar_hash;

				avatar.meta = st.stanza("item", { id = avatar_hash, xmlns = "http://jabber.org/protocol/pubsub" })
					:tag("metadata", { xmlns="urn:xmpp:avatar:metadata" })
						:tag("info", {
							bytes = tostring(#avatar_raw),
							id = avatar_hash,
							type = avatar_type,
						});

				avatar.data = st.stanza("item", { id = avatar_hash, xmlns = "http://jabber.org/protocol/pubsub" })
					:tag("data", { xmlns="urn:xmpp:avatar:data" })
						:text(avatar_payload);

			end
		end
	end
	return vcard4, avatar;
end

function save_to_pep(pep_service, actor, vcard4, avatar)
	if avatar then

		if pep_service:purge("urn:xmpp:avatar:metadata", actor) then
			pep_service:purge("urn:xmpp:avatar:data", actor);
		end

		if avatar.data and avatar.meta then
			local ok, err = assert(pep_service:publish("urn:xmpp:avatar:data", actor, avatar.hash, avatar.data, node_defaults));
			if ok then
				ok, err = assert(pep_service:publish("urn:xmpp:avatar:metadata", actor, avatar.hash, avatar.meta, node_defaults));
			end
			if not ok then
				return ok, err;
			end
		end
	end

	if vcard4 then
		return pep_service:publish("urn:xmpp:vcard4", actor, "current", vcard4, node_defaults);
	end

	return true;
end

module:hook("iq-set/self/vcard-temp:vCard", function (event)
	local origin, stanza = event.origin, event.stanza;
	local pep_service = mod_pep.get_pep_service(origin.username);

	local vcard_temp = stanza.tags[1];

	local ok, err = save_to_pep(pep_service, origin.full_jid, vcard_to_pep(vcard_temp));
	if ok then
		origin.send(st.reply(stanza));
	else
		handle_error(origin, stanza, err);
	end

	return true;
end);

local function inject_xep153(event)
	local origin, stanza = event.origin, event.stanza;
	local username = origin.username;
	if not username then return end
	if stanza.attr.type then return end
	local pep_service = mod_pep.get_pep_service(username);

	local x_update = stanza:get_child("x", "vcard-temp:x:update");
	if not x_update then
		x_update = st.stanza("x", { xmlns = "vcard-temp:x:update" }):tag("photo");
		stanza:add_direct_child(x_update);
	elseif x_update:get_child("photo") then
		return; -- XEP implies that these should be left alone
	else
		x_update:tag("photo");
	end
	local ok, avatar_hash = pep_service:get_last_item("urn:xmpp:avatar:metadata", true);
	if ok and avatar_hash then
		x_update:text(avatar_hash);
	end
end

module:hook("pre-presence/full", inject_xep153, 1);
module:hook("pre-presence/bare", inject_xep153, 1);
module:hook("pre-presence/host", inject_xep153, 1);

if module:get_option_boolean("upgrade_legacy_vcards", true) then
module:hook("resource-bind", function (event)
	local session = event.session;
	local username = session.username;
	local vcard_temp = vcards:get(username);
	if not vcard_temp then
		session.log("debug", "No legacy vCard to migrate or already migrated");
		return;
	end
	local pep_service = mod_pep.get_pep_service(username);
	vcard_temp = st.deserialize(vcard_temp);
	local vcard4, avatars = vcard_to_pep(vcard_temp);
	if pep_service:get_last_item("urn:xmpp:vcard4", true) then
		vcard4 = nil;
	end
	if pep_service:get_last_item("urn:xmpp:avatar:metadata", true)
	or pep_service:get_last_item("urn:xmpp:avatar:data", true) then
		avatars = nil;
	end
	if not (vcard4 or avatars) then
		session.log("debug", "Already PEP data, not overwriting with migrated data");
		vcards:set(username, nil);
		return;
	end
	local ok, err = save_to_pep(pep_service, true, vcard4, avatars);
	if ok and vcards:set(username, nil) then
		session.log("info", "Migrated vCard-temp to PEP");
	else
		session.log("info", "Failed to migrate vCard-temp to PEP: %s", err or "problem emptying 'vcard' store");
	end
end);
end
