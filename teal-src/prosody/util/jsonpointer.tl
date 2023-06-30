
local enum ptr_error
	"invalid-table"
	"invalid-path"
end

local function unescape_token(escaped_token : string) : string
	local unescaped = escaped_token:gsub("~1", "/"):gsub("~0", "~")
	return unescaped
end

local function resolve_json_pointer(ref : any, path : string) : any, ptr_error
	local ptr_len = #path+1
	for part, pos in path:gmatch("/([^/]*)()") do
		local token = unescape_token(part)
		if not ref is table then
			return nil
		end
		local idx = next(ref)
		local new_ref : any

		if idx is string then
			new_ref = ref[token]
		elseif idx is integer then
			local i = tonumber(token)
			if token == "-" then i = #(ref as {any}) + 1 end
			new_ref = ref[i+1]
		else
			return nil, "invalid-table"
		end

		if pos as integer == ptr_len then
			return new_ref
		elseif new_ref is table then
			ref = new_ref
		elseif not ref is table then
			return nil, "invalid-path"
		end

	end
	return ref
end

return {
	resolve = resolve_json_pointer,
}
