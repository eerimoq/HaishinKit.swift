all:
	$(MAKE) style
	$(MAKE) lint

style:
	swiftformat --maxwidth 110 Sources

style-check:
	swiftformat --maxwidth 110 --lint Sources

lint:
	swiftlint lint --strict Sources

periphery:
	periphery scan
