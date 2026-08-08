SHELL := /bin/bash

.PHONY: all up platform gitops verify status down

all: up platform gitops verify

up:
	./scripts/container-lab.sh up

platform:
	./scripts/container-lab.sh platform

gitops:
	./scripts/container-lab.sh gitops

verify:
	./scripts/container-lab.sh verify

status:
	./scripts/container-lab.sh status

down:
	./scripts/container-lab.sh down
