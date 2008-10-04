
local m_random = math.random;
module "uuid"

function uuid_generate()
	return m_random(0, 99999999);
end

return _M;