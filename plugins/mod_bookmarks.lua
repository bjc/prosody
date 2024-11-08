local mm = require "prosody.core.modulemanager";
if mm.get_modules_for_host(module.host):contains("bookmarks2") then
	error("mod_bookmarks and mod_bookmarks2 are conflicting, please disable one of them.", 0);
end

local st = require "prosody.util.stanza";
local jid_split = require "prosody.util.jid".split;

local mod_pep = module:depends "pep";
local private_storage = module:open_store("private", "map");

local namespace = "urn:xmpp:bookmarks:1";
local namespace_old = "urn:xmpp:bookmarks:0";
local namespace_private = "jabber:iq:private";
local namespace_legacy = "storage:bookmarks";
local xmlns_pubsub = "http://jabber.org/protocol/pubsub";

local default_options = {
	["persist_items"] = true;
	["max_items"] = "max";
	["send_last_published_item"] = "never";
	["access_model"] = "whitelist";
};

module:hook("account-disco-info", function (event)
	-- This Time it’s Serious!
	event.reply:tag("feature", { var = namespace.."#compat" }):up();
	event.reply:tag("feature", { var = namespace.."#compat-pep" }):up();

	-- COMPAT XEP-0411
	event.reply:tag("feature", { var = "urn:xmpp:bookmarks-conversion:0" }):up();
end);

-- This must be declared on the domain JID, not the account JID.  Note that
-- this isn’t defined in the XEP.
module:add_feature(namespace_private);


local function generate_legacy_storage(items)
	local storage = st.stanza("storage", { xmlns = namespace_legacy });
	for _, item_id in ipairs(items) do
		local item = items[item_id];
		local bookmark = item:get_child("conference", namespace);
		if not bookmark then
			module:log("warn", "Invalid bookmark published: expected {%s}conference, got {%s}%s", namespace,

				item.tags[1] and item.tags[1].attr.xmlns, item.tags[1] and item.tags[1].name);
		end
		local conference = st.stanza("conference", {
			jid = item.attr.id,
			name = bookmark and bookmark.attr.name,
			autojoin = bookmark and bookmark.attr.autojoin,
		});
		local nick = bookmark and bookmark:get_child_text("nick");
		if nick ~= nil then
			conference:text_tag("nick", nick):up();
		end
		local password = bookmark and bookmark:get_child_text("password");
		if password ~= nil then
			conference:text_tag("password", password):up();
		end
		storage:add_child(conference);
	end

	return storage;
end

local function on_retrieve_legacy_pep(event)
	local stanza, session = event.stanza, event.origin;
	local pubsub = stanza:get_child("pubsub", "http://jabber.org/protocol/pubsub");
	if pubsub == nil then
		return;
	end

	local items = pubsub:get_child("items");
	if items == nil then
		return;
	end

	local node = items.attr.node;
	if node ~= namespace_legacy then
		return;
	end

	local username = session.username;
	local jid = username.."@"..session.host;
	local service = mod_pep.get_pep_service(username);
	local ok, ret = service:get_items(namespace, session.full_jid);
	if not ok then
		if ret == "item-not-found" then
			module:log("debug", "Got no PEP bookmarks item for %s, returning empty private bookmarks", jid);
		else
			module:log("error", "Failed to retrieve PEP bookmarks of %s: %s", jid, ret);
		end
		session.send(st.error_reply(stanza, "cancel", ret, "Failed to retrieve bookmarks from PEP"));
		return true;
	end

	local storage = generate_legacy_storage(ret);

	module:log("debug", "Sending back legacy PEP for %s: %s", jid, storage);
	session.send(st.reply(stanza)
		:tag("pubsub", {xmlns = "http://jabber.org/protocol/pubsub"})
			:tag("items", {node = namespace_legacy})
				:tag("item", {id = "current"})
					:add_child(storage));
	return true;
end

local function on_retrieve_private_xml(event)
	local stanza, session = event.stanza, event.origin;
	local query = stanza:get_child("query", namespace_private);
	if query == nil then
		return;
	end

	local bookmarks = query:get_child("storage", namespace_legacy);
	if bookmarks == nil then
		return;
	end

	module:log("debug", "Getting private bookmarks: %s", bookmarks);

	local username = session.username;
	local jid = username.."@"..session.host;
	local service = mod_pep.get_pep_service(username);
	local ok, ret = service:get_items(namespace, session.full_jid);
	if not ok then
		if ret == "item-not-found" then
			module:log("debug", "Got no PEP bookmarks item for %s, returning empty private bookmarks", jid);
			session.send(st.reply(stanza):add_child(query));
		else
			module:log("error", "Failed to retrieve PEP bookmarks of %s: %s", jid, ret);
			session.send(st.error_reply(stanza, "cancel", ret, "Failed to retrieve bookmarks from PEP"));
		end
		return true;
	end

	local storage = generate_legacy_storage(ret);

	module:log("debug", "Sending back private for %s: %s", jid, storage);
	session.send(st.reply(stanza):query(namespace_private):add_child(storage));
	return true;
end

local function compare_bookmark2(a, b)
	if a == nil or b == nil then
		return false;
	end
	local a_conference = a:get_child("conference", namespace);
	local b_conference = b:get_child("conference", namespace);
	local a_nick = a_conference:get_child_text("nick");
	local b_nick = b_conference:get_child_text("nick");
	local a_password = a_conference:get_child_text("password");
	local b_password = b_conference:get_child_text("password");
	return (a.attr.id == b.attr.id and
	        a_conference.attr.name == b_conference.attr.name and
	        a_conference.attr.autojoin == b_conference.attr.autojoin and
	        a_nick == b_nick and
	        a_password == b_password);
end

local function publish_to_pep(jid, bookmarks, synchronise)
	local service = mod_pep.get_pep_service(jid_split(jid));

	if #bookmarks.tags == 0 then
		if synchronise then
			-- If we set zero legacy bookmarks, purge the bookmarks 2 node.
			module:log("debug", "No bookmark in the set, purging instead.");
			local ok, err = service:purge(namespace, jid, true);
			-- It's okay if no node exists when purging, user has
			-- no bookmarks anyway.
			if not ok and err ~= "item-not-found" then
				module:log("error", "Failed to clear items from bookmarks 2 node: %s", err);
				return ok, err;
			end
		end
		return true;
	end

	-- Retrieve the current bookmarks2.
	module:log("debug", "Retrieving the current bookmarks 2.");
	local has_bookmarks2, ret = service:get_items(namespace, jid);
	local bookmarks2;
	if not has_bookmarks2 and ret == "item-not-found" then
		module:log("debug", "Got item-not-found, assuming it was empty until now, creating.");
		local ok, err = service:create(namespace, jid, default_options);
		if not ok then
			module:log("error", "Creating bookmarks 2 node failed: %s", err);
			return ok, err;
		end
		bookmarks2 = {};
	elseif not has_bookmarks2 then
		module:log("debug", "Got %s error, aborting.", ret);
		return false, ret;
	else
		module:log("debug", "Got existing bookmarks2.");
		bookmarks2 = ret;

		local ok, err = service:get_node_config(namespace, jid);
		if not ok then
			module:log("error", "Retrieving bookmarks 2 node config failed: %s", err);
			return ok, err;
		end

		local options = err;
		for key, value in pairs(default_options) do
			if options[key] and options[key] ~= value then
				module:log("warn", "Overriding bookmarks 2 configuration for %s, from %s to %s", jid, options[key], value);
				options[key] = value;
			end
		end

		local ok, err = service:set_node_config(namespace, jid, options);
		if not ok then
			module:log("error", "Setting bookmarks 2 node config failed: %s", err);
			return ok, err;
		end
	end

	-- Get a list of all items we may want to remove.
	local to_remove = {};
	for i in ipairs(bookmarks2) do
		to_remove[bookmarks2[i]] = true;
	end

	for bookmark in bookmarks:childtags("conference", namespace_legacy) do
		-- Create the new conference element by copying everything from the legacy one.
		local conference = st.stanza("conference", {
			xmlns = namespace,
			name = bookmark.attr.name,
			autojoin = bookmark.attr.autojoin,
		});
		local nick = bookmark:get_child_text("nick");
		if nick ~= nil then
			conference:text_tag("nick", nick):up();
		end
		local password = bookmark:get_child_text("password");
		if password ~= nil then
			conference:text_tag("password", password):up();
		end

		-- Create its wrapper.
		local item = st.stanza("item", { xmlns = "http://jabber.org/protocol/pubsub", id = bookmark.attr.jid })
			:add_child(conference);

		-- Then publish it only if it’s a new one or updating a previous one.
		if compare_bookmark2(item, bookmarks2[bookmark.attr.jid]) then
			module:log("debug", "Item %s identical to the previous one, skipping.", item.attr.id);
			to_remove[bookmark.attr.jid] = nil;
		else
			if bookmarks2[bookmark.attr.jid] == nil then
				module:log("debug", "Item %s not existing previously, publishing.", item.attr.id);
			else
				module:log("debug", "Item %s different from the previous one, publishing.", item.attr.id);
				to_remove[bookmark.attr.jid] = nil;
			end
			local ok, err = service:publish(namespace, jid, bookmark.attr.jid, item, default_options);
			if not ok then
				module:log("error", "Publishing item %s failed: %s", item.attr.id, err);
				return ok, err;
			end
		end
	end

	-- Now handle retracting items that have been removed.
	if synchronise then
		for id in pairs(to_remove) do
			module:log("debug", "Item %s removed from bookmarks.", id);
			local ok, err = service:retract(namespace, jid, id, st.stanza("retract", { id = id }));
			if not ok then
				module:log("error", "Retracting item %s failed: %s", id, err);
				return ok, err;
			end
		end
	end
	return true;
end

-- Synchronise legacy PEP to PEP.
local function on_publish_legacy_pep(event)
	local stanza, session = event.stanza, event.origin;
	local pubsub = stanza:get_child("pubsub", "http://jabber.org/protocol/pubsub");
	if pubsub == nil then
		return;
	end

	local publish = pubsub:get_child("publish");
	if publish == nil then return end
	if publish.attr.node == namespace_old then
		session.send(st.error_reply(stanza, "modify", "not-allowed",
			"Your client does XEP-0402 version 0.3.0 but 0.4.0+ is required"));
		return true;
	end
	if publish.attr.node ~= namespace_legacy then
		return;
	end

	local item = publish:get_child("item");
	if item == nil then
		return;
	end

	-- Here we ignore the item id, it’ll be generated as 'current' anyway.

	local bookmarks = item:get_child("storage", namespace_legacy);
	if bookmarks == nil then
		return;
	end

	-- We also ignore the publish-options.

	module:log("debug", "Legacy PEP bookmarks set by client, publishing to PEP.");

	local ok, err = publish_to_pep(session.full_jid, bookmarks, true);
	if not ok then
		module:log("error", "Failed to sync legacy bookmarks to PEP for %s@%s: %s", session.username, session.host, err);
		session.send(st.error_reply(stanza, "cancel", "internal-server-error", "Failed to store bookmarks to PEP"));
		return true;
	end

	session.send(st.reply(stanza));
	return true;
end

-- Synchronise Private XML to PEP.
local function on_publish_private_xml(event)
	local stanza, session = event.stanza, event.origin;
	local query = stanza:get_child("query", namespace_private);
	if query == nil then
		return;
	end

	local bookmarks = query:get_child("storage", namespace_legacy);
	if bookmarks == nil then
		return;
	end

	module:log("debug", "Private bookmarks set by client, publishing to PEP.");

	local ok, err = publish_to_pep(session.full_jid, bookmarks, true);
	if not ok then
		module:log("error", "Failed to sync private XML bookmarks to PEP for %s@%s: %s", session.username, session.host, err);
		session.send(st.error_reply(stanza, "cancel", "internal-server-error", "Failed to store bookmarks to PEP"));
		return true;
	end

	session.send(st.reply(stanza));
	return true;
end

local function migrate_legacy_bookmarks(event)
	local session = event.session;
	local username = session.username;
	local service = mod_pep.get_pep_service(username);
	local jid = username.."@"..session.host;

	local ok, ret = service:get_items(namespace_legacy, session.full_jid);
	if ok and ret[1] then
		module:log("debug", "Legacy PEP bookmarks found for %s, migrating.", jid);
		local failed = false;
		for _, item_id in ipairs(ret) do
			local item = ret[item_id];
			if item.attr.id ~= "current" then
				module:log("warn", "Legacy PEP bookmarks for %s isn’t using 'current' as its id: %s", jid, item.attr.id);
			end
			local bookmarks = item:get_child("storage", namespace_legacy);
			module:log("debug", "Got legacy PEP bookmarks of %s: %s", jid, bookmarks);

			local ok, err = publish_to_pep(session.full_jid, bookmarks, false);
			if not ok then
				module:log("error", "Failed to store legacy PEP bookmarks to bookmarks 2 for %s, aborting migration: %s", jid, err);
				failed = true;
				break;
			end
		end
		if not failed then
			module:log("debug", "Successfully migrated legacy PEP bookmarks of %s to bookmarks 2, clearing items.", jid);
			local ok, err = service:purge(namespace_legacy, jid, false);
			if not ok then
				module:log("error", "Failed to delete legacy PEP bookmarks for %s: %s", jid, err);
			end
		end
	end

	local ok, current_legacy_config = service:get_node_config(namespace_legacy, jid);
	if not ok or current_legacy_config["access_model"] ~= "whitelist" then
		-- The legacy node must exist in order for the access model to apply to the
		-- XEP-0411 COMPAT broadcasts (which bypass the pubsub service entirely),
		-- so create or reconfigure it to be useless.
		--
		-- FIXME It would be handy to have a publish model that prevents the owner
		-- from publishing, but the affiliation takes priority
		local config = {
			["persist_items"] = false;
			["max_items"] = 1;
			["send_last_published_item"] = "never";
			["access_model"] = "whitelist";
		};
		local ok, err;
		if ret == "item-not-found" then
			ok, err = service:create(namespace_legacy, jid, config);
		else
			ok, err = service:set_node_config(namespace_legacy, jid, config);
		end
		if not ok then
			module:log("error", "Setting legacy bookmarks node config failed: %s", err);
			return ok, err;
		end
	end

	local data, err = private_storage:get(username, "storage:storage:bookmarks");
	if not data then
		module:log("debug", "No existing legacy bookmarks for %s, migration already done: %s", jid, err);
		local ok, ret2 = service:get_items(namespace, session.full_jid);
		if not ok or not ret2 then
			module:log("debug", "Additionally, no bookmarks 2 were existing for %s, assuming empty.", jid);
			module:fire_event("bookmarks/empty", { session = session });
		end
		return;
	end
	local bookmarks = st.deserialize(data);
	module:log("debug", "Got legacy bookmarks of %s: %s", jid, bookmarks);

	module:log("debug", "Going to store legacy bookmarks to bookmarks 2 %s.", jid);
	local ok, err = publish_to_pep(session.full_jid, bookmarks, false);
	if not ok then
		module:log("error", "Failed to store legacy bookmarks to bookmarks 2 for %s, aborting migration: %s", jid, err);
		return;
	end
	module:log("debug", "Stored legacy bookmarks to bookmarks 2 for %s.", jid);

	local ok, err = private_storage:set(username, "storage:storage:bookmarks", nil);
	if not ok then
		module:log("error", "Failed to remove legacy bookmarks of %s: %s", jid, err);
		return;
	end
	module:log("debug", "Removed legacy bookmarks of %s, migration done!", jid);
end

module:hook("iq/bare/jabber:iq:private:query", function (event)
	if event.stanza.attr.type == "get" then
		return on_retrieve_private_xml(event);
	else
		return on_publish_private_xml(event);
	end
end, 1);
module:hook("iq/bare/http://jabber.org/protocol/pubsub:pubsub", function (event)
	if event.stanza.attr.type == "get" then
		return on_retrieve_legacy_pep(event);
	else
		return on_publish_legacy_pep(event);
	end
end, 1);
if module:get_option_boolean("upgrade_legacy_bookmarks", true) then
	module:hook("resource-bind", migrate_legacy_bookmarks);
end
-- COMPAT XEP-0411 Broadcast as per XEP-0048 + PEP
local function legacy_broadcast(event)
	local service = event.service;
	local ok, bookmarks = service:get_items(namespace, event.actor);
	if bookmarks == "item-not-found" then ok, bookmarks = true, {} end
	if not ok then return end
	local legacy_bookmarks_item = st.stanza("item", { xmlns = xmlns_pubsub; id = "current" })
		:add_child(generate_legacy_storage(bookmarks));
	service:broadcast("items", namespace_legacy, { --[[ no subscribers ]] }, legacy_bookmarks_item, event.actor);
end
local function broadcast_legacy_removal(event)
	if event.node ~= namespace then return end
	return legacy_broadcast(event);
end
module:hook("presence/initial", function (event)
	-- Broadcasts to all clients with legacy+notify, not just the one coming online.
	-- Upgrade to XEP-0402 to avoid it
	local service = mod_pep.get_pep_service(event.origin.username);
	legacy_broadcast({ service = service, actor = event.origin.full_jid });
end);
module:handle_items("pep-service", function (event)
	local service = event.item.service;
	module:hook_object_event(service.events, "item-published/" .. namespace, legacy_broadcast);
	module:hook_object_event(service.events, "item-retracted", broadcast_legacy_removal);
	module:hook_object_event(service.events, "node-purged", broadcast_legacy_removal);
	module:hook_object_event(service.events, "node-deleted", broadcast_legacy_removal);
end, function (event)
	local service = event.item.service;
	module:unhook_object_event(service.events, "item-published/" .. namespace, legacy_broadcast);
	module:unhook_object_event(service.events, "item-retracted", broadcast_legacy_removal);
	module:unhook_object_event(service.events, "node-purged", broadcast_legacy_removal);
	module:unhook_object_event(service.events, "node-deleted", broadcast_legacy_removal);
end, true);
