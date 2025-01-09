export DEFAULT_IMG_TAG=localhost/mpiit-automation
export DEFAULT_DB_NAME=mpiit-db.json
export CONTAINER_ENGINE=podman

default: build db

dev: dev-build db

db:
	$$CONTAINER_ENGINE run $$DEFAULT_IMG_TAG > $$DEFAULT_DB_NAME

run:
	$$CONTAINER_ENGINE run $$DEFAULT_IMG_TAG

build:
	$$CONTAINER_ENGINE build . --no-cache --squash-all -t $$DEFAULT_IMG_TAG

dev-build:
	$$CONTAINER_ENGINE build . -t $$DEFAULT_IMG_TAG

