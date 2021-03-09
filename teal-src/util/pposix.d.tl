local record pposix
	enum syslog_facility
		"auth"
		"authpriv"
		"cron"
		"daemon"
		"ftp"
		"kern"
		"local0"
		"local1"
		"local2"
		"local3"
		"local4"
		"local5"
		"local6"
		"local7"
		"lpr"
		"mail"
		"syslog"
		"user"
		"uucp"
	end

	enum syslog_level
		"debug"
		"info"
		"notice"
		"warn"
		"error"
	end

	enum ulimit_resource
		"CORE"
		"CPU"
		"DATA"
		"FSIZE"
		"NOFILE"
		"STACK"
		"MEMLOCK"
		"NPROC"
		"RSS"
		"NICE"
	end

	enum ulimit_unlimited
		"unlimited"
	end

	type ulimit_limit = number | ulimit_unlimited

	record utsname
		sysname         :  string
		nodename        :  string
		release         :  string
		version         :  string
		machine         :  string
		domainname      :  string
	end

	record memoryinfo
		allocated       :  number
		allocated_mmap  :  number
		used            :  number
		unused          :  number
		returnable      :  number
	end

	abort : function ()

	daemonize : function () : boolean, string

	syslog_open : function (ident : string, facility : syslog_facility)
	syslog_close : function ()
	syslog_log : function (level : syslog_level, src : string, msg : string)
	syslog_setminlevel : function (level : syslog_level)

	getpid : function () : number
	getuid : function () : number
	getgid : function () : number

	setuid : function (uid : string) : boolean, string -- string|number
	setgid : function (uid : string) : boolean, string
	initgroups : function (user : string, gid : number) : boolean, string

	umask : function (umask : string) : string

	mkdir : function (dir : string) : boolean, string

	setrlimit : function (resource : ulimit_resource, soft : ulimit_limit, hard : ulimit_limit) : boolean, string
	getrlimit : function (resource : ulimit_resource) : boolean, ulimit_limit, ulimit_limit
	getrlimit : function (resource : ulimit_resource) : boolean, string

	uname : function () : utsname

	setenv : function (key : string, value : string) : boolean

	meminfo : function () : memoryinfo

	atomic_append : function (f : FILE, s : string) : boolean, string, number

	ENOENT : number
	_NAME : string
	_VESRION : string
end

return pposix
