all: build

help:
	@echo ""
	@echo "-- Help Menu"
	@echo ""
	@echo "   1. make build       - build the redmine image"
	@echo "   2. make stop        - stop redmine"
	@echo "   3. make logs        - view logs"
	@echo "   4. make purge       - stop and remove the container"

build:
	@docker build --tag=grem4/redmine .

release:
	@docker build --tag=grem4/redmine:$(shell cat VERSION) .

stop:
	@echo "Stopping redmine..."
	@docker stop redmine >/dev/null

purge: stop
	@echo "Removing stopped container..."
	@docker rm redmine >/dev/null

logs:
	@docker logs -f redmine
