local error_mt = { __name = "error" };

function error_mt:__tostring()
	return ("error<%s:%s:%s>"):format(self.type, self.condition, self.text or "");
end

local function is_err(e)
	return getmetatable(e) == error_mt;
end

local function new(e, context, registry)
	local template = (registry and registry[e]) or e or {};
	return setmetatable({
		type = template.type or "cancel";
		condition = template.condition or "undefined-condition";
		text = template.text;
		code = template.code or 500;

		context = context or template.context or { _error_id = e };
	}, error_mt);
end

local function coerce(ok, err, ...)
	if ok or is_err(err) then
		return ok, err, ...;
	end

	local new_err = setmetatable({
		native = err;

		type = "cancel";
		condition = "undefined-condition";
	}, error_mt);
	return ok, new_err, ...;
end

local function from_stanza(stanza, context)
	local error_type, condition, text = stanza:get_error();
	return setmetatable({
		type = error_type or "cancel";
		condition = condition or "undefined-condition";
		text = text;

		context = context or { stanza = stanza };
	}, error_mt);
end

return {
	new = new;
	coerce = coerce;
	is_err = is_err;
	from_stanza = from_stanza;
}
