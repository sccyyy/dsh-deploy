SHELL := /bin/bash

.PHONY: check lint test package

check: lint test

lint:
	bash -n deploy-dsh.sh
	shellcheck deploy-dsh.sh tests/*.sh scripts/*.sh

test:
	bash tests/run.sh

package:
	bash scripts/package.sh
