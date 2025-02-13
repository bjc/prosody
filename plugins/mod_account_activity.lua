local jid = require "prosody.util.jid";
local time = os.time;

local store = module:open_store(nil, "keyval+");

module:hook("authentication-success", function(event)
	local session = event.session;
	if session.username then
		store:set_key(session.username, "timestamp", time());
	end
end);

module:hook("resource-unbind", function(event)
	local session = event.session;
	if session.username then
		store:set_key(session.username, "timestamp", time());
	end
end);

local user_sessions = prosody.hosts[module.host].sessions;
function get_last_active(username) --luacheck: ignore 131/get_last_active
	if user_sessions[username] then
		return os.time(), true; -- Currently connected
	else
		local last_activity = store:get(username);
		if not last_activity then return nil; end
		return last_activity.timestamp;
	end
end

module:add_item("shell-command", {
	section = "user";
	section_desc = "View user activity data";
	name = "activity";
	desc = "View the last recorded user activity for an account";
	args = { { name = "jid"; type = "string" } };
	host_selector = "jid";
	handler = function(self, userjid) --luacheck: ignore 212/self
		local username = jid.prepped_split(userjid);
		local last_timestamp, is_online = get_last_active(username);
		if not last_timestamp then
			return true, "No activity";
		end

		return true, ("%s (%s)"):format(os.date("%Y-%m-%d %H:%M:%S", last_timestamp), (is_online and "online" or "offline"));
	end;
});

module:add_item("shell-command", {
	section = "user";
	section_desc = "View user activity data";
	name = "list_inactive";
	desc = "List inactive user accounts";
	args = {
		{ name = "host"; type = "string" };
		{ name = "duration"; type = "string" };
	};
	host_selector = "host";
	handler = function(self, host, duration) --luacheck: ignore 212/self
		local um = require "prosody.core.usermanager";
		local duration_sec = require "prosody.util.human.io".parse_duration(duration or "");
		if not duration_sec then
			return false, ("Invalid duration %q - try something like \"30d\""):format(duration);
		end

		local now = os.time();
		local n_inactive, n_unknown = 0, 0;

		for username in um.users(host) do
			local last_active = store:get_key(username, "timestamp");
			if not last_active then
				local created_at = um.get_account_info(username, host).created;
				if created_at and (now - created_at) > duration_sec then
					self.session.print(username, "");
					n_inactive = n_inactive + 1;
				elseif not created_at then
					n_unknown = n_unknown + 1;
				end
			elseif (now - last_active) > duration_sec then
				self.session.print(username, os.date("%Y-%m-%dT%T", last_active));
				n_inactive = n_inactive + 1;
			end
		end

		if n_unknown > 0 then
			return true, ("%d accounts inactive since %s (%d unknown)"):format(n_inactive, os.date("%Y-%m-%dT%T", now - duration_sec), n_unknown);
		end
		return true, ("%d accounts inactive since %s"):format(n_inactive, os.date("%Y-%m-%dT%T", now - duration_sec));
	end;
});

module:add_item("shell-command", {
	section = "migrate";
	section_desc = "Perform data migrations";
	name = "account_activity_lastlog2";
	desc = "Migrate account activity information from mod_lastlog2";
	args = { { name = "host"; type = "string" } };
	host_selector = "host";
	handler = function(self, host) --luacheck: ignore 212/host
		local lastlog2 = module:open_store("lastlog2", "keyval+");
		local n_updated, n_errors, n_skipped = 0, 0, 0;

		local async = require "prosody.util.async";

		local p = require "prosody.util.promise".new(function (resolve)
			local async_runner = async.runner(function ()
				local n = 0;
				for username in lastlog2:items() do
					n = n + 1;
					if n % 100 == 0 then
						self.session.print(("Processed %d..."):format(n));
						async.sleep(0);
					end
					local lastlog2_data = lastlog2:get(username);
					if lastlog2_data then
						local current_data, err = store:get(username);
						if not current_data then
							if not err then
								current_data = {};
							else
								n_errors = n_errors + 1;
							end
						end
						if current_data then
							local imported_timestamp = current_data.timestamp;
							local latest;
							for k, v in pairs(lastlog2_data) do
								if k ~= "registered" and (not latest or v.timestamp > latest) then
									latest = v.timestamp;
								end
							end
							if latest and (not imported_timestamp or imported_timestamp < latest) then
								local ok, err = store:set_key(username, "timestamp", latest);
								if ok then
									n_updated = n_updated + 1;
								else
									self.session.print(("WW: Failed to import %q: %s"):format(username, err));
									n_errors = n_errors + 1;
								end
							else
								n_skipped = n_skipped + 1;
							end
						end
					end
				end
				return resolve(("%d accounts imported, %d errors, %d skipped"):format(n_updated, n_errors, n_skipped));
			end);
			async_runner:run(true);
		end);
		return p;
	end;
});
