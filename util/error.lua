local id = require "util.id";

-- Library configuration (see configure())
local auto_inject_traceback = false;
local display_tracebacks = false;


local error_mt = { __name = "error" };

function error_mt:__tostring()
	if display_tracebacks and self.context.traceback then
		return ("error<%s:%s:%s:%s>"):format(self.type, self.condition, self.text or "", self.context.traceback);
	end
	return ("error<%s:%s:%s>"):format(self.type, self.condition, self.text or "");
end

local function is_err(e)
	return getmetatable(e) == error_mt;
end

local function configure(opt)
	if opt.display_tracebacks ~= nil then
		display_tracebacks = opt.display_tracebacks;
	end
	if opt.auto_inject_traceback ~= nil then
		auto_inject_traceback = opt.auto_inject_traceback;
	end
end

-- Do we want any more well-known fields?
-- Or could we just copy all fields from `e`?
-- Sometimes you want variable details in the `text`, how to handle that?
-- Translations?
-- Should the `type` be restricted to the stanza error types or free-form?
-- What to set `type` to for stream errors or SASL errors? Those don't have a 'type' attr.

local function new(e, context, registry, source)
	if is_err(e) then return e; end
	local template = registry and registry[e];
	if not template then
		if type(e) == "table" then
			template = {
				code = e.code;
				type = e.type;
				condition = e.condition;
				text = e.text;
				extra = e.extra;
			};
		else
			template = {};
		end
	end
	context = context or {};

	if auto_inject_traceback then
		context.traceback = debug.traceback("error stack", 2);
	end

	local error_instance = setmetatable({
		instance_id = id.short();

		type = template.type or "cancel";
		condition = template.condition or "undefined-condition";
		text = template.text;
		code = template.code;
		extra = template.extra;

		context = context;
		source = source;
	}, error_mt);

	return error_instance;
end

-- compact --> normal form
local function expand_registry(namespace, registry)
	local mapped = {}
	for err,template in pairs(registry) do
		local e = {
			type = template[1];
			condition = template[2];
			text = template[3];
		};
		if namespace and template[4] then
			e.extra = { namespace = namespace, condition = template[4] };
		end
		mapped[err] = e;
	end
	return mapped;
end

local function init(source, namespace, registry)
	if type(namespace) == "table" then
		-- registry can be given as second argument if namespace is not used
		registry, namespace = namespace, nil;
	end
	local _, protoerr = next(registry, nil);
	if protoerr and type(next(protoerr)) == "number" then
		registry = expand_registry(namespace, registry);
	end
	return {
		source = source;
		registry = registry;
		new = function (e, context)
			return new(e, context, registry, source);
		end;
	};
end

local function coerce(ok, err, ...)
	if ok or is_err(err) then
		return ok, err, ...;
	end

	local new_err = new({
		type = "cancel", condition = "undefined-condition"
	}, { wrapped_error = err });

	return ok, new_err, ...;
end

local function from_stanza(stanza, context, source)
	local error_type, condition, text, extra_tag = stanza:get_error();
	local error_tag = stanza:get_child("error");
	context = context or {};
	context.stanza = stanza;
	context.by = error_tag.attr.by or stanza.attr.from;

	local uri;
	if condition == "gone" or condition == "redirect" then
		uri = error_tag:get_child_text(condition, "urn:ietf:params:xml:ns:xmpp-stanzas");
	end

	return new({
		type = error_type or "cancel";
		condition = condition or "undefined-condition";
		text = text;
		extra = (extra_tag or uri) and {
			uri = uri;
			tag = extra_tag;
		} or nil;
	}, context, nil, source);
end

return {
	new = new;
	init = init;
	coerce = coerce;
	is_err = is_err;
	from_stanza = from_stanza;
	configure = configure;
}
