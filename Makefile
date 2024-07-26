include .env

ifdef FILE
  matchFile = --match-contract $(FILE)
endif
ifdef FUNC
  matchFunction = --match-test $(FUNC)
endif

test = forge test $(matchFile) $(matchFunction)

t:
	$(test) -vv   --fork-url $(RPC) --fork-block-number $(FORK_BLOCK_NUMBER)
tt:
	$(test) -vvv  --fork-url $(RPC) --fork-block-number $(FORK_BLOCK_NUMBER)
ttt:
	$(test) -vvvv --fork-url $(RPC)	--fork-block-number $(FORK_BLOCK_NUMBER)
