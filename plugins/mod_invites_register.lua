local st = require "prosody.util.stanza";
local jid_split = require "prosody.util.jid".split;
local jid_bare = require "prosody.util.jid".bare;
local rostermanager = require "prosody.core.rostermanager";

local require_encryption = module:get_option_boolean("c2s_require_encryption",
	module:get_option_boolean("require_encryption", true));
local invite_only = module:get_option_boolean("registration_invite_only", true);

local invites;
if prosody.process_type == "prosody" then
	invites = module:depends("invites");

	if invite_only then
		module:depends("register_ibr");
	end
end

local legacy_invite_stream_feature = st.stanza("register", { xmlns = "urn:xmpp:invite" }):up();
local invite_stream_feature = st.stanza("register", { xmlns = "urn:xmpp:ibr-token:0" }):up();
module:hook("stream-features", function(event)
	local session, features = event.origin, event.features;

	-- Advertise to unauthorized clients only.
	if session.type ~= "c2s_unauthed" or (require_encryption and not session.secure) then
		return
	end

	features:add_child(legacy_invite_stream_feature);
	features:add_child(invite_stream_feature);
end);

-- XEP-0379: Pre-Authenticated Roster Subscription
module:hook("presence/bare", function (event)
	local stanza = event.stanza;
	if stanza.attr.type ~= "subscribe" then return end

	local preauth = stanza:get_child("preauth", "urn:xmpp:pars:0");
	if not preauth then return end
	local token = preauth.attr.token;
	if not token then return end

	local username, host = jid_split(stanza.attr.to);

	local invite, err = invites.get(token, username);

	if not invite then
		module:log("debug", "Got invalid token, error: %s", err);
		return;
	end

	local contact = jid_bare(stanza.attr.from);

	module:log("debug", "Approving inbound subscription to %s from %s", username, contact);
	if rostermanager.set_contact_pending_in(username, host, contact, stanza) then
		if rostermanager.subscribed(username, host, contact) then
			invite:use();
			rostermanager.roster_push(username, host, contact);

			-- Send back a subscription request (goal is mutual subscription)
			if not rostermanager.is_user_subscribed(username, host, contact)
			and not rostermanager.is_contact_pending_out(username, host, contact) then
				module:log("debug", "Sending automatic subscription request to %s from %s", contact, username);
				if rostermanager.set_contact_pending_out(username, host, contact) then
					rostermanager.roster_push(username, host, contact);
					module:send(st.presence({type = "subscribe", from = username.."@"..host, to = contact }));
				else
					module:log("warn", "Failed to set contact pending out for %s", username);
				end
			end
		end
	end
end, 1);

-- Client is submitting a preauth token to allow registration
module:hook("stanza/iq/urn:xmpp:pars:0:preauth", function(event)
	local preauth = event.stanza.tags[1];
	local token = preauth.attr.token;
	local validated_invite = invites.get(token);
	if not validated_invite then
		local reply = st.error_reply(event.stanza, "cancel", "forbidden", "The invite token is invalid or expired");
		event.origin.send(reply);
		return true;
	end
	event.origin.validated_invite = validated_invite;
	local reply = st.reply(event.stanza);
	event.origin.send(reply);
	return true;
end);

-- Registration attempt - ensure a valid preauth token has been supplied
module:hook("user-registering", function (event)
	local validated_invite = event.validated_invite or (event.session and event.session.validated_invite);
	if invite_only and not validated_invite then
		event.allowed = false;
		event.reason = "Registration on this server is through invitation only";
		return;
	elseif not validated_invite then
		-- This registration is not using an invite, but
		-- the server is not in invite-only mode, so nothing
		-- for this module to do...
		return;
	end
	if validated_invite then
		local username = validated_invite.username;
		if validated_invite.type ~= "roster" and username and username ~= event.username then
			event.allowed = false;
			event.reason = "The chosen username is not valid with this invitation";
		end
		local reset_username = validated_invite.additional_data and validated_invite.additional_data.allow_reset;
		if reset_username then
			if reset_username ~= event.username then
				event.allowed = false;
				event.reason = "Incorrect username for password reset";
			end
			event.allow_reset = reset_username;
		end
	end
end);

-- Make a *one-way* subscription. User will see when contact is online,
-- contact will not see when user is online.
function subscribe(host, user_username, contact_username)
	local user_jid = user_username.."@"..host;
	local contact_jid = contact_username.."@"..host;
	-- Update user's roster to say subscription request is pending...
	rostermanager.set_contact_pending_out(user_username, host, contact_jid);
	-- Update contact's roster to say subscription request is pending...
	rostermanager.set_contact_pending_in(contact_username, host, user_jid);
	-- Update contact's roster to say subscription request approved...
	rostermanager.subscribed(contact_username, host, user_jid);
	-- Update user's roster to say subscription request approved...
	rostermanager.process_inbound_subscription_approval(user_username, host, contact_jid);
end

-- Make a mutual subscription between jid1 and jid2. Each JID will see
-- when the other one is online.
function subscribe_both(host, user1, user2)
	subscribe(host, user1, user2);
	subscribe(host, user2, user1);
end

-- Registration successful, if there was a preauth token, mark it as used
module:hook("user-registered", function (event)
	local validated_invite = event.validated_invite or (event.session and event.session.validated_invite);
	if not validated_invite then
		return;
	end
	local inviter_username = validated_invite.inviter;
	local contact_username = event.username;
	validated_invite:use();

	if inviter_username then
		module:log("debug", "Creating mutual subscription between %s and %s", inviter_username, contact_username);
		subscribe_both(module.host, inviter_username, contact_username);
		rostermanager.roster_push(inviter_username, module.host, contact_username.."@"..module.host);
	end

	if validated_invite.additional_data then
		module:log("debug", "Importing roles from invite");
		local roles = validated_invite.additional_data.roles;
		if roles and roles[1] ~= nil then
			local um = require "prosody.core.usermanager";
			local ok, err = um.set_user_role(event.username, module.host, roles[1]);
			if not ok then
				module:log("error", "Could not set role %s for newly registered user %s: %s", roles[1], event.username, err);
			end
			for i = 2, #roles do
				local ok, err = um.add_user_secondary_role(event.username, module.host, roles[i]);
				if not ok then
					module:log("warn", "Could not add secondary role %s for newly registered user %s: %s", roles[i], event.username, err);
				end
			end
		elseif roles and type(next(roles)) == "string" then
			module:log("warn", "Invite carries legacy, migration required for user '%s' for role set %q to take effect", event.username, roles);
			module:open_store("roles"):set(contact_username, roles);
		end
	end
end);

-- Equivalent of user-registered but for when the account already existed
-- (i.e. password reset)
module:hook("user-password-reset", function (event)
	local validated_invite = event.validated_invite or (event.session and event.session.validated_invite);
	if not validated_invite then
		return;
	end
	validated_invite:use();
end);

