BASEDIR = $(shell pwd)
REBAR = rebar3
APPNAME = dmap

all: deps compile

deps:
	@( $(REBAR) deps )

compile:
	@( $(REBAR) compile )

clean:
	@( $(REBAR) clean )

observer:
	@( erl -name observer@127.0.0.1 -setcookie dmap_cookie -run observer)

erl: compile
	@( erl -pa _build/default/lib/*/ebin -name dmap1@127.0.0.1 -setcookie dmap_cookie )

run: compile
	@( erl -pa _build/default/lib/*/ebin -name $(NODE_NAME) -setcookie dmap_cookie -s dmap )

.PHONY: all deps compile clean run test
