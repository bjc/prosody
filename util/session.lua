
local function new_session(typ)
	local session = {
		type = typ .. "_unauthed";
	};
	return session;
end

return {
	new = new_session;
}
