SWIFTFORMAT ?= swiftformat
SWIFTLINT ?= swiftlint
SCREENSAVER_INSTALL_DIR ?= $(HOME)/Library/Screen Savers

SWIFT_SOURCES := Shared ScreenSaver Preview

.PHONY: format check-format lint check install

format:
	"$(SWIFTFORMAT)" $(SWIFT_SOURCES) --config .swiftformat --cache ignore

check-format:
	"$(SWIFTFORMAT)" $(SWIFT_SOURCES) --config .swiftformat --lint --cache ignore

lint:
	"$(SWIFTLINT)" lint --strict --no-cache --config .swiftlint.yml

check: check-format lint

install:
	@/bin/sh ./Scripts/install.sh "$(SCREENSAVER_INSTALL_DIR)"
