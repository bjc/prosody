
function match(match)
	local _ = require "util.ip".new_ip;
	local ip = _"10.20.30.40";
	assert_equal(match(ip, _"10.0.0.0", 8), true);
	assert_equal(match(ip, _"10.0.0.0", 16), false);
	assert_equal(match(ip, _"10.0.0.0", 24), false);
	assert_equal(match(ip, _"10.0.0.0", 32), false);

	assert_equal(match(ip, _"10.20.0.0", 8), true);
	assert_equal(match(ip, _"10.20.0.0", 16), true);
	assert_equal(match(ip, _"10.20.0.0", 24), false);
	assert_equal(match(ip, _"10.20.0.0", 32), false);

	assert_equal(match(ip, _"0.0.0.0", 32), false);
	assert_equal(match(ip, _"0.0.0.0", 0), true);
	assert_equal(match(ip, _"0.0.0.0"), false);

	assert_equal(match(ip, _"10.0.0.0", 255), false, "excessive number of bits");
	assert_equal(match(ip, _"10.0.0.0", -8), true, "negative number of bits");
	assert_equal(match(ip, _"10.0.0.0", -32), true, "negative number of bits");
	assert_equal(match(ip, _"10.0.0.0", 0), true, "zero bits");
	assert_equal(match(ip, _"10.0.0.0"), false, "no specified number of bits (differing ip)");
	assert_equal(match(ip, _"10.20.30.40"), true, "no specified number of bits (same ip)");

	assert_equal(match(_"80.244.94.84", _"80.244.94.84"), true, "simple ip");

	assert_equal(match(_"8.8.8.8", _"8.8.0.0", 16), true);
	assert_equal(match(_"8.8.4.4", _"8.8.0.0", 16), true);
end
