local id = require "util.id";
local jid = require "util.jid";
local base64 = require "util.encodings".base64;
local usermanager = require "core.usermanager";
local generate_identifier = require "util.id".short;

local token_store = module:open_store("auth_tokens", "map");

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

	local token_info = {
		owner = actor_jid;
		created = os.time();
		expires = token_ttl and (os.time() + token_ttl) or nil;
		jid = token_jid;
		purpose = token_purpose;

		resource = token_resource;
		role = token_role;
		data = token_data;
	};

	local token_id = id.long();
	local token = base64.encode("1;"..jid.join(token_username, token_host)..";"..token_id);
	token_store:set(token_username, token_id, token_info);

	return token, token_info;
end

local function parse_token(encoded_token)
	if not encoded_token then return nil; end
	local token = base64.decode(encoded_token);
	if not token then return nil; end
	local token_jid, token_id = token:match("^1;([^;]+);(.+)$");
	if not token_jid then return nil; end
	local token_user, token_host = jid.split(token_jid);
	return token_id, token_user, token_host;
end

local function _get_parsed_token_info(token_id, token_user, token_host)
	if token_host ~= module.host then
		return nil, "invalid-host";
	end

	local token_info, err = token_store:get(token_user, token_id);
	if not token_info then
		if err then
			return nil, "internal-error";
		end
		return nil, "not-authorized";
	end

	if token_info.expires and token_info.expires < os.time() then
		token_store:set(token_user, token_id, nil);
		return nil, "not-authorized";
	end

	local account_info = usermanager.get_account_info(token_user, module.host);
	local password_updated_at = account_info and account_info.password_updated;
	if password_updated_at and password_updated_at > token_info.created then
		token_store:set(token_user, token_id, nil);
		return nil, "not-authorized";
	end

	return token_info
end

function get_token_info(token)
	local token_id, token_user, token_host = parse_token(token);
	if not token_id then
		return nil, "invalid-token-format";
	end
	return _get_parsed_token_info(token_id, token_user, token_host);
end

function get_token_session(token, resource)
	local token_id, token_user, token_host = parse_token(token);
	if not token_id then
		return nil, "invalid-token-format";
	end

	local token_info, err = _get_parsed_token_info(token_id, token_user, token_host);
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
