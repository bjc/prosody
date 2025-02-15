-- XEP-0357: Push (aka: My mobile OS vendor won't let me have persistent TCP connections)
-- Copyright (C) 2015-2016 Kim Alvefur
-- Copyright (C) 2017-2019 Thilo Molitor
--
-- This file is MIT/X11 licensed.

local os_time = os.time;
local st = require"prosody.util.stanza";
local jid = require"prosody.util.jid";
local dataform = require"prosody.util.dataforms".new;
local hashes = require"prosody.util.hashes";
local random = require"prosody.util.random";
local cache = require"prosody.util.cache";
local watchdog = require "prosody.util.watchdog";

local xmlns_push = "urn:xmpp:push:0";

-- configuration
local include_body = module:get_option_boolean("push_notification_with_body", false);
local include_sender = module:get_option_boolean("push_notification_with_sender", false);
local max_push_errors = module:get_option_number("push_max_errors", 16);
local max_push_devices = module:get_option_number("push_max_devices", 5);
local dummy_body = module:get_option_string("push_notification_important_body", "New Message!");
local extended_hibernation_timeout = module:get_option_number("push_max_hibernation_timeout", 72*3600);  -- use same timeout like ejabberd

local host_sessions = prosody.hosts[module.host].sessions;
local push_errors = module:shared("push_errors");
local id2node = {};
local id2identifier = {};

-- For keeping state across reloads while caching reads
-- This uses util.cache for caching the most recent devices and removing all old devices when max_push_devices is reached
local push_store = (function()
	local store = module:open_store();
	local push_services = {};
	local api = {};
	--luacheck: ignore 212/self
	function api:get(user)
		if not push_services[user] then
			local loaded, err = store:get(user);
			if not loaded and err then
				module:log("warn", "Error reading push notification storage for user '%s': %s", user, tostring(err));
				push_services[user] = cache.new(max_push_devices):table();
				return push_services[user], false;
			end
			if loaded then
				push_services[user] = cache.new(max_push_devices):table();
				-- copy over plain table loaded from disk into our cache
				for k, v in pairs(loaded) do push_services[user][k] = v; end
			else
				push_services[user] = cache.new(max_push_devices):table();
			end
		end
		return push_services[user], true;
	end
	function api:flush_to_disk(user)
		local plain_table = {};
		for k, v in pairs(push_services[user]) do plain_table[k] = v; end
		local ok, err = store:set(user, plain_table);
		if not ok then
			module:log("error", "Error writing push notification storage for user '%s': %s", user, tostring(err));
			return false;
		end
		return true;
	end
	function api:set_identifier(user, push_identifier, data)
		local services = self:get(user);
		services[push_identifier] = data;
	end
	return api;
end)();


-- Forward declarations, as both functions need to reference each other
local handle_push_success, handle_push_error;

function handle_push_error(event)
	local stanza = event.stanza;
	local error_type, condition, error_text = stanza:get_error();
	local node = id2node[stanza.attr.id];
	local identifier = id2identifier[stanza.attr.id];
	if node == nil then
		module:log("warn", "Received push error with unrecognised id: %s", stanza.attr.id);
		return false; -- unknown stanza? Ignore for now!
	end
	local from = stanza.attr.from;
	local user_push_services = push_store:get(node);
	local found, changed = false, false;

	for push_identifier, _ in pairs(user_push_services) do
		if push_identifier == identifier then
			found = true;
			if user_push_services[push_identifier] and user_push_services[push_identifier].jid == from and error_type ~= "wait" then
				push_errors[push_identifier] = push_errors[push_identifier] + 1;
				module:log("info", "Got error <%s:%s:%s> for identifier '%s': "
					.."error count for this identifier is now at %s", error_type, condition, error_text or "", push_identifier,
					tostring(push_errors[push_identifier]));
				if push_errors[push_identifier] >= max_push_errors then
					module:log("warn", "Disabling push notifications for identifier '%s'", push_identifier);
					-- remove push settings from sessions
					if host_sessions[node] then
						for _, session in pairs(host_sessions[node].sessions) do
							if session.push_identifier == push_identifier then
								session.push_identifier = nil;
								session.push_settings = nil;
								session.first_hibernated_push = nil;
								-- check for prosody 0.12 mod_smacks
								if session.hibernating_watchdog and session.original_smacks_callback and session.original_smacks_timeout then
									-- restore old smacks watchdog
									session.hibernating_watchdog:cancel();
									session.hibernating_watchdog = watchdog.new(session.original_smacks_timeout, session.original_smacks_callback);
								end
							end
						end
					end
					-- save changed global config
					changed = true;
					user_push_services[push_identifier] = nil
					push_errors[push_identifier] = nil;
					-- unhook iq handlers for this identifier (if possible)
					module:unhook("iq-error/host/"..stanza.attr.id, handle_push_error);
					module:unhook("iq-result/host/"..stanza.attr.id, handle_push_success);
					id2node[stanza.attr.id] = nil;
					id2identifier[stanza.attr.id] = nil;
				end
			elseif user_push_services[push_identifier] and user_push_services[push_identifier].jid == from and error_type == "wait" then
				module:log("debug", "Got error <%s:%s:%s> for identifier '%s': "
					.."NOT increasing error count for this identifier", error_type, condition, error_text or "", push_identifier);
			else
				module:log("debug", "Unhandled push error <%s:%s:%s> from %s for identifier '%s'",
					error_type, condition, error_text or "", from, push_identifier
				);
			end
		end
	end
	if changed then
		push_store:flush_to_disk(node);
	elseif not found then
		module:log("warn", "Unable to find matching registration for push error <%s:%s:%s> from %s", error_type, condition, error_text or "", from);
	end
	return true;
end

function handle_push_success(event)
	local stanza = event.stanza;
	local node = id2node[stanza.attr.id];
	local identifier = id2identifier[stanza.attr.id];
	if node == nil then return false; end		-- unknown stanza? Ignore for now!
	local from = stanza.attr.from;
	local user_push_services = push_store:get(node);

	for push_identifier, _ in pairs(user_push_services) do
		if push_identifier == identifier then
			if user_push_services[push_identifier] and user_push_services[push_identifier].jid == from and push_errors[push_identifier] > 0 then
				push_errors[push_identifier] = 0;
				-- unhook iq handlers for this identifier (if possible)
				module:unhook("iq-error/host/"..stanza.attr.id, handle_push_error);
				module:unhook("iq-result/host/"..stanza.attr.id, handle_push_success);
				id2node[stanza.attr.id] = nil;
				id2identifier[stanza.attr.id] = nil;
				module:log("debug", "Push succeeded, error count for identifier '%s' is now at %s again",
					push_identifier, tostring(push_errors[push_identifier])
				);
			end
		end
	end
	return true;
end

-- http://xmpp.org/extensions/xep-0357.html#disco
local function account_dico_info(event)
	(event.reply or event.stanza):tag("feature", {var=xmlns_push}):up();
end
module:hook("account-disco-info", account_dico_info);

-- http://xmpp.org/extensions/xep-0357.html#enabling
local function push_enable(event)
	local origin, stanza = event.origin, event.stanza;
	local enable = stanza.tags[1];
	origin.log("debug", "Attempting to enable push notifications");
	-- MUST contain a 'jid' attribute of the XMPP Push Service being enabled
	local push_jid = enable.attr.jid;
	-- SHOULD contain a 'node' attribute
	local push_node = enable.attr.node;
	-- CAN contain a 'include_payload' attribute
	local include_payload = enable.attr.include_payload;
	if not push_jid then
		origin.log("debug", "Push notification enable request missing the 'jid' field");
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing jid"));
		return true;
	end
	if push_jid == stanza.attr.from then
		origin.log("debug", "Push notification enable request 'jid' field identical to our own");
		origin.send(st.error_reply(stanza, "modify", "bad-request", "JID must be different from ours"));
		return true;
	end
	local publish_options = enable:get_child("x", "jabber:x:data");
	if not publish_options then
		-- Could be intentional
		origin.log("debug", "No publish options in request");
	end
	local push_identifier = push_jid .. "<" .. (push_node or "");
	local push_service = {
		jid = push_jid;
		node = push_node;
		include_payload = include_payload;
		options = publish_options and st.preserialize(publish_options);
		timestamp = os_time();
		client_id = origin.client_id;
		resource = not origin.client_id and origin.resource or nil;
		language = stanza.attr["xml:lang"];
	};
	local allow_registration = module:fire_event("cloud_notify/registration", {
		origin = origin, stanza = stanza, push_info = push_service;
	});
	if allow_registration == false then
		return true; -- Assume error reply already sent
	end
	push_store:set_identifier(origin.username, push_identifier, push_service);
	local ok = push_store:flush_to_disk(origin.username);
	if not ok then
		origin.send(st.error_reply(stanza, "wait", "internal-server-error"));
	else
		origin.push_identifier = push_identifier;
		origin.push_settings = push_service;
		origin.first_hibernated_push = nil;
		origin.log("info", "Push notifications enabled for %s (%s)", tostring(stanza.attr.from), tostring(origin.push_identifier));
		origin.send(st.reply(stanza));
	end
	return true;
end
module:hook("iq-set/self/"..xmlns_push..":enable", push_enable);

-- http://xmpp.org/extensions/xep-0357.html#disabling
local function push_disable(event)
	local origin, stanza = event.origin, event.stanza;
	local push_jid = stanza.tags[1].attr.jid; -- MUST include a 'jid' attribute
	local push_node = stanza.tags[1].attr.node; -- A 'node' attribute MAY be included
	if not push_jid then
		origin.send(st.error_reply(stanza, "modify", "bad-request", "Missing jid"));
		return true;
	end
	local user_push_services = push_store:get(origin.username);
	for key, push_info in pairs(user_push_services) do
		if push_info.jid == push_jid and (not push_node or push_info.node == push_node) then
			origin.log("info", "Push notifications disabled (%s)", tostring(key));
			if origin.push_identifier == key then
				origin.push_identifier = nil;
				origin.push_settings = nil;
				origin.first_hibernated_push = nil;
				-- check for prosody 0.12 mod_smacks
				if origin.hibernating_watchdog and origin.original_smacks_callback and origin.original_smacks_timeout then
					-- restore old smacks watchdog
					origin.hibernating_watchdog:cancel();
					origin.hibernating_watchdog = watchdog.new(origin.original_smacks_timeout, origin.original_smacks_callback);
				end
			end
			user_push_services[key] = nil;
			push_errors[key] = nil;
			for stanza_id, identifier in pairs(id2identifier) do
				if identifier == key then
					module:unhook("iq-error/host/"..stanza_id, handle_push_error);
					module:unhook("iq-result/host/"..stanza_id, handle_push_success);
					id2node[stanza_id] = nil;
					id2identifier[stanza_id] = nil;
				end
			end
		end
	end
	local ok = push_store:flush_to_disk(origin.username);
	if not ok then
		origin.send(st.error_reply(stanza, "wait", "internal-server-error"));
	else
		origin.send(st.reply(stanza));
	end
	return true;
end
module:hook("iq-set/self/"..xmlns_push..":disable", push_disable);

-- urgent stanzas should be delivered without delay
local function is_urgent(stanza)
	-- TODO
	if stanza.name == "message" then
		if stanza:get_child("propose", "urn:xmpp:jingle-message:0") then
			return true, "jingle call";
		end
	end
end

-- is this push a high priority one (this is needed for ios apps not using voip pushes)
local function is_important(stanza)
	local st_name = stanza and stanza.name or nil;
	if not st_name then return false; end -- nonzas are never important here
	if st_name == "presence" then
		return false; -- same for presences
	elseif st_name == "message" then
		-- unpack carbon copied message stanzas
		local carbon = stanza:find("{urn:xmpp:carbons:2}/{urn:xmpp:forward:0}/{jabber:client}message");
		local stanza_direction = carbon and stanza:child_with_name("sent") and "out" or "in";
		if carbon then stanza = carbon; end
		local st_type = stanza.attr.type;

		-- headline message are always not important
		if st_type == "headline" then return false; end

		-- carbon copied outgoing messages are not important
		if carbon and stanza_direction == "out" then return false; end

		-- We can't check for body contents in encrypted messages, so let's treat them as important
		-- Some clients don't even set a body or an empty body for encrypted messages

		-- check omemo https://xmpp.org/extensions/inbox/omemo.html
		if stanza:get_child("encrypted", "eu.siacs.conversations.axolotl") or stanza:get_child("encrypted", "urn:xmpp:omemo:0") then return true; end

		-- check xep27 pgp https://xmpp.org/extensions/xep-0027.html
		if stanza:get_child("x", "jabber:x:encrypted") then return true; end

		-- check xep373 pgp (OX) https://xmpp.org/extensions/xep-0373.html
		if stanza:get_child("openpgp", "urn:xmpp:openpgp:0") then return true; end

		-- XEP-0353: Jingle Message Initiation (incoming call request)
		if stanza:get_child("propose", "urn:xmpp:jingle-message:0") then return true; end

		local body = stanza:get_child_text("body");

		-- groupchat subjects are not important here
		if st_type == "groupchat" and stanza:get_child_text("subject") then
			return false;
		end

		-- empty bodies are not important
		return body ~= nil and body ~= "";
	end
	return false;		-- this stanza wasn't one of the above cases --> it is not important, too
end

local push_form = dataform {
	{ name = "FORM_TYPE"; type = "hidden"; value = "urn:xmpp:push:summary"; };
	{ name = "message-count"; type = "text-single"; };
	{ name = "pending-subscription-count"; type = "text-single"; };
	{ name = "last-message-sender"; type = "jid-single"; };
	{ name = "last-message-body"; type = "text-single"; };
};

-- http://xmpp.org/extensions/xep-0357.html#publishing
local function handle_notify_request(stanza, node, user_push_services, log_push_decline)
	local pushes = 0;
	if not #user_push_services then return pushes end

	for push_identifier, push_info in pairs(user_push_services) do
		local send_push = true;		-- only send push to this node when not already done for this stanza or if no stanza is given at all
		if stanza then
			if not stanza._push_notify then stanza._push_notify = {}; end
			if stanza._push_notify[push_identifier] then
				if log_push_decline then
					module:log("debug", "Already sent push notification for %s@%s to %s (%s)", node, module.host, push_info.jid, tostring(push_info.node));
				end
				send_push = false;
			end
			stanza._push_notify[push_identifier] = true;
		end

		if send_push then
			-- construct push stanza
			local stanza_id = hashes.sha256(random.bytes(8), true);
			local push_notification_payload = st.stanza("notification", { xmlns = xmlns_push });
			local form_data = {
				-- hardcode to 1 because other numbers are just meaningless (the XEP does not specify *what exactly* to count)
				["message-count"] = "1";
			};
			if stanza and include_sender then
				form_data["last-message-sender"] = stanza.attr.from;
			end
			if stanza and include_body then
				form_data["last-message-body"] = stanza:get_child_text("body");
			elseif stanza and dummy_body and is_important(stanza) then
				form_data["last-message-body"] = tostring(dummy_body);
			end

			push_notification_payload:add_child(push_form:form(form_data));

			local push_publish = st.iq({ to = push_info.jid, from = module.host, type = "set", id = stanza_id })
				:tag("pubsub", { xmlns = "http://jabber.org/protocol/pubsub" })
					:tag("publish", { node = push_info.node })
						:tag("item")
							:add_child(push_notification_payload)
						:up()
					:up();

			if push_info.options then
				push_publish:tag("publish-options"):add_child(st.deserialize(push_info.options));
			end
			-- send out push
			module:log("debug", "Sending %s push notification for %s@%s to %s (%s)",
				form_data["last-message-body"] and "important" or "unimportant",
				node, module.host, push_info.jid, tostring(push_info.node)
			);
			-- module:log("debug", "PUSH STANZA: %s", tostring(push_publish));
			local push_event = {
				notification_stanza = push_publish;
				notification_payload = push_notification_payload;
				original_stanza = stanza;
				username = node;
				push_info = push_info;
				push_summary = form_data;
				important = not not form_data["last-message-body"];
			};

			if module:fire_event("cloud_notify/push", push_event) then
				module:log("debug", "Push was blocked by event handler: %s", push_event.reason or "Unknown reason");
			else
				-- handle push errors for this node
				if push_errors[push_identifier] == nil then
					push_errors[push_identifier] = 0;
				end
				module:hook("iq-error/host/"..stanza_id, handle_push_error);
				module:hook("iq-result/host/"..stanza_id, handle_push_success);
				id2node[stanza_id] = node;
				id2identifier[stanza_id] = push_identifier;
				module:send(push_publish);
				pushes = pushes + 1;
			end
		end
	end
	return pushes;
end

-- small helper function to extract relevant push settings
local function get_push_settings(stanza, session)
	local to = stanza.attr.to;
	local node = to and jid.split(to) or session.username;
	local user_push_services = push_store:get(node);
	return node, user_push_services;
end

-- publish on offline message
module:hook("message/offline/handle", function(event)
	local node, user_push_services = get_push_settings(event.stanza, event.origin);
	module:log("debug", "Invoking cloud handle_notify_request() for offline stanza");
	handle_notify_request(event.stanza, node, user_push_services, true);
end, 1);

-- publish on bare groupchat
-- this picks up MUC messages when there are no devices connected
module:hook("message/bare/groupchat", function(event)
	module:log("debug", "Invoking cloud handle_notify_request() for bare groupchat stanza");
	local node, user_push_services = get_push_settings(event.stanza, event.origin);
	handle_notify_request(event.stanza, node, user_push_services, true);
end, 1);


local function process_stanza_queue(queue, session, queue_type)
	if not session.push_identifier then return; end
	local user_push_services = {[session.push_identifier] = session.push_settings};
	local notified = { unimportant = false; important = false }
	for i=1, #queue do
		local stanza = queue[i];
		-- fast ignore of already pushed stanzas
		if stanza and not (stanza._push_notify and stanza._push_notify[session.push_identifier]) then
			local node = get_push_settings(stanza, session);
			local stanza_type = "unimportant";
			if dummy_body and is_important(stanza) then stanza_type = "important"; end
			if not notified[stanza_type] then		-- only notify if we didn't try to push for this stanza type already
				-- session.log("debug", "Invoking cloud handle_notify_request() for smacks queued stanza: %d", i);
				if handle_notify_request(stanza, node, user_push_services, false) ~= 0 then
					if session.hibernating and not session.first_hibernated_push then
						-- if important stanzas are treated differently (pushed with last-message-body field set to dummy string)
						-- if the message was important (e.g. had a last-message-body field) OR if we treat all pushes equally,
						-- then record the time of first push in the session for the smack module which will extend its hibernation
						-- timeout based on the value of session.first_hibernated_push
						if not dummy_body or (dummy_body and is_important(stanza)) then
							session.first_hibernated_push = os_time();
							-- check for prosody 0.12 mod_smacks
							if session.hibernating_watchdog and session.original_smacks_callback and session.original_smacks_timeout then
								-- restore old smacks watchdog (--> the start of our original timeout will be delayed until first push)
								session.hibernating_watchdog:cancel();
								session.hibernating_watchdog = watchdog.new(session.original_smacks_timeout, session.original_smacks_callback);
							end
						end
					end
					session.log("debug", "Cloud handle_notify_request() > 0, not notifying for other %s queued stanzas of type %s", queue_type, stanza_type);
					notified[stanza_type] = true
				end
			end
		end
		if notified.unimportant and notified.important then break; end		-- stop processing the queue if all push types are exhausted
	end
end

-- publish on unacked smacks message (use timer to send out push for all stanzas submitted in a row only once)
local function process_stanza(session, stanza)
	if session.push_identifier then
		session.log("debug", "adding new stanza to push_queue");
		if not session.push_queue then session.push_queue = {}; end
		local queue = session.push_queue;
		queue[#queue+1] = st.clone(stanza);
		if not session.awaiting_push_timer then		-- timer not already running --> start new timer
			session.log("debug", "Invoking cloud handle_notify_request() for newly smacks queued stanza (in a moment)");
			session.awaiting_push_timer = module:add_timer(1.0, function ()
				session.log("debug", "Invoking cloud handle_notify_request() for newly smacks queued stanzas (now in timer)");
				process_stanza_queue(session.push_queue, session, "push");
				session.push_queue = {};		-- clean up queue after push
				session.awaiting_push_timer = nil;
			end);
		end
	end
	return stanza;
end

local function process_smacks_stanza(event)
	local session = event.origin;
	local stanza = event.stanza;
	if not session.push_identifier then
		session.log("debug", "NOT invoking cloud handle_notify_request() for newly smacks queued stanza (session.push_identifier is not set: %s)",
			session.push_identifier
		);
	else
		process_stanza(session, stanza)
	end
end

-- smacks hibernation is started
local function hibernate_session(event)
	local session = event.origin;
	local queue = event.queue;
	session.first_hibernated_push = nil;
	if session.push_identifier and session.hibernating_watchdog then -- check for prosody 0.12 mod_smacks
		-- save old watchdog callback and timeout
		session.original_smacks_callback = session.hibernating_watchdog.callback;
		session.original_smacks_timeout = session.hibernating_watchdog.timeout;
		-- cancel old watchdog and create a new watchdog with extended timeout
		session.hibernating_watchdog:cancel();
		session.hibernating_watchdog = watchdog.new(extended_hibernation_timeout, function()
			session.log("debug", "Push-extended smacks watchdog triggered");
			if session.original_smacks_callback then
				session.log("debug", "Calling original smacks watchdog handler");
				session.original_smacks_callback();
			end
		end);
	end
	-- process unacked stanzas
	process_stanza_queue(queue, session, "smacks");
end

-- smacks hibernation is ended
local function restore_session(event)
	local session = event.resumed;
	if session then		-- older smacks module versions send only the "intermediate" session in event.session and no session.resumed one
		if session.awaiting_push_timer then
			session.awaiting_push_timer:stop();
			session.awaiting_push_timer = nil;
		end
		session.first_hibernated_push = nil;
		-- the extended smacks watchdog will be canceled by the smacks module, no need to anything here
	end
end

-- smacks ack is delayed
local function ack_delayed(event)
	local session = event.origin;
	local queue = event.queue;
	local stanza = event.stanza;
	if not session.push_identifier then return; end
	if stanza then process_stanza(session, stanza); return; end		-- don't iterate through smacks queue if we know which stanza triggered this
	for i=1, #queue do
		local queued_stanza = queue[i];
		-- process unacked stanzas (handle_notify_request() will only send push requests for new stanzas)
		process_stanza(session, queued_stanza);
	end
end

-- archive message added
local function archive_message_added(event)
	-- event is: { origin = origin, stanza = stanza, for_user = store_user, id = id }
	-- only notify for new mam messages when at least one device is online
	if not event.for_user or not host_sessions[event.for_user] then return; end
	local stanza = event.stanza;
	local user_session = host_sessions[event.for_user].sessions;
	local to = stanza.attr.to;
	to = to and jid.split(to) or event.origin.username;

	-- only notify if the stanza destination is the mam user we store it for
	if event.for_user == to then
		local user_push_services = push_store:get(to);

		-- Urgent stanzas are time-sensitive (e.g. calls) and should
		-- be pushed immediately to avoid getting stuck in the smacks
		-- queue in case of dead connections, for example
		local is_urgent_stanza, urgent_reason = is_urgent(event.stanza);

		local notify_push_services;
		if is_urgent_stanza then
			module:log("debug", "Urgent push for %s (%s)", to, urgent_reason);
			notify_push_services = user_push_services;
		else
			-- only notify nodes with no active sessions (smacks is counted as active and handled separate)
			notify_push_services = {};
			for identifier, push_info in pairs(user_push_services) do
				local identifier_found = nil;
				for _, session in pairs(user_session) do
					if session.push_identifier == identifier then
						identifier_found = session;
						break;
					end
				end
				if identifier_found then
					identifier_found.log("debug", "Not cloud notifying '%s' of new MAM stanza (session still alive)", identifier);
				else
					notify_push_services[identifier] = push_info;
				end
			end
		end

		handle_notify_request(event.stanza, to, notify_push_services, true);
	end
end

module:hook("smacks-hibernation-start", hibernate_session);
module:hook("smacks-hibernation-end", restore_session);
module:hook("smacks-ack-delayed", ack_delayed);
module:hook("smacks-hibernation-stanza-queued", process_smacks_stanza);
module:hook("archive-message-added", archive_message_added);

local function send_ping(event)
	local user = event.user;
	local push_services = event.push_services or push_store:get(user);
	module:log("debug", "Handling event 'cloud-notify-ping' for user '%s'", user);
	local retval = handle_notify_request(nil, user, push_services, true);
	module:log("debug", "handle_notify_request() returned %s", tostring(retval));
end
-- can be used by other modules to ping one or more (or all) push endpoints
module:hook("cloud-notify-ping", send_ping);

module:log("info", "Module loaded");
function module.unload()
	module:log("info", "Unloading module");
	-- cleanup some settings, reloading this module can cause process_smacks_stanza() to stop working otherwise
	for user, _ in pairs(host_sessions) do
		for _, session in pairs(host_sessions[user].sessions) do
			if session.awaiting_push_timer then session.awaiting_push_timer:stop(); end
			session.awaiting_push_timer = nil;
			session.push_queue = nil;
			session.first_hibernated_push = nil;
			-- check for prosody 0.12 mod_smacks
			if session.hibernating_watchdog and session.original_smacks_callback and session.original_smacks_timeout then
				-- restore old smacks watchdog
				session.hibernating_watchdog:cancel();
				session.hibernating_watchdog = watchdog.new(session.original_smacks_timeout, session.original_smacks_callback);
			end
		end
	end
	module:log("info", "Module unloaded");
end
