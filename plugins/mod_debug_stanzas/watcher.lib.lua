local filters = require "prosody.util.filters";
local jid = require "prosody.util.jid";
local set = require "prosody.util.set";

local client_watchers = {};

-- active_filters[session] = {
--   filter_func = filter_func;
--   downstream = { cb1, cb2, ... };
-- }
local active_filters = {};

local function subscribe_session_stanzas(session, handler, reason)
	if active_filters[session] then
		table.insert(active_filters[session].downstream, handler);
		if reason then
			handler(reason, nil, session);
		end
		return;
	end
	local downstream = { handler };
	active_filters[session] = {
		filter_in = function (stanza)
			module:log("debug", "NOTIFY WATCHER %d", #downstream);
			for i = 1, #downstream do
				downstream[i]("received", stanza, session);
			end
			return stanza;
		end;
		filter_out = function (stanza)
			module:log("debug", "NOTIFY WATCHER %d", #downstream);
			for i = 1, #downstream do
				downstream[i]("sent", stanza, session);
			end
			return stanza;
		end;
		downstream = downstream;
	};
	filters.add_filter(session, "stanzas/in", active_filters[session].filter_in);
	filters.add_filter(session, "stanzas/out", active_filters[session].filter_out);
	if reason then
		handler(reason, nil, session);
	end
end

local function unsubscribe_session_stanzas(session, handler, reason)
	local active_filter = active_filters[session];
	if not active_filter then
		return;
	end
	for i = #active_filter.downstream, 1, -1 do
		if active_filter.downstream[i] == handler then
			table.remove(active_filter.downstream, i);
			if reason then
				handler(reason, nil, session);
			end
		end
	end
	if #active_filter.downstream == 0 then
		filters.remove_filter(session, "stanzas/in", active_filter.filter_in);
		filters.remove_filter(session, "stanzas/out", active_filter.filter_out);
	end
	active_filters[session] = nil;
end

local function unsubscribe_all_from_session(session, reason)
	local active_filter = active_filters[session];
	if not active_filter then
		return;
	end
	for i = #active_filter.downstream, 1, -1 do
		local handler = table.remove(active_filter.downstream, i);
		if reason then
			handler(reason, nil, session);
		end
	end
	filters.remove_filter(session, "stanzas/in", active_filter.filter_in);
	filters.remove_filter(session, "stanzas/out", active_filter.filter_out);
	active_filters[session] = nil;
end

local function unsubscribe_handler_from_all(handler, reason)
	for session in pairs(active_filters) do
		unsubscribe_session_stanzas(session, handler, reason);
	end
end

local s2s_watchers = {};

module:hook("s2sin-established", function (event)
	for _, watcher in ipairs(s2s_watchers) do
		if watcher.target_spec == event.session.from_host then
			subscribe_session_stanzas(event.session, watcher.handler, "opened");
		end
	end
end);

module:hook("s2sout-established", function (event)
	for _, watcher in ipairs(s2s_watchers) do
		if watcher.target_spec == event.session.to_host then
			subscribe_session_stanzas(event.session, watcher.handler, "opened");
		end
	end
end);

module:hook("s2s-closed", function (event)
	unsubscribe_all_from_session(event.session, "closed");
end);

local watched_hosts = set.new();

local handler_map = setmetatable({}, { __mode = "kv" });

local function add_stanza_watcher(spec, orig_handler)
	local function filtering_handler(event_type, stanza, session)
		if stanza and spec.filter_spec then
			if spec.filter_spec.with_jid then
				if event_type == "sent" and (not stanza.attr.from or not jid.compare(stanza.attr.from, spec.filter_spec.with_jid)) then
					return;
				elseif event_type == "received" and (not stanza.attr.to or not jid.compare(stanza.attr.to, spec.filter_spec.with_jid)) then
					return;
				end
			end
		end
		return orig_handler(event_type, stanza, session);
	end
	handler_map[orig_handler] = filtering_handler;
	if spec.target_spec.jid then
		local target_is_remote_host = not jid.node(spec.target_spec.jid) and not prosody.hosts[spec.target_spec.jid];

		if target_is_remote_host then
			-- Watch s2s sessions
			table.insert(s2s_watchers, {
				target_spec = spec.target_spec.jid;
				handler = filtering_handler;
				orig_handler = orig_handler;
			});

			-- Scan existing s2sin for matches
			for session in pairs(prosody.incoming_s2s) do
				if spec.target_spec.jid == session.from_host then
					subscribe_session_stanzas(session, filtering_handler, "attached");
				end
			end
			-- Scan existing s2sout for matches
			for local_host, local_session in pairs(prosody.hosts) do --luacheck: ignore 213/local_host
				for remote_host, remote_session in pairs(local_session.s2sout) do
					if spec.target_spec.jid == remote_host then
						subscribe_session_stanzas(remote_session, filtering_handler, "attached");
					end
				end
			end
		else
			table.insert(client_watchers, {
				target_spec = spec.target_spec.jid;
				handler = filtering_handler;
				orig_handler = orig_handler;
			});
			local host = jid.host(spec.target_spec.jid);
			if not watched_hosts:contains(host) and prosody.hosts[host] then
				module:context(host):hook("resource-bind", function (event)
					for _, watcher in ipairs(client_watchers) do
						module:log("debug", "NEW CLIENT: %s vs %s", event.session.full_jid, watcher.target_spec);
						if jid.compare(event.session.full_jid, watcher.target_spec) then
							module:log("debug", "MATCH");
							subscribe_session_stanzas(event.session, watcher.handler, "opened");
						else
							module:log("debug", "NO MATCH");
						end
					end
				end);

				module:context(host):hook("resource-unbind", function (event)
					unsubscribe_all_from_session(event.session, "closed");
				end);

				watched_hosts:add(host);
			end
			for full_jid, session in pairs(prosody.full_sessions) do
				if jid.compare(full_jid, spec.target_spec.jid) then
					subscribe_session_stanzas(session, filtering_handler, "attached");
				end
			end
		end
	else
		error("No recognized target selector");
	end
end

local function remove_stanza_watcher(orig_handler)
	local handler = handler_map[orig_handler];
	unsubscribe_handler_from_all(handler, "detached");
	handler_map[orig_handler] = nil;

	for i = #client_watchers, 1, -1 do
		if client_watchers[i].orig_handler == orig_handler then
			table.remove(client_watchers, i);
		end
	end

	for i = #s2s_watchers, 1, -1 do
		if s2s_watchers[i].orig_handler == orig_handler then
			table.remove(s2s_watchers, i);
		end
	end
end

local function cleanup(reason)
	client_watchers = {};
	s2s_watchers = {};
	for session in pairs(active_filters) do
		unsubscribe_all_from_session(session, reason or "cancelled");
	end
end

return {
	add = add_stanza_watcher;
	remove = remove_stanza_watcher;
	cleanup = cleanup;
};
