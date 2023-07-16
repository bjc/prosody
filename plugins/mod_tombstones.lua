-- TODO warn when trying to create an user before the tombstone expires
-- e.g. via telnet or other admin interface
local datetime = require "prosody.util.datetime";
local errors = require "prosody.util.error";
local jid_node = require"prosody.util.jid".node;
local st = require "prosody.util.stanza";

-- Using a map store as key-value store so that removal of all user data
-- does not also remove the tombstone, which would defeat the point
local graveyard = module:open_store(nil, "map");
local graveyard_cache = require "prosody.util.cache".new(module:get_option_integer("tombstone_cache_size", 1024, 1));

local ttl = module:get_option_period("user_tombstone_expiry", nil);
-- Keep tombstones forever by default
--
-- Rationale:
-- There is no way to be completely sure when remote services have
-- forgotten and revoked all memberships.

-- TODO If the user left a JID they moved to, return a gone+redirect error
-- TODO Attempt to deregister from MUCs based on bookmarks
-- TODO Unsubscribe from pubsub services if a notification is received

module:hook_global("user-deleted", function(event)
	if event.host == module.host then
		local ok, err = graveyard:set(nil, event.username, os.time());
		if not ok then module:log("error", "Could store tombstone for %s: %s", event.username, err); end
	end
end);

-- Public API
function has_tombstone(username)
	local tombstone;

	-- Check cache
	local cached_result = graveyard_cache:get(username);
	if cached_result == false then
		-- We cached that there is no tombstone for this user
		return false;
	elseif cached_result then
		tombstone = cached_result;
	else
		local stored_result, err = graveyard:get(nil, username);
		if not stored_result and not err then
			-- Cache that there is no tombstone for this user
			graveyard_cache:set(username, false);
			return false;
		elseif err then
			-- Failed to check tombstone status
			return nil, err;
		end
		-- We have a tombstone stored, so let's continue with that
		tombstone = stored_result;
	end

	-- Check expiry
	if ttl and tombstone + ttl < os.time() then
		module:log("debug", "Tombstone for %s created at %s has expired", username, datetime.datetime(tombstone));
		graveyard:set(nil, username, nil);
		graveyard_cache:set(username, nil); -- clear cache entry (if any)
		return nil;
	end

	-- Cache for the future
	graveyard_cache:set(username, tombstone);

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
	local local_username = jid_node(presence.attr.to);
	if not local_username then return; end

	-- We want to undo any left-over presence subscriptions and notify the former
	-- contact that they're gone.
	--
	-- FIXME This leaks that the user once existed. Hard to avoid without keeping
	-- the contact list in some form, which we don't want to do for privacy
	-- reasons.  Bloom filter perhaps?

	local pres_type = presence.attr.type;
	local is_probe = pres_type == "probe";
	local is_normal = pres_type == nil or pres_type == "unavailable";
	if is_probe and has_tombstone(local_username) then
		origin.send(st.error_reply(presence, "cancel", "gone", "User deleted"));
		origin.send(st.presence({ type = "unsubscribed"; to = presence.attr.from; from = presence.attr.to }));
		return true;
	elseif is_normal and has_tombstone(local_username) then
		origin.send(st.error_reply(presence, "cancel", "gone", "User deleted"));
		origin.send(st.presence({ type = "unsubscribe"; to = presence.attr.from; from = presence.attr.to }));
		return true;
	end
end, 1);
