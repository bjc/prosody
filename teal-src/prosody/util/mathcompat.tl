if not math.type then
	local enum number_subtype
		"float" "integer"
	end
	local function math_type(t:any) : number_subtype
		if t is number then
			if t % 1 == 0 and t ~= t+1 and t ~= t-1 then
				return "integer"
			else
				return "float"
			end
		end
	end
	_G.math.type = math_type
end
