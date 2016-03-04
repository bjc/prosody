
function encode(encode, json)
	local function test(f, j, e)
		if e then
			assert_equal(f(j), e);
		end
		assert_equal(f(j), f(json.decode(f(j))));
	end
	test(encode, json.null, "null")
	test(encode, {}, "{}")
	test(encode, {a=1});
	test(encode, {a={1,2,3}});
	test(encode, {1}, "[1]");
end

function decode(decode)
	local empty_array = decode("[]");
	assert_equal(type(empty_array), "table");
	assert_equal(#empty_array, 0);
	assert_equal(next(empty_array), nil);
end
