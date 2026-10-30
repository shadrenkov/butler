APP := .build/Butler.app
AGENT := $(HOME)/Library/LaunchAgents/com.butler.plist
DOMAIN := gui/$(shell id -u)
DEMO := $(CURDIR)/.build/demo
BUTLER := CFFIXED_USER_HOME=$(DEMO) $(APP)/Contents/MacOS/Butler --offline

.PHONY: build test app install uninstall sounds screens

build:
	swift build -c release

test:
	swift test

sounds:
	swift run Butler --sounds

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/Butler $(APP)/Contents/MacOS/Butler
	cp Support/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

install: app
	mkdir -p $(HOME)/Applications
	rsync -a --delete $(APP) $(HOME)/Applications/
	sed "s|__HOME__|$(HOME)|" Support/com.butler.plist > $(AGENT)
	-launchctl bootout $(DOMAIN)/com.butler 2>/dev/null
	while launchctl print $(DOMAIN)/com.butler >/dev/null 2>&1; do sleep 0.2; done
	launchctl bootstrap $(DOMAIN) $(AGENT)

# Скриншоты README: выдуманный календарь в подставной домашней папке, без единого обращения к серверу.
screens: app
	rm -rf $(DEMO)
	python3 Support/demo.py $(DEMO)
	mkdir -p Docs
	$(BUTLER) --now 2035-07-17T11:23 --picture month Docs/month.png
	$(BUTLER) --now 2035-07-17T10:59 --picture day Docs/alert.png
	# В настройках звуки видны включёнными; в 11:23 ни одно напоминание не срабатывает.
	python3 Support/demo.py $(DEMO) sounds
	$(BUTLER) --now 2035-07-17T11:23 --picture settings Docs/settings.png

uninstall:
	-launchctl bootout $(DOMAIN)/com.butler 2>/dev/null
	rm -f $(AGENT)
	rm -rf $(HOME)/Applications/Butler.app
