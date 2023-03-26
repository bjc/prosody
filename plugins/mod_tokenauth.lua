local base64 = require "prosody.util.encodings".base64;
local hashes = require "prosody.util.hashes";
local id = require "prosody.util.id";
local jid = require "prosody.util.jid";
local random = require "prosody.util.random";
local usermanager = require "prosody.core.usermanager";
local generate_identifier = require "prosody.util.id".short;

local token_store = module:open_store("auth_tokens", "map");

local access_time_granularity = module:get_option_number("token_auth_access_time_granularity", 60);

local function select_role(username, host, role)
	if role then
		return prosody.hosts[host].authz.get_role_by_name(role);
	end
	return usermanager.get_user_role(username, host);
end

function create_jid_token(actor_jid, token_jid, token_role, token_ttl, token_data, token_purpose)
	token_jid = jid.prep(token_jid);
	if not actor_jid or token_jid ~= actor_jid and not jid.compare(token_jid, actor_jid) then
		return nil, "not-authorized";
	end

	local token_username, token_host, token_resource = jid.split(token_jid);

	if token_host ~= module.host then
		return nil, "invalid-host";
	end

	if (token_data and type(token_data) ~= "table") or (token_purpose and type(token_purpose) ~= "string") then
		return nil, "bad-request";
	end

	local token_id = id.short();

	local now = os.time();

	local token_info = {
		id = token_id;

		owner = actor_jid;
		created = now;
		expires = token_ttl and (now + token_ttl) or nil;
		accessed = now;
		jid = token_jid;
		purpose = token_purpose;

		resource = token_resource;
		role = token_role;
		data = token_data;
	};

	local token_secret = random.bytes(18);
	local token = "secret-token:"..base64.encode("2;"..token_id..";"..token_secret..";"..jid.join(token_username, token_host));
	local ok, err = token_store:set(token_username, token_id, {
		secret_sha256 = hashes.sha256(token_secret, true);
		token_info = token_info
	});
	if not ok then
		return nil, err;
	end

	return token, token_info;
end

function create_sub_token(actor_jid, parent_id, token_role, token_ttl, token_data, token_purpose)
	local username, host = jid.split(actor_jid);
	if host ~= module.host then
		return nil, "invalid-host";
	end

	if (token_data and type(token_data) ~= "table") or (token_purpose and type(token_purpose) ~= "string") then
		return nil, "bad-request";
	end

	-- Find parent token
	local parent_token = token_store:get(username, parent_id);
	if not parent_token then return nil; end
	local token_info = parent_token.token_info;

	local now = os.time();
	local expires = token_info.expires; -- Default to same expiry as parent token
	if token_ttl then
		if expires then
			-- Parent token has an expiry, so limit to that or shorter
			expires = math.min(now + token_ttl, expires);
		else
			-- Parent token never expires, just add whatever expiry is requested
			expires = now + token_ttl;
		end
	end

	local sub_token_info = {
		id = parent_id;
		type = "subtoken";
		role = token_role or token_info.role;
		jid = token_info.jid;
		created = now;
		expires = expires;
		purpose = token_purpose or token_info.purpose;
		data = token_data;
	};

	local sub_tokens = parent_token.sub_tokens;
	if not sub_tokens then
		sub_tokens = {};
		parent_token.sub_tokens = sub_tokens;
	end

	local sub_token_secret = random.bytes(18);
	sub_tokens[hashes.sha256(sub_token_secret, true)] = sub_token_info;

	local sub_token = "secret-token:"..base64.encode("2;"..token_info.id..";"..sub_token_secret..";"..token_info.jid);

	local ok, err = token_store:set(username, parent_id, parent_token);
	if not ok then
		return nil, err;
	end

	return sub_token, sub_token_info;
end

local function clear_expired_sub_tokens(username, token_id)
	local sub_tokens = token_store:get_key(username, token_id, "sub_tokens");
	if not sub_tokens then return; end
	local now = os.time();
	for secret, info in pairs(sub_tokens) do
		if info.expires < now then
			sub_tokens[secret] = nil;
		end
	end
end

local function parse_token(encoded_token)
	if not encoded_token then return nil; end
	local encoded_data = encoded_token:match("^secret%-token:(.+)$");
	if not encoded_data then return nil; end
	local token = base64.decode(encoded_data);
	if not token then return nil; end
	local token_id, token_secret, token_jid = token:match("^2;([^;]+);([^;]+);(.+)$");
	if not token_id then return nil; end
	local token_user, token_host = jid.split(token_jid);
	return token_id, token_user, token_host, token_secret;
end

local function _validate_token_info(token_user, token_id, token_info, sub_token_info)
	local now = os.time();
	if token_info.expires and token_info.expires < now then
		if token_info.type == "subtoken" then
			clear_expired_sub_tokens(token_user, token_id);
		else
			token_store:set(token_user, token_id, nil);
		end
		return nil, "not-authorized";
	end

	if token_info.type ~= "subtoken" then
		local account_info = usermanager.get_account_info(token_user, module.host);
		local password_updated_at = account_info and account_info.password_updated;
		if password_updated_at and password_updated_at > token_info.created then
			token_store:set(token_user, token_id, nil);
			return nil, "not-authorized";
		end

		-- Update last access time if necessary
		local last_accessed = token_info.accessed;
		if not last_accessed or (now - last_accessed) > access_time_granularity then
			token_info.accessed = now;
			token_store:set_key(token_user, token_id, "token_info", token_info);
		end
	end

	if sub_token_info then
		-- Parent token validated, now validate (and return) the subtoken
		return _validate_token_info(token_user, token_id, sub_token_info);
	end

	return token_info
end

local function _get_validated_token_info(token_id, token_user, token_host, token_secret)
	if token_host ~= module.host then
		return nil, "invalid-host";
	end

	local token, err = token_store:get(token_user, token_id);
	if not token then
		if err then
			return nil, "internal-error";
		end
		return nil, "not-authorized";
	elseif not token.secret_sha256 then -- older token format
		token_store:set(token_user, token_id, nil);
		return nil, "not-authorized";
	end

	-- Check provided secret
	local secret_hash = hashes.sha256(token_secret, true);
	if not hashes.equals(secret_hash, token.secret_sha256) then
		local sub_token_info = token.sub_tokens and token.sub_tokens[secret_hash];
		if sub_token_info then
			return _validate_token_info(token_user, token_id, token.token_info, sub_token_info);
		end
		return nil, "not-authorized";
	end

	return _validate_token_info(token_user, token_id, token.token_info);

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

	return {
		username = token_user;
		host = token_host;
		resource = token_info.resource or resource or generate_identifier();

		role = select_role(token_user, token_host, token_info.role);
	};
end


function revoke_token(token)
	local token_id, token_user, token_host = parse_token(token);
	if not token_id then
		module:log("warn", "Failed to verify access token: %s", token_user);
		return nil, "invalid-token-format";
	end
	if token_host ~= module.host then
		return nil, "invalid-host";
	end
	return token_store:set(token_user, token_id, nil);
end

function sasl_handler(auth_provider, purpose, extra)
	return function (sasl, token, realm, _authzid)
		local token_info, err = get_token_info(token);
		if not token_info then
			module:log("debug", "SASL handler failed to verify token: %s", err);
			return nil, nil, extra;
		end
		local token_user, token_host, resource = jid.split(token_info.jid);
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
