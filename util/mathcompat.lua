if not math.type then

	local function math_type(t)
		if type(t) == "number" then
			if t % 1 == 0 and t ~= t + 1 and t ~= t - 1 then
				return "integer"
			else
				return "float"
			end
		end
	end
	_G.math.type = math_type
end
