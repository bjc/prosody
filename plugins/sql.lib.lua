local cache = module:shared("/*/sql.lib/util.sql");

if not cache._M then
	prosody.unlock_globals();
	cache._M = require "util.sql";
	prosody.lock_globals();
end

return cache._M;
