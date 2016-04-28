-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local st = require "util.stanza";

local lock_rooms = module:get_option_boolean("muc_room_locking", false);
local lock_room_timeout = module:get_option_number("muc_room_lock_timeout", 300);

local function lock(room)
	module:fire_event("muc-room-locked", {room = room;});
	room._data.locked = os.time() + lock_room_timeout;
end
local function unlock(room)
	module:fire_event("muc-room-unlocked", {room = room;});
	room._data.locked = nil;
end
local function is_locked(room)
	local ts = room._data.locked or false;
	if ts then
		if ts < os.time() then return true; end
		unlock(room);
	end
	return false;
end

if lock_rooms then
	module:hook("muc-room-pre-create", function(event)
		-- Older groupchat protocol doesn't lock
		if not event.stanza:get_child("x", "http://jabber.org/protocol/muc") then return end
		-- Lock room at creation
		local room = event.room;
		lock(room);
	end, 10);
end

-- Don't let users into room while it is locked
module:hook("muc-occupant-pre-join", function(event)
	if not event.is_new_room and is_locked(event.room) then -- Deny entry
		event.origin.send(st.error_reply(event.stanza, "cancel", "item-not-found"));
		return true;
	end
end, -30);

-- When config is submitted; unlock the room
module:hook("muc-config-submitted", function(event)
	if is_locked(event.room) then
		unlock(event.room);
	end
end, -1);

return {
	lock = lock;
	unlock = unlock;
	is_locked = is_locked;
};
