APP_NAME    := cbm
BUNDLE_ID   := ee.henno.cbm
INSTALL_DIR := $(HOME)/Applications
APP         := $(INSTALL_DIR)/$(APP_NAME).app
CONFIG      ?= release
BIN         := .build/$(CONFIG)/$(APP_NAME)
CERT_DIR    := certs
CERT_CN     := cbm-dev

# TCC (the Accessibility grant) keys unsigned/ad-hoc binaries by their cdhash,
# which changes on every rebuild -- so every rebuild silently invalidates the
# grant. A stable self-signed identity keys it by the designated requirement
# instead, which survives rebuilds. `make cert` creates one; until then we fall
# back to ad-hoc and you re-toggle Accessibility after each build.
SIGN_ID := $(shell if security find-identity -v -p codesigning 2>/dev/null | grep -q '$(CERT_CN)'; then echo $(CERT_CN); else echo -; fi)

.PHONY: all build bundle install run stop restart test status clean uninstall cert cert-status help

all: install

help:
	@echo "make run        build, install to $(APP), (re)launch"
	@echo "make build      compile only"
	@echo "make install    build + assemble + sign + install"
	@echo "make test       run the logic self-tests"
	@echo "make stop       quit a running instance"
	@echo "make cert       create a stable self-signed signing identity (one-time)"
	@echo "make cert-status  show which identity will be used"
	@echo "make clean      remove build artifacts"
	@echo "make uninstall  remove $(APP) (leaves your clipboard history intact)"
	@echo ""
	@echo "CONFIG=debug make run   for an unoptimised build"

build:
	swift build -c $(CONFIG)

bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@cp "$(BIN)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@# Stamp in where this was built from, so the app can name the exact command
	@# to run rather than telling the user to "run make cert" from nowhere.
	@/usr/libexec/PlistBuddy -c "Add :CBMSourceRoot string $(CURDIR)" \
		"$(APP)/Contents/Info.plist" >/dev/null 2>&1 || true
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"

install: bundle
	@codesign --force --sign "$(SIGN_ID)" --identifier "$(BUNDLE_ID)" \
		--options runtime --timestamp=none "$(APP)" 2>/dev/null \
		|| codesign --force --sign "$(SIGN_ID)" --identifier "$(BUNDLE_ID)" "$(APP)"
	@echo "installed $(APP)  (signed with: $(SIGN_ID))"
ifeq ($(SIGN_ID),-)
	@echo ""
	@echo "  NOTE: ad-hoc signed. If auto-paste stops working after this build,"
	@echo "        toggle cbm off and on in System Settings > Privacy & Security"
	@echo "        > Accessibility. Run 'make cert' once to stop that happening."
endif

test: build
	@$(BIN) --self-test

status:
	@"$(APP)/Contents/MacOS/$(APP_NAME)" --status

stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.3

run: stop install
	@open "$(APP)"
	@echo "running. Cmd+Option+C opens the panel."

restart: run

cert-status:
	@echo "signing identity: $(SIGN_ID)"
	@security find-identity -v -p codesigning || true

# One-time: mint a self-signed code-signing cert, import it, trust it.
# The trust step opens a system authentication dialog -- that is expected.
cert:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '$(CERT_CN)'; then \
		echo "'$(CERT_CN)' already exists, nothing to do."; exit 0; fi
	@mkdir -p $(CERT_DIR)
	@printf '%s\n' \
		'[req]' 'distinguished_name=dn' 'x509_extensions=v3' 'prompt=no' \
		'[dn]' 'CN=$(CERT_CN)' \
		'[v3]' 'basicConstraints=critical,CA:false' \
		'keyUsage=critical,digitalSignature' \
		'extendedKeyUsage=critical,codeSigning' \
		> $(CERT_DIR)/openssl.cnf
	@openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
		-keyout $(CERT_DIR)/$(CERT_CN).key -out $(CERT_DIR)/$(CERT_CN).crt \
		-config $(CERT_DIR)/openssl.cnf >/dev/null 2>&1
	@# macOS cannot read OpenSSL 3's default PKCS#12 encryption, and rejects an
	@# empty password outright, so pin the legacy algorithms and use a throwaway
	@# passphrase. The bundle is deleted immediately after import.
	@openssl pkcs12 -export -out $(CERT_DIR)/$(CERT_CN).p12 \
		-inkey $(CERT_DIR)/$(CERT_CN).key -in $(CERT_DIR)/$(CERT_CN).crt \
		-name $(CERT_CN) -passout pass:$(CERT_CN) \
		-macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
	@security import $(CERT_DIR)/$(CERT_CN).p12 -k "$(HOME)/Library/Keychains/login.keychain-db" \
		-P $(CERT_CN) -T /usr/bin/codesign -T /usr/bin/security
	@echo ""
	@echo "  A system dialog will now ask you to authorise trusting the certificate."
	@security add-trusted-cert -r trustRoot -p codeSign \
		-k "$(HOME)/Library/Keychains/login.keychain-db" $(CERT_DIR)/$(CERT_CN).crt
	@rm -f $(CERT_DIR)/$(CERT_CN).p12 $(CERT_DIR)/openssl.cnf
	@echo ""
	@echo "done. Re-run 'make run'; the Accessibility grant will now survive rebuilds."

clean:
	rm -rf .build

uninstall: stop
	rm -rf "$(APP)"
	@echo "removed $(APP). History is still in ~/Library/Application Support/cbm"
