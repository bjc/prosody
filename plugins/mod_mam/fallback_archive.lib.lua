-- Prosody IM
-- Copyright (C) 2008-2017 Matthew Wild
-- Copyright (C) 2008-2017 Waqas Hussain
-- Copyright (C) 2011-2017 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
-- luacheck: ignore 212/self

local uuid = require "util.uuid".generate;
local store = module:shared("archive");
local archive_store = { _provided_by = "mam"; name = "fallback"; };

function archive_store:append(username, key, value, when, with)
	local archive = store[username];
	if not archive then
		archive = { [0] = 0 };
		store[username] = archive;
	end
	local index = (archive[0] or #archive)+1;
	local item = { key = key, when = when, with = with, value = value };
	if not key or archive[key] then
		key = uuid();
		item.key = key;
	end
	archive[index] = item;
	archive[key] = index;
	archive[0] = index;
	return key;
end

function archive_store:find(username, query)
	local archive = store[username] or {};
	local start, stop, step = 1, archive[0] or #archive, 1;
	local qstart, qend, qwith = -math.huge, math.huge;
	local limit;

	if query then
		if query.reverse then
			start, stop, step = stop, start, -1;
			if query.before and archive[query.before] then
				start = archive[query.before] - 1;
			end
		elseif query.after and archive[query.after] then
			start = archive[query.after] + 1;
		end
		qwith = query.with;
		limit = query.limit;
		qstart = query.start or qstart;
		qend = query["end"] or qend;
	end

	return function ()
		if limit and limit <= 0 then return end
		for i = start, stop, step do
			local item = archive[i];
			if (not qwith or qwith == item.with) and item.when >= qstart and item.when <= qend then
				if limit then limit = limit - 1; end
				start = i + step; -- Start on next item
				return item.key, item.value, item.when, item.with;
			end
		end
	end
end

function archive_store:delete(username, query)
	if not query or next(query) == nil then
		-- no specifics, delete everything
		store[username] = nil;
		return true;
	end
	local archive = store[username];
	if not archive then return true; end -- no messages, nothing to delete

	local qstart = query.start or -math.huge;
	local qend = query["end"] or math.huge;
	local qwith = query.with;
		store[username] = nil;
	for i = 1, #archive do
		local item = archive[i];
		local when, with = item.when, item.when;
		-- Add things that don't match the query
		if not ((not qwith or qwith == item.with) and item.when >= qstart and item.when <= qend) then
			self:append(username, item.key, item.value, when, with);
		end
	end
	return true;
end

return archive_store;
