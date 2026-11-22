module openmtpbench

go 1.27.3

require (
	github.com/ganeshrvel/go-mtpfs v1.0.4-0.20240426083057-1c3302b3c476
	github.com/ganeshrvel/go-mtpx v0.0.0-20240426092756-18f12db021cc
)

require github.com/ganeshrvel/usb v0.0.0-20210103155855-14d96f5ae403 // indirect

// Local copy of go-mtpfs@1c3302b3c476 plus one additive file (mtp/select_vendor.go) so the
// harness can select a device by USB vendor without opening other connected MTP devices.
// build.sh swaps this for a patched copy to build the ZLP-fix variant.
replace github.com/ganeshrvel/go-mtpfs => ./third_party/go-mtpfs
