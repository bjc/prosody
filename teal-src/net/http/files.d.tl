local record serve_options
	path : string
	mime_map : { string : string }
	cache_size : integer
	cache_max_file_size : integer
	index_files : { string }
	directory_index : boolean
end

local record http_files
	serve : function(serve_options|string) : function
end

return http_files
