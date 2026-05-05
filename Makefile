.PHONY: gen gen-check gen-orphans gen-test

gen:
	cd scripts/codegen && deno task gen

gen-check:
	cd scripts/codegen && deno task gen:check

gen-orphans:
	cd scripts/codegen && deno task gen:orphans

gen-test:
	cd scripts/codegen && deno task test
