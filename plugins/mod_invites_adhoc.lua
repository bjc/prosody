-- XEP-0401: Easy User Onboarding
local dataforms = require "util.dataforms";
local datetime = require "util.datetime";
local split_jid = require "util.jid".split;
local usermanager = require "core.usermanager";

local new_adhoc = module:require("adhoc").new;

-- Whether local users can invite other users to create an account on this server
local allow_user_invites = module:get_option_boolean("allow_user_invites", false);
-- Who can see and use the contact invite command. It is strongly recommended to
-- keep this available to all local users. To allow/disallow invite-registration
-- on the server, use the option above instead.
local allow_contact_invites = module:get_option_boolean("allow_contact_invites", true);

local allow_user_invite_roles = module:get_option_set("allow_user_invites_by_roles");
local deny_user_invite_roles = module:get_option_set("deny_user_invites_by_roles");

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
local function may_invite_new_users(jid)
	if usermanager.get_roles then
		local user_roles = usermanager.get_roles(jid, module.host);
		if not user_roles then return; end
		if user_roles["prosody:admin"] then
			return true;
		end
		if allow_user_invite_roles then
			for allowed_role in allow_user_invite_roles do
				if user_roles[allowed_role] then
					return true;
				end
			end
		end
		if deny_user_invite_roles then
			for denied_role in deny_user_invite_roles do
				if user_roles[denied_role] then
					return false;
				end
			end
		end
	elseif usermanager.is_admin(jid, module.host) then -- COMPAT w/0.11
		return true; -- Admins may always create invitations
	end
	-- No role matches, so whatever the default is
	return allow_user_invites;
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
			local invite = invites.create_contact(username, may_invite_new_users(data.from), {
				source = data.from
			});
			--TODO: check errors
			return {
				status = "completed";
				form = {
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
				form = {
					layout = invite_result_form;
					values = {
						uri = invite.uri;
						url = invite.landing_page;
						expire = datetime.datetime(invite.expires);
					};
				};
			};
		end, "admin"));
