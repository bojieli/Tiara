CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Werror -std=c11 -fPIC
INCLUDE := -I../include

LIB    := libtiara.a
SHARED := libtiara.so
OBJS   := client.o

all: $(LIB) $(SHARED)

$(LIB): $(OBJS)
	$(AR) rcs $@ $(OBJS)

$(SHARED): $(OBJS)
	$(CC) -shared -o $@ $(OBJS)

%.o: %.c ../include/tiara.h
	$(CC) $(CFLAGS) $(INCLUDE) -c -o $@ $<

clean:
	rm -f $(LIB) $(SHARED) $(OBJS)

.PHONY: all clean
