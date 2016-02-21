-- Makes no attempt at testing how random the bytes are,
-- just that it returns the number of bytes requested

function bytes(bytes)
	assert_is(bytes(16));

	for i = 1, 255 do
		assert_equal(i, #bytes(i));
	end
end
