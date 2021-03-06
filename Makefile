BIN_NAME = searchfs
MAN_NAME = searchfs.1
CFLAGS = -Os
DEST_DIR = /usr/local/bin/
MAN_DIR = /usr/local/share/man/man1/
FRAMEWORKS = -framework Foundation

all:: main

main: main.m
	gcc $(FRAMEWORKS) -o $(BIN_NAME) $(CFLAGS) main.m
	strip -x $(BIN_NAME)

install: main
	cp $(BIN_NAME) $(DEST_DIR)
	cp $(MAN_NAME) $(MAN_DIR)

uninstall:
	rm $(DEST_DIR)$(BIN_NAME)
	rm $(MAN_NAME)$(MAN_DIR)

clean:
	rm -rf *.o searchfs 2> /dev/null
