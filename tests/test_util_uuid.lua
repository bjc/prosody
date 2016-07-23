-- This tests the format, not the randomness

-- https://tools.ietf.org/html/rfc4122#section-4.4

local pattern = "^" .. table.concat({
	string.rep("%x", 8),
	string.rep("%x", 4),
	"4" .. -- version
	string.rep("%x", 3),
	"[89ab]" .. -- reserved bits of 1 and 0
	string.rep("%x", 3),
	string.rep("%x", 12),
}, "%-") .. "$";

function generate(generate)
	for _ = 1, 100 do
		assert_is(generate():match(pattern));
	end
end

function seed(seed)
	assert_equal(seed("random string here"), nil, "seed doesn't return anything");
end

