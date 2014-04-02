-- Prosody IM
-- Copyright (C) 2008-2010 Matthew Wild
-- Copyright (C) 2008-2010 Waqas Hussain
-- Copyright (C) 2014 Daurnimator
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local lock_rooms = module:get_option_boolean("muc_room_locking", false);
local lock_room_timeout = module:get_option_number("muc_room_lock_timeout", 300);

local function lock(room)
	module:fire_event("muc-room-locked", {room = room;});
	room.locked = true;
end
local function unlock(room)
	module:fire_event("muc-room-unlocked", {room = room;});
	room.locked = nil;
end
local function is_locked(room)
	return not not room.locked;
end

if lock_rooms then
	module:hook("muc-room-created", function(event)
		local room = event.room;
		lock(room);
		if lock_room_timeout and lock_room_timeout > 0 then
			module:add_timer(lock_room_timeout, function ()
				if is_locked(room) then
					room:destroy(); -- Not unlocked in time
				end
			end);
		end
	end);
end

-- Older groupchat protocol doesn't lock
module:hook("muc-room-pre-create", function(event)
	if is_locked(event.room) and not event.stanza:get_child("x", "http://jabber.org/protocol/muc") then
		unlock(event.room);
	end
end, 10);

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
