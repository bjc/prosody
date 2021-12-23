-- TODO warn when trying to create an user before the tombstone expires
-- e.g. via telnet or other admin interface
local datetime = require "util.datetime";
local errors = require "util.error";
local jid_split = require"util.jid".split;
local st = require "util.stanza";

-- Using a map store as key-value store so that removal of all user data
-- does not also remove the tombstone, which would defeat the point
local graveyard = module:open_store(nil, "map");

local ttl = module:get_option_number("user_tombstone_expiry", nil);
-- Keep tombstones forever by default
--
-- Rationale:
-- There is no way to be completely sure when remote services have
-- forgotten and revoked all memberships.

module:hook_global("user-deleted", function(event)
	if event.host == module.host then
		local ok, err = graveyard:set(nil, event.username, os.time());
		if not ok then module:log("error", "Could store tombstone for %s: %s", event.username, err); end
	end
end);

-- Public API
function has_tombstone(username)
	local tombstone, err = graveyard:get(nil, username);

	if err or not tombstone then return tombstone, err; end

	if ttl and tombstone + ttl < os.time() then
		module:log("debug", "Tombstone for %s created at %s has expired", username, datetime.datetime(tombstone));
		graveyard:set(nil, username, nil);
		return nil;
	end
	return tombstone;
end

module:hook("user-registering", function(event)
	local tombstone, err = has_tombstone(event.username);

	if err then
		event.allowed, event.error = errors.coerce(false, err);
		return true;
	elseif not tombstone then
		-- Feel free
		return;
	end

	module:log("debug", "Tombstone for %s created at %s", event.username, datetime.datetime(tombstone));
	event.allowed = false;
	return true;
end);

module:hook("presence/bare", function(event)
	local origin, presence = event.origin, event.stanza;

	-- We want to undo any left-over presence subscriptions and notify the former
	-- contact that they're gone.
	--
	-- FIXME This leaks that the user once existed. Hard to avoid without keeping
	-- the contact list in some form, which we don't want to do for privacy
	-- reasons.  Bloom filter perhaps?
	if has_tombstone(jid_split(presence.attr.to)) then
		if presence.attr.type == "probe" then
			origin.send(st.error_reply(presence, "cancel", "gone", "User deleted"));
			origin.send(st.presence({ type = "unsubscribed"; to = presence.attr.from; from = presence.attr.to }));
		elseif presence.attr.type == nil or presence.attr.type == "unavailable" then
			origin.send(st.error_reply(presence, "cancel", "gone", "User deleted"));
			origin.send(st.presence({ type = "unsubscribe"; to = presence.attr.from; from = presence.attr.to }));
		end
		return true;
	end
end, 1);
