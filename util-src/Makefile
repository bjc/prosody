
LUA_INCLUDE=/usr/include/lua5.1
LUA_LIB=lua5.1

IDN_LIB=idn
OPENSSL_LIB=ssl


all: encodings.so hashes.so

install: encodings.so hashes.so
	strip *.so
	cp *.so ../util/
	

clean:
	rm *.so

encodings.so: encodings.c
	gcc -shared encodings.c -I$(LUA_INCLUDE) -l$(LUA_LIB) -l$(IDN_LIB) -o encodings.so

hashes.so: hashes.c
	gcc -shared hashes.c -I$(LUA_INCLUDE) -l$(LUA_LIB) -l$(OPENSSL_LIB) -o hashes.so
	
