-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local gettime = os.time;
local datetime = require "prosody.util.datetime";
local st = require "prosody.util.stanza";

local default_history_length = 20;
local max_history_length = module:get_option_integer("max_history_messages", math.huge, 0);

local function set_max_history_length(_max_history_length)
	max_history_length = _max_history_length or math.huge;
end

local function get_historylength(room)
	return math.min(room._data.history_length or default_history_length, max_history_length);
end

local function set_historylength(room, length)
	if length then
		length = assert(tonumber(length), "Length not a valid number");
	end
	if length == default_history_length then length = nil; end
	room._data.history_length = length;
	return true;
end

-- Fix for clients who don't support XEP-0045 correctly
-- Default number of history messages the room returns
local function get_defaulthistorymessages(room)
	return room._data.default_history_messages or default_history_length;
end
local function set_defaulthistorymessages(room, number)
	number = math.min(tonumber(number) or default_history_length, room._data.history_length or default_history_length);
	if number == default_history_length then
		number = nil;
	end
	room._data.default_history_messages = number;
end

module:hook("muc-config-form", function(event)
	table.insert(event.form, {
		name = "muc#roomconfig_historylength";
		type = "text-single";
		datatype = "xs:integer";
		label = "Maximum number of history messages returned by room";
		desc = "Specify the maximum number of previous messages that should be sent to users when they join the room";
		value = get_historylength(event.room);
	});
	table.insert(event.form, {
		name = 'muc#roomconfig_defaulthistorymessages',
		type = 'text-single',
		datatype = "xs:integer";
		label = 'Default number of history messages returned by room',
		desc = "Specify the number of previous messages sent to new users when they join the room";
		value = get_defaulthistorymessages(event.room);
	});
end, 70-5);

module:hook("muc-config-submitted/muc#roomconfig_historylength", function(event)
	if set_historylength(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

module:hook("muc-config-submitted/muc#roomconfig_defaulthistorymessages", function(event)
	if set_defaulthistorymessages(event.room, event.value) then
		event.status_codes["104"] = true;
	end
end);

local function parse_history(stanza)
	local x_tag = stanza:get_child("x", "http://jabber.org/protocol/muc");
	local history_tag = x_tag and x_tag:get_child("history", "http://jabber.org/protocol/muc");
	if not history_tag then
		return nil, nil, nil;
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
	local history = room._history; -- send discussion history
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
	function event.next_stanza()
		if i > history_len then return nil end
		local entry = history[i];
		local msg = entry.stanza;
		msg.attr.to = to;
		i = i + 1;
		return msg;
	end
	return true;
end, -1);

local function send_history(room, stanza)
	local maxchars, maxstanzas, since = parse_history(stanza);
	if not(maxchars or maxstanzas or since) then
		maxstanzas = get_defaulthistorymessages(room);
	end
	local event = {
		room = room;
		stanza = stanza;
		to = stanza.attr.from; -- `to` is required to calculate the character count for `maxchars`
		maxchars = maxchars,
		maxstanzas = maxstanzas,
		since = since;
		next_stanza = function() end; -- events should define this iterator
	};
	module:fire_event("muc-get-history", event);
	for msg in event.next_stanza, event do
		room:route_stanza(msg);
	end
end

-- Send history on join
module:hook("muc-occupant-session-new", function(event)
	send_history(event.room, event.stanza);
end, 50); -- Before subject(20)

-- add to history
module:hook("muc-add-history", function(event)
	local room = event.room
	if get_historylength(room) == 0 then
		room._history = nil;
		return;
	end
	local history = room._history;
	if not history then history = {}; room._history = history; end
	local stanza = st.clone(event.stanza);
	stanza.attr.to = "";
	local ts = gettime();
	local stamp = datetime.datetime(ts);
	stanza:tag("delay", { -- XEP-0203
		xmlns = "urn:xmpp:delay", from = room.jid, stamp = stamp
	}):up();
	local entry = { stanza = stanza, timestamp = ts };
	table.insert(history, entry);
	while #history > get_historylength(room) do table.remove(history, 1) end
	return true;
end, -1);

-- Have a single muc-add-history event, so that plugins can mark it
-- as handled without stopping other muc-broadcast-message handlers
module:hook("muc-broadcast-message", function(event)
	if module:fire_event("muc-message-is-historic", event) then
		module:fire_event("muc-add-history", event);
	end
end);

module:hook("muc-message-is-historic", function (event)
	local stanza = event.stanza;
	if stanza:get_child("no-store", "urn:xmpp:hints")
	or stanza:get_child("no-permanent-store", "urn:xmpp:hints") then
		return false, "hint";
	end
	if stanza:get_child("store", "urn:xmpp:hints") then
		return true, "hint";
	end
	if stanza:get_child("body") then
		return true;
	end
	if stanza:get_child("encryption", "urn:xmpp:eme:0") then
		-- Since we can't know what an encrypted message contains, we assume it's important
		-- XXX Experimental XEP
		return true, "encrypted";
	end
	if stanza:get_child(nil, "urn:xmpp:chat-markers:0") then
		return true, "marker";
	end
end, -1);

return {
	set_max_length = set_max_history_length;
	parse_history = parse_history;
	send = send_history;
	get_length = get_historylength;
	set_length = set_historylength;
};
