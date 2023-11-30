-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--


local st = require "prosody.util.stanza";
local usermanager = require "prosody.core.usermanager";
local nodeprep = require "prosody.util.encodings".stringprep.nodeprep;
local jid_bare, jid_node = import("prosody.util.jid", "bare", "node");

local compat = module:get_option_boolean("registration_compat", true);
local soft_delete_period = module:get_option_period("registration_delete_grace_period");
local deleted_accounts = module:open_store("accounts_cleanup");

module:add_feature("jabber:iq:register");

-- Allow us to 'freeze' a session and retrieve properties even after it is
-- destroyed
local function capture_session_properties(session)
	return setmetatable({
		id = session.id;
		ip = session.ip;
		type = session.type;
		client_id = session.client_id;
	}, { __index = session });
end

-- Password change and account deletion handler
local function handle_registration_stanza(event)
	local session, stanza = event.origin, event.stanza;
	local log = session.log or module._log;

	local query = stanza.tags[1];
	if stanza.attr.type == "get" then
		local reply = st.reply(stanza);
		reply:tag("query", {xmlns = "jabber:iq:register"})
			:tag("registered"):up()
			:tag("username"):text(session.username):up()
			:tag("password"):up();
		session.send(reply);
	else -- stanza.attr.type == "set"
		if query.tags[1] and query.tags[1].name == "remove" then
			local username, host = session.username, session.host;

			if host ~= module.host then -- Sanity check for safety
				module:log("error", "Host mismatch on deletion request (a bug): %s ~= %s", host, module.host);
				session.send(st.error_reply(stanza, "cancel", "internal-server-error"));
				return true;
			end

			-- This one weird trick sends a reply to this stanza before the user is deleted
			local old_session_close = session.close;
			session.close = function(self, ...)
				self.send(st.reply(stanza));
				return old_session_close(self, ...);
			end

			local old_session = capture_session_properties(session);

			if not soft_delete_period then
				local ok, err = usermanager.delete_user(username, host);

				if not ok then
					log("debug", "Removing user account %s@%s failed: %s", username, host, err);
					session.close = old_session_close;
					session.send(st.error_reply(stanza, "cancel", "service-unavailable", err));
					return true;
				end

				log("info", "User removed their account: %s@%s (deleted)", username, host);
				module:fire_event("user-deregistered", { username = username, host = host, source = "mod_register", session = old_session });
			else
				local ok, err = usermanager.disable_user(username, host, {
					reason = "ibr";
					comment = "Deletion requested by user";
					when = os.time();
				});

				if not ok then
					log("debug", "Removing (disabling) user account %s@%s failed: %s", username, host, err);
					session.close = old_session_close;
					session.send(st.error_reply(stanza, "cancel", "service-unavailable", err));
					return true;
				end

				local status = {
					deleted_at = os.time();
					pending_until = os.time() + soft_delete_period;
					client_id = session.client_id;
				};
				deleted_accounts:set(username, status);

				log("info", "User removed their account: %s@%s (disabled, pending deletion)", username, host);
				module:fire_event("user-deregistered-pending", {
					username = username;
					host = host;
					source = "mod_register";
					session = old_session;
					status = status;
				});
			end
		else
			local username = query:get_child_text("username");
			local password = query:get_child_text("password");
			if username and password then
				username = nodeprep(username);
				if username == session.username then
					if usermanager.set_password(username, password, session.host, session.resource) then
						session.send(st.reply(stanza));
					else
						-- TODO unable to write file, file may be locked, etc, what's the correct error?
						session.send(st.error_reply(stanza, "wait", "internal-server-error"));
					end
				else
					session.send(st.error_reply(stanza, "modify", "bad-request"));
				end
			else
				session.send(st.error_reply(stanza, "modify", "bad-request"));
			end
		end
	end
	return true;
end

module:hook("iq/self/jabber:iq:register:query", handle_registration_stanza);
if compat then
	module:hook("iq/host/jabber:iq:register:query", function (event)
		local session, stanza = event.origin, event.stanza;
		if session.type == "c2s" and jid_bare(stanza.attr.to) == session.host then
			return handle_registration_stanza(event);
		end
	end);
end

-- This improves UX of soft-deleted accounts by informing the user that the
-- account has been deleted, rather than just disabled. They can e.g. contact
-- their admin if this was a mistake.
module:hook("authentication-failure", function (event)
	if event.condition ~= "account-disabled" then return; end
	local session = event.session;
	local sasl_handler = session and session.sasl_handler;
	if sasl_handler.username then
		local status = deleted_accounts:get(sasl_handler.username);
		if status then
			event.text = "Account deleted";
		end
	end
end, -1000);

function restore_account(username)
	local pending, pending_err = deleted_accounts:get(username);
	if not pending then
		return nil, pending_err or "Account not pending deletion";
	end
	local account_info, err = usermanager.get_account_info(username, module.host);
	if not account_info then
		return nil, "Couldn't fetch account info: "..err;
	end
	local forget_ok, forget_err = deleted_accounts:set(username, nil);
	if not forget_ok then
		return nil, "Couldn't remove account from deletion queue: "..forget_err;
	end
	local enable_ok, enable_err = usermanager.enable_user(username, module.host);
	if not enable_ok then
		return nil, "Removed account from deletion queue, but couldn't enable it: "..enable_err;
	end
	return true, "Account restored";
end

local cleanup_time = module:measure("cleanup", "times");

function cleanup_soft_deleted_accounts()
	local cleanup_done = cleanup_time();
	local success, fail, restored, pending = 0, 0, 0, 0;

	for username in deleted_accounts:users() do
		module:log("debug", "Processing account cleanup for '%s'", username);
		local account_info, account_info_err = usermanager.get_account_info(username, module.host);
		if not account_info then
			module:log("warn", "Unable to process delayed deletion of user '%s': %s", username, account_info_err);
			fail = fail + 1;
		else
			if account_info.enabled == false then
				local meta = deleted_accounts:get(username);
				if meta.pending_until <= os.time() then
					local ok, err = usermanager.delete_user(username, module.host);
					if not ok then
						module:log("warn", "Unable to process delayed deletion of user '%s': %s", username, err);
						fail = fail + 1;
					else
						success = success + 1;
						deleted_accounts:set(username, nil);
						module:log("debug", "Deleted account '%s' successfully", username);
						module:fire_event("user-deregistered", { username = username, host = module.host, source = "mod_register" });
					end
				else
					pending = pending + 1;
				end
			else
				module:log("warn", "Account '%s' is not disabled, removing from deletion queue", username);
				restored = restored + 1;
			end
		end
	end

	module:log("debug", "%d accounts scheduled for future deletion", pending);

	if success > 0 or fail > 0 then
		module:log("info", "Completed account cleanup - %d accounts deleted (%d failed, %d restored, %d pending)", success, fail, restored, pending);
	end
	cleanup_done();
end

module:daily("Remove deleted accounts", cleanup_soft_deleted_accounts);

--- shell command
module:add_item("shell-command", {
	section = "user";
	name = "restore";
	desc = "Restore a user account scheduled for deletion";
	args = {
		{ name = "jid", type = "string" };
	};
	host_selector = "jid";
	handler = function (self, jid) --luacheck: ignore 212/self
		return restore_account(jid_node(jid));
	end;
});
