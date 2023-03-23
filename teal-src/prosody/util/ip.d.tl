local record iplib
	enum protocol
		"IPv6"
		"IPv4"
	end
	record ip_t
		addr : string
		packed : string
		proto : protocol
		zone : string
	end

	new_ip : function (string, protocol) : ip_t
	commonPrefixLength : function (ip_t, ip_t) : integer
	parse_cidr : function (string) : ip_t, integer
	match : function (ip_t, ip_t, integer) : boolean
	is_ip : function (any) : boolean
	truncate : function (ip_t, integer) : ip_t
end
return iplib
