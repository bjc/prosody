local base64 = require "prosody.util.encodings".base64;
local hashes = require "prosody.util.hashes";
local id = require "prosody.util.id";
local jid = require "prosody.util.jid";
local random = require "prosody.util.random";
local usermanager = require "prosody.core.usermanager";
local generate_identifier = require "prosody.util.id".short;

local token_store = module:open_store("auth_tokens", "keyval+");

local access_time_granularity = module:get_option_period("token_auth_access_time_granularity", 60);
local empty_grant_lifetime = module:get_option_period("tokenless_grant_ttl", "2w");

local function select_role(username, host, role_name)
	if not role_name then return end
	local role = usermanager.get_role_by_name(role_name, host);
	if not role then return end
	if not usermanager.user_can_assume_role(username, host, role.name) then return end
	return role;
end

function create_grant(actor_jid, grant_jid, grant_ttl, grant_data)
	grant_jid = jid.prep(grant_jid);
	if not actor_jid or actor_jid ~= grant_jid and not jid.compare(grant_jid, actor_jid) then
		module:log("debug", "Actor <%s> is not permitted to create a token granting access to JID <%s>", actor_jid, grant_jid);
		return nil, "not-authorized";
	end

	local grant_username, grant_host, grant_resource = jid.split(grant_jid);

	if grant_host ~= module.host then
		return nil, "invalid-host";
	end

	local grant_id = id.short();
	local now = os.time();

	local grant = {
		id = grant_id;

		owner = actor_jid;
		created = now;
		expires = grant_ttl and (now + grant_ttl) or nil;
		accessed = now;

		jid = grant_jid;
		resource = grant_resource;

		data = grant_data;

		-- tokens[<hash-name>..":"..<secret>] = token_info
		tokens = {};
	};

	local ok, err = token_store:set_key(grant_username, grant_id, grant);
	if not ok then
		return nil, err;
	end

	module:fire_event("token-grant-created", {
		id = grant_id;
		grant = grant;
		username = grant_username;
		host = grant_host;
	});

	return grant;
end

function create_token(grant_jid, grant, token_role, token_ttl, token_purpose, token_data)
	if (token_data and type(token_data) ~= "table") or (token_purpose and type(token_purpose) ~= "string") then
		return nil, "bad-request";
	end
	local grant_username, grant_host = jid.split(grant_jid);
	if grant_host ~= module.host then
		return nil, "invalid-host";
	end
	if type(grant) == "string" then -- lookup by id
		grant = token_store:get_key(grant_username, grant);
		if not grant then return nil; end
	end

	if not grant.tokens then return nil, "internal-server-error"; end -- old-style token?

	local now = os.time();
	local expires = grant.expires; -- Default to same expiry as grant
	if token_ttl then -- explicit lifetime requested
		if expires then
			-- Grant has an expiry, so limit to that or shorter
			expires = math.min(now + token_ttl, expires);
		else
			-- Grant never expires, just use whatever expiry is requested for the token
			expires = now + token_ttl;
		end
	end

	local token_info = {
		role = token_role;

		created = now;
		expires = expires;
		purpose = token_purpose;

		data = token_data;
	};

	local token_secret = random.bytes(18);
	grant.tokens["sha256:"..hashes.sha256(token_secret, true)] = token_info;

	local ok, err = token_store:set_key(grant_username, grant.id, grant);
	if not ok then
		return nil, err;
	end

	local token_string = "secret-token:"..base64.encode("2;"..grant.id..";"..token_secret..";"..grant.jid);
	return token_string, token_info;
end

local function parse_token(encoded_token)
	if not encoded_token then return nil; end
	local encoded_data = encoded_token:match("^secret%-token:(.+)$");
	if not encoded_data then return nil; end
	local token = base64.decode(encoded_data);
	if not token then return nil; end
	local token_id, token_secret, token_jid = token:match("^2;([^;]+);(..................);(.+)$");
	if not token_id then return nil; end
	local token_user, token_host = jid.split(token_jid);
	return token_id, token_user, token_host, token_secret;
end

local function clear_expired_grant_tokens(grant, now)
	local updated;
	now = now or os.time();
	for secret, token_info in pairs(grant.tokens) do
		local expires = token_info.expires;
		if expires and expires <= now then
			grant.tokens[secret] = nil;
			updated = true;
		end
	end
	return updated;
end

local function _get_validated_grant_info(username, grant)
	if type(grant) == "string" then
		grant = token_store:get_key(username, grant);
	end
	if not grant or not grant.created or not grant.id then return nil; end

	-- Invalidate grants from before last password change
	local account_info = usermanager.get_account_info(username, module.host);
	local password_updated_at = account_info and account_info.password_updated;
	local now = os.time();
	if password_updated_at and grant.created < password_updated_at then
		module:log("debug", "Token grant %s of %s issued before last password change, invalidating it now", grant.id, username);
		token_store:set_key(username, grant.id, nil);
		return nil, "not-authorized";
	elseif grant.expires and grant.expires <= now then
		module:log("debug", "Token grant %s of %s expired, cleaning up", grant.id, username);
		token_store:set_key(username, grant.id, nil);
		return nil, "expired";
	end

	if not grant.tokens then
		module:log("debug", "Token grant %s of %s without tokens, cleaning up", grant.id, username);
		token_store:set_key(username, grant.id, nil);
		return nil, "invalid";
	end

	local found_expired = false
	for secret_hash, token_info in pairs(grant.tokens) do
		if token_info.expires and token_info.expires <= now then
			module:log("debug", "Token %s of grant %s of %s has expired, cleaning it up", secret_hash:sub(-8), grant.id, username);
			grant.tokens[secret_hash] = nil;
			found_expired = true;
		end
	end

	if not grant.expires and next(grant.tokens) == nil and grant.accessed + empty_grant_lifetime <= now then
		module:log("debug", "Token %s of %s grant has no tokens, discarding", grant.id, username);
		token_store:set_key(username, grant.id, nil);
		return nil, "expired";
	elseif found_expired then
		token_store:set_key(username, grant.id, grant);
	end

	return grant;
end

local function _get_validated_token_info(token_id, token_user, token_host, token_secret)
	if token_host ~= module.host then
		return nil, "invalid-host";
	end

	local grant, err = token_store:get_key(token_user, token_id);
	if not grant or not grant.tokens then
		if err then
			module:log("error", "Unable to read from token storage: %s", err);
			return nil, "internal-error";
		end
		module:log("warn", "Invalid token in storage (%s / %s)", token_user, token_id);
		return nil, "not-authorized";
	end

	-- Check provided secret
	local secret_hash = "sha256:"..hashes.sha256(token_secret, true);
	local token_info = grant.tokens[secret_hash];
	if not token_info then
		module:log("debug", "No tokens matched the given secret");
		return nil, "not-authorized";
	end

	-- Check expiry
	local now = os.time();
	if token_info.expires and token_info.expires <= now then
		module:log("debug", "Token has expired, cleaning it up");
		grant.tokens[secret_hash] = nil;
		token_store:set_key(token_user, token_id, grant);
		return nil, "not-authorized";
	end

	-- Verify grant validity (expiry, etc.)
	grant = _get_validated_grant_info(token_user, grant);
	if not grant then
		return nil, "not-authorized";
	end

	-- Update last access time if necessary
	local last_accessed = grant.accessed;
	if not last_accessed or (now - last_accessed) > access_time_granularity then
		grant.accessed = now;
		clear_expired_grant_tokens(grant); -- Clear expired tokens while we're here
		token_store:set_key(token_user, token_id, grant);
	end

	token_info.id = token_id;
	token_info.grant = grant;
	token_info.jid = grant.jid;

	return token_info;
end

function get_grant_info(username, grant_id)
	local grant = _get_validated_grant_info(username, grant_id);
	if not grant then return nil; end

	-- Caller is only interested in the grant, no need to expose token stuff to them
	grant.tokens = nil;

	return grant;
end

function get_user_grants(username)
	local grants = token_store:get(username);
	if not grants then return nil; end
	for grant_id, grant in pairs(grants) do
		grants[grant_id] = _get_validated_grant_info(username, grant);
	end
	return grants;
end

function get_token_info(token)
	local token_id, token_user, token_host, token_secret = parse_token(token);
	if not token_id then
		module:log("warn", "Failed to verify access token: %s", token_user);
		return nil, "invalid-token-format";
	end
	return _get_validated_token_info(token_id, token_user, token_host, token_secret);
end

function get_token_session(token, resource)
	local token_id, token_user, token_host, token_secret = parse_token(token);
	if not token_id then
		module:log("warn", "Failed to verify access token: %s", token_user);
		return nil, "invalid-token-format";
	end

	local token_info, err = _get_validated_token_info(token_id, token_user, token_host, token_secret);
	if not token_info then return nil, err; end

	local role = select_role(token_user, token_host, token_info.role);
	if not role then return nil, "not-authorized"; end
	return {
		username = token_user;
		host = token_host;
		resource = token_info.resource or resource or generate_identifier();

		role = role;
	};
end

function revoke_token(token)
	local grant_id, token_user, token_host, token_secret = parse_token(token);
	if not grant_id then
		module:log("warn", "Failed to verify access token: %s", token_user);
		return nil, "invalid-token-format";
	end
	if token_host ~= module.host then
		return nil, "invalid-host";
	end
	local grant, err = _get_validated_grant_info(token_user, grant_id);
	if not grant then return grant, err; end
	local secret_hash = "sha256:"..hashes.sha256(token_secret, true);
	local token_info = grant.tokens[secret_hash];
	if not grant or not token_info then
		return nil, "item-not-found";
	end
	grant.tokens[secret_hash] = nil;
	local ok, err = token_store:set_key(token_user, grant_id, grant);
	if not ok then
		return nil, err;
	end
	module:fire_event("token-revoked", {
		grant_id = grant_id;
		grant = grant;
		info = token_info;
		username = token_user;
		host = token_host;
	});
	return true;
end

function revoke_grant(username, grant_id)
	local ok, err = token_store:set_key(username, grant_id, nil);
	if not ok then return nil, err; end
	module:fire_event("token-grant-revoked", { id = grant_id, username = username, host = module.host });
	return true;
end

function sasl_handler(auth_provider, purpose, extra)
	return function (sasl, token, realm, _authzid)
		local token_info, err = get_token_info(token);
		if not token_info then
			module:log("debug", "SASL handler failed to verify token: %s", err);
			return nil, nil, extra;
		end
		local token_user, token_host, resource = jid.split(token_info.grant.jid);
		if realm ~= token_host or (purpose and token_info.purpose ~= purpose) then
			return nil, nil, extra;
		end
		if auth_provider.is_enabled and not auth_provider.is_enabled(token_user) then
			return true, false, token_info;
		end
		sasl.resource = resource;
		sasl.token_info = token_info;
		return token_user, true, token_info;
	end;
end

module:daily("clear expired grants", function()
	for username in token_store:items() do
		get_user_grants(username); -- clears out expired grants
	end
end)
