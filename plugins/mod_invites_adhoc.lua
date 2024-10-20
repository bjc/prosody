-- XEP-0401: Easy User Onboarding
local dataforms = require "prosody.util.dataforms";
local datetime = require "prosody.util.datetime";
local split_jid = require "prosody.util.jid".split;
local adhocutil = require "prosody.util.adhoc";

local new_adhoc = module:require("adhoc").new;

-- Whether local users can invite other users to create an account on this server
local allow_user_invites = module:get_option_boolean("allow_user_invites", false);
-- Who can see and use the contact invite command. It is strongly recommended to
-- keep this available to all local users. To allow/disallow invite-registration
-- on the server, use the option above instead.
local allow_contact_invites = module:get_option_boolean("allow_contact_invites", true);

module:default_permission(allow_user_invites and "prosody:registered" or "prosody:admin", ":invite-users");

local invites;
if prosody.shutdown then -- COMPAT hack to detect prosodyctl
	invites = module:depends("invites");
end

local invite_result_form = dataforms.new({
		title = "Your invite has been created",
		{
			name = "url" ;
			var = "landing-url";
			label = "Invite web page";
			desc = "Share this link";
		},
		{
			name = "uri";
			label = "Invite URI";
			desc = "This alternative link can be opened with some XMPP clients";
		},
		{
			name = "expire";
			label = "Invite valid until";
		},
	});

-- This is for checking if the specified JID may create invites
-- that allow people to register accounts on this host.
local function may_invite_new_users(context)
	return module:may(":invite-users", context);
end

module:depends("adhoc");

-- This command is available to all local users, even if allow_user_invites = false
-- If allow_user_invites is false, creating an invite still works, but the invite will
-- not be valid for registration on the current server, only for establishing a roster
-- subscription.
module:provides("adhoc", new_adhoc("Create new contact invite", "urn:xmpp:invite#invite",
		function (_, data)
			local username, host = split_jid(data.from);
			if host ~= module.host then
				return {
					status = "completed";
					error = {
						message = "This command is only available to users of "..module.host;
					};
				};
			end
			local invite = invites.create_contact(username, may_invite_new_users(data), {
				source = data.from
			});
			--TODO: check errors
			return {
				status = "completed";
				result = {
					layout = invite_result_form;
					values = {
						uri = invite.uri;
						url = invite.landing_page;
						expire = datetime.datetime(invite.expires);
					};
				};
			};
		end, allow_contact_invites and "local_user" or "admin"));

-- This is an admin-only command that creates a new invitation suitable for registering
-- a new account. It does not add the new user to the admin's roster.
module:provides("adhoc", new_adhoc("Create new account invite", "urn:xmpp:invite#create-account",
		function (_, data)
			local invite = invites.create_account(nil, {
				source = data.from
			});
			--TODO: check errors
			return {
				status = "completed";
				result = {
					layout = invite_result_form;
					values = {
						uri = invite.uri;
						url = invite.landing_page;
						expire = datetime.datetime(invite.expires);
					};
				};
			};
		end, "admin"));

local password_reset_form = dataforms.new({
	title = "Generate Password Reset Invite";
	{
		name = "accountjid";
		type = "jid-single";
		required = true;
		label = "The XMPP ID for the account to generate a password reset invite for";
	};
});

module:provides("adhoc", new_adhoc("Create password reset invite", "xmpp:prosody.im/mod_invites_adhoc#password-reset",
		adhocutil.new_simple_form(password_reset_form,
		function (fields, err)
			if err then return { status = "completed"; error = { message = "Fill in the form correctly" } }; end
			local username = split_jid(fields.accountjid);
			local invite = invites.create_account_reset(username);
			return {
				status = "completed";
				result = {
					layout = invite_result_form;
					values = {
						uri = invite.uri;
						url = invite.landing_page;
						expire = datetime.datetime(invite.expires);
					};
				};
			};
	end), "admin"));
