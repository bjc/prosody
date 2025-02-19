local record lib
	enum Signal
		"SIGABRT"
		"SIGALRM"
		"SIGBUS"
		"SIGCHLD"
		"SIGCLD"
		"SIGCONT"
		"SIGFPE"
		"SIGHUP"
		"SIGILL"
		"SIGINT"
		"SIGIO"
		"SIGIOT"
		"SIGKILL"
		"SIGPIPE"
		"SIGPOLL"
		"SIGPROF"
		"SIGQUIT"
		"SIGSEGV"
		"SIGSTKFLT"
		"SIGSTOP"
		"SIGSYS"
		"SIGTERM"
		"SIGTRAP"
		"SIGTTIN"
		"SIGTTOU"
		"SIGURG"
		"SIGUSR1"
		"SIGUSR2"
		"SIGVTALRM"
		"SIGWINCH"
		"SIGXCPU"
		"SIGXFSZ"
	end
	signal : function (integer | Signal, function, boolean) : boolean
	raise : function (integer | Signal)
	kill : function (integer, integer | Signal)
	signalfd : function (integer) : FILE
	-- enum : integer
end
return lib
