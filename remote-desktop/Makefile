SWIFT_BIN  := capture/.build/release/CaptureHelper
GO_BIN     := server/sdg-rdp-server

.PHONY: all swift go clean install

all: swift go

swift:
	cd capture && swift build -c release 2>&1

go:
	cd server && go build -o sdg-rdp-server . 2>&1

clean:
	cd capture && swift package clean
	rm -f server/sdg-rdp-server

# Install built binaries and client files to their deployment paths.
# Run as root (sudo make install) or from the Ansible role.
install: all
	install -m 755 $(SWIFT_BIN)  /usr/local/bin/sdg-rdp-capture
	install -m 755 $(GO_BIN)     /usr/local/bin/sdg-rdp-server
	mkdir -p /usr/local/share/sdg-rdp
	install -m 644 client/index.html /usr/local/share/sdg-rdp/index.html
