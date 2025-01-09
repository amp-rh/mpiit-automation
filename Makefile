export DEFAULT_IMG_TAG=localhost/mpiit-automation
export DEFAULT_DB_NAME=mpiit-db.json
export CONTAINER_ENGINE=podman

default: build db verify

dev: build-with-cache db attach

db:
	$$CONTAINER_ENGINE run $$DEFAULT_IMG_TAG "cat db | jq" | tee $$DEFAULT_DB_NAME

verify:
	$$CONTAINER_ENGINE run $$DEFAULT_IMG_TAG "cat verification | jq" | tee verify-results.json

run:
	$$CONTAINER_ENGINE run $$DEFAULT_IMG_TAG

build:
	$$CONTAINER_ENGINE build . --no-cache -t $$DEFAULT_IMG_TAG

build-with-cache:
	$$CONTAINER_ENGINE build . -t $$DEFAULT_IMG_TAG

attach:
	$$CONTAINER_ENGINE run --entrypoint=/bin/bash -it $$DEFAULT_IMG_TAG

build-stage:
	$$CONTAINER_ENGINE build . -t $$TARGET_STAGE --target $$TARGET_STAGE

run-stage:
	$$CONTAINER_ENGINE run --entrypoint bash -it --name $$TARGET_STAGE --replace $$TARGET_STAGE

stage: build-stage run-stage

