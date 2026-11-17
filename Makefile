SWIFTFORMAT ?= swiftformat
SWIFTLINT ?= swiftlint

SWIFT_SOURCES := Shared ScreenSaver Preview

.PHONY: format check-format lint check

format:
	"$(SWIFTFORMAT)" $(SWIFT_SOURCES) --config .swiftformat --cache ignore

check-format:
	"$(SWIFTFORMAT)" $(SWIFT_SOURCES) --config .swiftformat --lint --cache ignore

lint:
	"$(SWIFTLINT)" lint --strict --no-cache --config .swiftlint.yml

check: check-format lint
