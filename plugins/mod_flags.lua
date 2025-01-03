local jid_node = require "prosody.util.jid".node;

local flags = module:open_store("account_flags", "keyval+");

-- API

function add_flag(username, flag, comment)
	local flag_data = {
		when = os.time();
		comment = comment;
	};

	local ok, err = flags:set_key(username, flag, flag_data);
	if not ok then
		return nil, err;
	end

	module:fire_event("user-flag-added/"..flag, {
		user = username;
		flag = flag;
		data = flag_data;
	});

	return true;
end

function remove_flag(username, flag)
	local ok, err = flags:set_key(username, flag, nil);
	if not ok then
		return nil, err;
	end

	module:fire_event("user-flag-removed/"..flag, {
		user = username;
		flag = flag;
	});

	return true;
end

function has_flag(username, flag) -- luacheck: ignore 131/has_flag
	local ok, err = flags:get_key(username, flag);
	if not ok and err then
		error("Failed to check flags for user: "..err);
	end
	return not not ok;
end

function get_flag_info(username, flag) -- luacheck: ignore 131/get_flag_info
	return flags:get_key(username, flag);
end

-- Shell commands

local function get_username(jid)
	return (assert(jid_node(jid), "please supply a valid user JID"));
end

module:add_item("shell-command", {
	section = "flags";
	section_desc = "View and manage flags on user accounts";
	name = "list";
	desc = "List flags for the given user account";
	args = {
		{ name = "jid", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid) --luacheck: ignore 212/self
		local c = 0;

		local user_flags, err = flags:get(get_username(jid));

		if not user_flags and err then
			return false, "Unable to list flags: "..err;
		end

		if user_flags then
			local print = self.session.print;

			for flag_name, flag_data in pairs(user_flags) do
				print(flag_name, os.date("%Y-%m-%d %R", flag_data.when), flag_data.comment);
				c = c + 1;
			end
		end

		return true, ("%d flags listed"):format(c);
	end;
});

module:add_item("shell-command", {
	section = "flags";
	section_desc = "View and manage flags on user accounts";
	name = "add";
	desc = "Add a flag to the given user account, with optional comment";
	args = {
		{ name = "jid", type = "string" };
		{ name = "flag", type = "string" };
		{ name = "comment", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid, flag, comment) --luacheck: ignore 212/self
		local username = get_username(jid);

		local ok, err = add_flag(username, flag, comment);
		if not ok then
			return false, "Failed to add flag: "..err;
		end

		return true, "Flag added";
	end;
});

module:add_item("shell-command", {
	section = "flags";
	section_desc = "View and manage flags on user accounts";
	name = "remove";
	desc = "Remove a flag from the given user account";
	args = {
		{ name = "jid", type = "string" };
		{ name = "flag", type = "string" };
	};
	host_selector = "jid";
	handler = function(self, jid, flag) --luacheck: ignore 212/self
		local username = get_username(jid);

		local ok, err = remove_flag(username, flag);
		if not ok then
			return false, "Failed to remove flag: "..err;
		end

		return true, "Flag removed";
	end;
});

module:add_item("shell-command", {
	section = "flags";
	section_desc = "View and manage flags on user accounts";
	name = "find";
	desc = "Find all user accounts with a given flag on the specified host";
	args = {
		{ name = "host", type = "string" };
		{ name = "flag", type = "string" };
	};
	host_selector = "host";
	handler = function(self, host, flag) --luacheck: ignore 212/self 212/host
		local users_with_flag = flags:get_key_from_all(flag);

		local print = self.session.print;
		local c = 0;
		for user, flag_data in pairs(users_with_flag) do
			print(user, os.date("%Y-%m-%d %R", flag_data.when), flag_data.comment);
			c = c + 1;
		end

		return true, ("%d accounts listed"):format(c);
	end;
});
