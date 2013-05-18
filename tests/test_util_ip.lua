
function test_match(match_ip) 
	assert(match_ip("10.20.30.40", "10.0.0.0/8"));
	assert(match_ip("80.244.94.84", "80.244.94.84"));
	assert(match_ip("8.8.8.8", "8.8.0.0/16"));
	assert(match_ip("8.8.4.4", "8.8.0.0/16"));
end
