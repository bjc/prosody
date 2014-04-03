-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local gettime = os.time;
local datetime = require "util.datetime";
local st = require "util.stanza";

local default_history_length, max_history_length = 20, math.huge;

local function set_max_history_length(_max_history_length)
	max_history_length = _max_history_length or math.huge;
end

local function get_historylength(room)
	return math.min(room._data.history_length or default_history_length, max_history_length);
end

local function set_historylength(room, length)
	length = assert(tonumber(length), "Length not a valid number");
	if length == default_history_length then length = nil; end
	room._data.history_length = length;
	return true;
end

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_historylength";
		type = "text-single";
		label = "Maximum Number of History Messages Returned by Room";
		value = tostring(get_historylength(event.room));
	});
end);

module:hook("muc-config-submitted", function(event)
	local new = event.fields["muc#roomconfig_historylength"];
	if new ~= nil and set_historylength(event.room, new) then
		event.status_codes["104"] = true;
	end
end);

local function parse_history(stanza)
	local x_tag = stanza:get_child("x", "http://jabber.org/protocol/muc");
	local history_tag = x_tag and x_tag:get_child("history", "http://jabber.org/protocol/muc");
	if not history_tag then
		return nil, default_history_length, nil;
	end

	local maxchars = tonumber(history_tag.attr.maxchars);

	local maxstanzas = tonumber(history_tag.attr.maxstanzas);

	-- messages received since the UTC datetime specified
	local since = history_tag.attr.since;
	if since then
		since = datetime.parse(since);
	end

	-- messages received in the last "X" seconds.
	local seconds = tonumber(history_tag.attr.seconds);
	if seconds then
		seconds = gettime() - seconds;
		if since then
			since = math.max(since, seconds);
		else
			since = seconds;
		end
	end

	return maxchars, maxstanzas, since;
end

module:hook("muc-get-history", function(event)
	local room = event.room;
	local history = room._data["history"]; -- send discussion history
	if not history then return nil end
	local history_len = #history;

	local to = event.to;
	local maxchars = event.maxchars;
	local maxstanzas = event.maxstanzas or history_len;
	local since = event.since;
	local n = 0;
	local charcount = 0;
	for i=history_len,1,-1 do
		local entry = history[i];
		if maxchars then
			if not entry.chars then
				entry.stanza.attr.to = "";
				entry.chars = #tostring(entry.stanza);
			end
			charcount = charcount + entry.chars + #to;
			if charcount > maxchars then break; end
		end
		if since and since > entry.timestamp then break; end
		if n + 1 > maxstanzas then break; end
		n = n + 1;
	end

	local i = history_len-n+1
	function event:next_stanza()
		if i > history_len then return nil end
		local entry = history[i];
		local msg = entry.stanza;
		msg.attr.to = to;
		i = i + 1;
		return msg;
	end
	return true;
end);

local function send_history(room, stanza)
	local maxchars, maxstanzas, since = parse_history(stanza);
	local event = {
		room = room;
		to = stanza.attr.from; -- `to` is required to calculate the character count for `maxchars`
		maxchars = maxchars, maxstanzas = maxstanzas, since = since;
		next_stanza = function() end; -- events should define this iterator
	};
	module:fire_event("muc-get-history", event);
	for msg in event.next_stanza, event do
		room:route_stanza(msg);
	end
end

-- Send history on join
module:hook("muc-occupant-joined", function(event)
	send_history(event.room, event.stanza);
end, 50); -- Between occupant list (80) and subject(20)

-- add to history
module:hook("muc-broadcast-message", function(event)
	local historic = event.stanza:get_child("body");
	if historic then
		local room = event.room
		local history = room._data["history"];
		if not history then history = {}; room._data["history"] = history; end
		local stanza = st.clone(event.stanza);
		stanza.attr.to = "";
		local ts = gettime();
		local stamp = datetime.datetime(ts);
		stanza:tag("delay", {xmlns = "urn:xmpp:delay", from = module.host, stamp = stamp}):up(); -- XEP-0203
		stanza:tag("x", {xmlns = "jabber:x:delay", from = module.host, stamp = datetime.legacy()}):up(); -- XEP-0091 (deprecated)
		local entry = { stanza = stanza, timestamp = ts };
		table.insert(history, entry);
		while #history > get_historylength(room) do table.remove(history, 1) end
	end
end);

return {
	set_max_length = set_max_history_length;
	parse_history = parse_history;
	send = send_history;
	get_length = get_historylength;
	set_length = set_historylength;
};
