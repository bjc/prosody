
local m_random = math.random;
module "uuid"

function generate()
	return m_random(0, 99999999);
end

return _M;