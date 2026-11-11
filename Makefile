APP := .build/Butler.app
AGENT := $(HOME)/Library/LaunchAgents/com.butler.plist
DOMAIN := gui/$(shell id -u)
DEMO := $(CURDIR)/.build/demo
BUTLER := CFFIXED_USER_HOME=$(DEMO) $(APP)/Contents/MacOS/Butler --offline

.PHONY: build test cert app install uninstall sounds screens

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
	mkdir -p $(APP)/Contents/Resources
	cp Pictures/*.png $(APP)/Contents/Resources/
	@if security find-certificate -c Butler >/dev/null 2>&1; then \
		codesign --force --sign Butler $(APP); \
	else \
		codesign --force --sign - $(APP); \
		echo "Подписано ad-hoc: разрешения macOS слетят после пересборки. Выполните make cert"; \
	fi

# Постоянная подпись: macOS узнаёт Butler от сборки к сборке и помнит выданные разрешения — доступ к
# календарям. Сертификат самоподписанный, в связке ключей входа; создаётся один раз.
cert:
	@if security find-certificate -c Butler >/dev/null 2>&1; then echo "Сертификат Butler уже есть"; exit 0; fi; \
	dir=$$(mktemp -d); \
	/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=Butler" \
		-addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
		-keyout $$dir/key.pem -out $$dir/cert.pem 2>/dev/null && \
	/usr/bin/openssl pkcs12 -export -inkey $$dir/key.pem -in $$dir/cert.pem -name Butler -passout pass:butler -out $$dir/butler.p12 && \
	security import $$dir/butler.p12 -k $(HOME)/Library/Keychains/login.keychain-db -P butler -T /usr/bin/codesign; \
	status=$$?; rm -rf $$dir; exit $$status

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
