local id = require "prosody.util.id";
local it = require "prosody.util.iterators";
local url = require "socket.url";
local jid_node = require "prosody.util.jid".node;
local jid_split = require "prosody.util.jid".split;
local argparse = require "prosody.util.argparse";
local human_io = require "prosody.util.human.io";

local url_escape = require "prosody.util.http".urlencode;
local render_url = require "prosody.util.interpolation".new("%b{}", url_escape, {
	urlescape = url_escape;
	noscheme = function (urlstring)
		return (urlstring:gsub("^[^:]+:", ""));
	end;
});

local default_ttl = module:get_option_period("invite_expiry", "1 week");

local token_storage;
if prosody.process_type == "prosody" or prosody.shutdown then
	token_storage = module:open_store("invite_token", "map");
end

local function get_uri(action, jid, token, params) --> string
	return url.build({
			scheme = "xmpp",
			path = jid,
			query = action..";preauth="..token..(params and (";"..params) or ""),
		});
end

local function create_invite(invite_action, invite_jid, allow_registration, additional_data, ttl, reusable)
	local token = id.medium();

	local created_at = os.time();
	local expires = created_at + (ttl or default_ttl);

	local invite_params = (invite_action == "roster" and allow_registration) and "ibr=y" or nil;

	local invite = {
		type = invite_action;
		jid = invite_jid;

		token = token;
		allow_registration = allow_registration;
		additional_data = additional_data;

		uri = get_uri(invite_action, invite_jid, token, invite_params);

		created_at = created_at;
		expires = expires;

		reusable = reusable;
	};

	module:fire_event("invite-created", invite);

	if allow_registration then
		local ok, err = token_storage:set(nil, token, invite);
		if not ok then
			module:log("warn", "Failed to store account invite: %s", err);
			return nil, "internal-server-error";
		end
	end

	if invite_action == "roster" then
		local username = jid_node(invite_jid);
		local ok, err = token_storage:set(username, token, expires);
		if not ok then
			module:log("warn", "Failed to store subscription invite: %s", err);
			return nil, "internal-server-error";
		end
	end

	return invite;
end

-- Create invitation to register an account (optionally restricted to the specified username)
function create_account(account_username, additional_data, ttl) --luacheck: ignore 131/create_account
	local jid = account_username and (account_username.."@"..module.host) or module.host;
	return create_invite("register", jid, true, additional_data, ttl);
end

-- Create invitation to reset the password for an account
function create_account_reset(account_username, ttl) --luacheck: ignore 131/create_account_reset
	return create_account(account_username, { allow_reset = account_username }, ttl or 86400);
end

-- Create invitation to become a contact of a local user
function create_contact(username, allow_registration, additional_data, ttl) --luacheck: ignore 131/create_contact
	return create_invite("roster", username.."@"..module.host, allow_registration, additional_data, ttl);
end

-- Create invitation to register an account and join a user group
-- If explicit ttl is passed, invite is valid for multiple signups
-- during that time period
function create_group(group_ids, additional_data, ttl) --luacheck: ignore 131/create_group
	local merged_additional_data = {
		groups = group_ids;
	};
	if additional_data then
		for k, v in pairs(additional_data) do
			merged_additional_data[k] = v;
		end
	end
	return create_invite("register", module.host, true, merged_additional_data, ttl, not not ttl);
end

-- Iterates pending (non-expired, unused) invites that allow registration
function pending_account_invites() --luacheck: ignore 131/pending_account_invites
	local store = module:open_store("invite_token");
	local now = os.time();
	local function is_valid_invite(_, invite)
		return invite.expires > now;
	end
	return it.filter(is_valid_invite, pairs(store:get(nil) or {}));
end

function get_account_invite_info(token) --luacheck: ignore 131/get_account_invite_info
	if not token then
		return nil, "no-token";
	end

	-- Fetch from host store (account invite)
	local token_info = token_storage:get(nil, token);
	if not token_info then
		return nil, "token-invalid";
	elseif os.time() > token_info.expires then
		return nil, "token-expired";
	end

	return token_info;
end

function delete_account_invite(token) --luacheck: ignore 131/delete_account_invite
	if not token then
		return nil, "no-token";
	end

	return token_storage:set(nil, token, nil);
end

local valid_invite_methods = {};
local valid_invite_mt = { __index = valid_invite_methods };

function valid_invite_methods:use()
	if self.reusable then
		return true;
	end

	if self.username then
		-- Also remove the contact invite if present, on the
		-- assumption that they now have a mutual subscription
		token_storage:set(self.username, self.token, nil);
	end
	token_storage:set(nil, self.token, nil);

	return true;
end

-- Get a validated invite (or nil, err). Must call :use() on the
-- returned invite after it is actually successfully used
-- For "roster" invites, the username of the local user (who issued
-- the invite) must be passed.
-- If no username is passed, but the registration is a roster invite
-- from a local user, the "inviter" field of the returned invite will
-- be set to their username.
function get(token, username)
	if not token then
		return nil, "no-token";
	end

	local valid_until, inviter;

	-- Fetch from host store (account invite)
	local token_info = token_storage:get(nil, token);

	if username then -- token being used for subscription
		-- Fetch from user store (subscription invite)
		valid_until = token_storage:get(username, token);
	else -- token being used for account creation
		valid_until = token_info and token_info.expires;
		if token_info and token_info.type == "roster" then
			username = jid_node(token_info.jid);
			inviter = username;
		end
	end

	if not valid_until then
		module:log("debug", "Got unknown token: %s", token);
		return nil, "token-invalid";
	elseif os.time() > valid_until then
		module:log("debug", "Got expired token: %s", token);
		return nil, "token-expired";
	end

	return setmetatable({
		token = token;
		username = username;
		inviter = inviter;
		type = token_info and token_info.type or "roster";
		uri = token_info and token_info.uri or get_uri("roster", username.."@"..module.host, token);
		additional_data = token_info and token_info.additional_data or nil;
		reusable = token_info and token_info.reusable or false;
	}, valid_invite_mt);
end

function use(token) --luacheck: ignore 131/use
	local invite = get(token);
	return invite and invite:use();
end

-- Point at e.g. a deployment of https://github.com/modernxmpp/easy-xmpp-invitation
-- This URL must always be absolute, as it is shared standalone
local invite_url_template = module:get_option_string("invites_page");
local invites_page_supports = module:get_option_set("invites_page_supports", { "account", "contact", "account-and-contact" });

local function add_landing_url(invite)
	if not invite_url_template or invite.landing_page then return; end

	-- Determine whether this type of invitation is supported by the landing page
	local invite_type;
	if invite.type == "register" then
		if invite.additional_data and invite.additional_data.allow_reset then
			invite_type = "password-reset";
		else
			invite_type = "account";
		end
	elseif invite.type == "roster" then
		if invite.allow_registration then
			invite_type = "account-and-contact";
		else
			invite_type = "contact-only";
		end
	end
	if not invites_page_supports:contains(invite_type) then
		return; -- Invitation type unsupported
	end

	invite.landing_page = render_url(invite_url_template, { host = module.host, invite = invite });
end

module:hook("invite-created", add_landing_url, -1);

--- shell command
-- COMPAT: Dynamic groups are work in progress as of 13.0, so we'll use the
-- presence of mod_invites_groups (a community module) to determine whether to
-- expose our support for invites to groups.
local have_group_invites = module:get_option_inherited_set("modules_enabled"):contains("invites_groups");

module:add_item("shell-command", {
	section = "invite";
	section_desc = "Create and manage invitations";
	name = "create_account";
	desc = "Create an invitation to make an account on this server with the specified JID (supply only a hostname to allow any username)";
	args = {
		{ name = "user_jid", type = "string" };
	};
	host_selector = "user_jid";
	flags = {
		array_params = { role = true, group = have_group_invites };
		value_params = { expires_after = true };
	};

	handler = function (self, user_jid, opts) --luacheck: ignore 212/self
		local username = jid_split(user_jid);
		local roles = opts and opts.role or {};
		local groups = opts and opts.group or {};

		if opts and opts.admin then
			-- Insert it first since we don't get order out of argparse
			table.insert(roles, 1, "prosody:admin");
		end

		local ttl;
		if opts and opts.expires_after then
			ttl = human_io.parse_duration(opts.expires_after);
			if not ttl then
				return false, "Unable to parse duration: "..opts.expires_after;
			end
		end

		local invite = assert(create_account(username, {
			roles = roles;
			groups = groups;
		}, ttl));

		return true, invite.landing_page or invite.uri;
	end;
});

module:add_item("shell-command", {
	section = "invite";
	section_desc = "Create and manage invitations";
	name = "create_reset";
	desc = "Create a password reset link for the specified user";
	args = { { name = "user_jid", type = "string" } };
	host_selector = "user_jid";
	flags = {
		value_params = { expires_after = true };
	};

	handler = function (self, user_jid, opts) --luacheck: ignore 212/self
		local username = jid_split(user_jid);
		if not username then
			return nil, "Supply the JID of the account you want to generate a password reset for";
		end
		local duration_sec = require "prosody.util.human.io".parse_duration(opts and opts.expires_after or "1d");
		if not duration_sec then
			return nil, "Unable to parse duration: "..opts.expires_after;
		end
		local invite, err = create_account_reset(username, duration_sec);
		if not invite then return nil, err; end
		self.session.print(invite.landing_page or invite.uri);
		return true, ("Password reset link for %s valid until %s"):format(user_jid, os.date("%Y-%m-%d %T", invite.expires));
	end;
});

module:add_item("shell-command", {
	section = "invite";
	section_desc = "Create and manage invitations";
	name = "create_contact";
	desc = "Create an invitation to become contacts with the specified user";
	args = { { name = "user_jid", type = "string" } };
	host_selector = "user_jid";
	flags = {
		value_params = { expires_after = true };
		kv_params = { allow_registration = true };
	};

	handler = function (self, user_jid, opts) --luacheck: ignore 212/self
		local username = jid_split(user_jid);
		if not username then
			return nil, "Supply the JID of the account you want the recipient to become a contact of";
		end
		local ttl;
		if opts and opts.expires_after then
			ttl = require "prosody.util.human.io".parse_duration(opts.expires_after);
			if not ttl then
				return nil, "Unable to parse duration: "..opts.expires_after;
			end
		end
		local invite, err = create_contact(username, opts and opts.allow_registration, nil, ttl);
		if not invite then return nil, err; end
		return true, invite.landing_page or invite.uri;
	end;
});

module:add_item("shell-command", {
	section = "invite";
	section_desc = "Create and manage invitations";
	name = "show";
	desc = "Show details of an account invitation token";
	args = { { name = "host", type = "string" }, { name = "token", type = "string" } };
	host_selector = "host";

	handler = function (self, host, token) --luacheck: ignore 212/self 212/host
		local invite, err = get_account_invite_info(token);
		if not invite then return nil, err; end

		local print = self.session.print;

		if invite.type == "roster" then
			print("Invitation to register and become a contact of "..invite.jid);
		elseif invite.type == "register" then
			local jid_user, jid_host = jid_split(invite.jid);
			if invite.additional_data and invite.additional_data.allow_reset then
				print("Password reset for "..invite.additional_data.allow_reset.."@"..jid_host);
			elseif jid_user then
				print("Invitation to register on "..jid_host.." with username '"..jid_user.."'");
			else
				print("Invitation to register on "..jid_host);
			end
		else
			print("Unknown invitation type");
		end

		if invite.inviter then
			print("Creator:", invite.inviter);
		end

		print("Created:", os.date("%Y-%m-%d %T", invite.created_at));
		print("Expires:", os.date("%Y-%m-%d %T", invite.expires));

		print("");

		if invite.uri then
			print("XMPP URI:", invite.uri);
		end

		if invite.landing_page then
			print("Web link:", invite.landing_page);
		end

		if invite.additional_data then
			print("");
			if invite.additional_data.roles then
				if invite.additional_data.roles[1] then
					print("Role:", invite.additional_data.roles[1]);
				end
				if invite.additional_data.roles[2] then
					print("Secondary roles:", table.concat(invite.additional_data.roles, ", ", 2, #invite.additional_data.roles));
				end
			end
			if invite.additional_data.groups then
				print("Groups:", table.concat(invite.additional_data.groups, ", "));
			end
			if invite.additional_data.note then
				print("Comment:", invite.additional_data.note);
			end
		end

		return true, "Invitation valid";
	end;
});

module:add_item("shell-command", {
	section = "invite";
	section_desc = "Create and manage invitations";
	name = "delete";
	desc = "Delete/revoke an invitation token";
	args = { { name = "host", type = "string" }, { name = "token", type = "string" } };
	host_selector = "host";

	handler = function (self, host, token) --luacheck: ignore 212/self 212/host
		local invite, err = delete_account_invite(token);
		if not invite then return nil, err; end
		return true, "Invitation deleted";
	end;
});

module:add_item("shell-command", {
	section = "invite";
	section_desc = "Create and manage invitations";
	name = "list";
	desc = "List pending invitations which allow account registration";
	args = { { name = "host", type = "string" } };
	host_selector = "host";

	handler = function (self, host) -- luacheck: ignore 212/host
		local print_row = human_io.table({
			{
				title = "Token";
				key = "invite";
				width = 24;
				mapper = function (invite)
					return invite.token;
				end;
			};
			{
				title = "Expires";
				key = "invite";
				width = 20;
				mapper = function (invite)
					return os.date("%Y-%m-%dT%T", invite.expires);
				end;
			};
			{
				title = "Description";
				key = "invite";
				width = "100%";
				mapper = function (invite)
					if invite.type == "roster" then
						return "Contact with "..invite.jid;
					elseif invite.type == "register" then
						local jid_user, jid_host = jid_split(invite.jid);
						if invite.additional_data and invite.additional_data.allow_reset then
							return "Password reset for "..invite.additional_data.allow_reset.."@"..jid_host;
						end
						if jid_user then
							return "Register on "..jid_host.." with username "..jid_user;
						end
						return "Register on "..jid_host;
					end
				end;
			};
		}, self.session.width);

		self.session.print(print_row());
		local count = 0;
		for _, invite in pending_account_invites() do
			count = count + 1;
			self.session.print(print_row({ invite = invite }));
		end
		return true, ("%d pending invites"):format(count);
	end;
});

local subcommands = {};

--- prosodyctl command
function module.command(arg)
	local opts = argparse.parse(arg, { short_params = { h = "help"; ["?"] = "help" } });
	local cmd = table.remove(arg, 1); -- pop command
	if opts.help or not cmd or not subcommands[cmd] then
		print("usage: prosodyctl mod_"..module.name.." generate example.com");
		return 2;
	end
	return subcommands[cmd](arg);
end

function subcommands.generate()
	print("This command is deprecated. Please see 'prosodyctl shell help invite' for available commands.");
	return 1;
end
