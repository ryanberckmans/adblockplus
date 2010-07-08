
all:
	./create_xpi.pl 2> /dev/null
	./register-devff-extension
	devff&
