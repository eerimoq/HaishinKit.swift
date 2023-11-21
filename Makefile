all:
	$(MAKE) style
	$(MAKE) lint

style:
	swiftformat --maxwidth 110 Sources SRTHaishinKit

style-check:
	swiftformat --maxwidth 110 --lint Sources SRTHaishinKit

lint:
	swiftlint lint --strict Sources SRTHaishinKit

periphery:
	periphery scan
