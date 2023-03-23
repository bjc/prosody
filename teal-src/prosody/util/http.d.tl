local record lib
	urlencode : function (s : string) : string 
	urldecode : function (s : string) : string 
	formencode : function (f : { string : string }) : string 
	formdecode : function (s : string) : { string : string } 
	contains_token : function (field : string, token : string) : boolean 
	normalize_path : function (path : string) : string 
end
return lib
