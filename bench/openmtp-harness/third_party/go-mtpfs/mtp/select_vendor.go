package mtp

// Benchmark-harness addition (not part of upstream go-mtpfs). Everything else in this module is
// byte-identical to go-mtpfs@1c3302b3c476 (see ../../README.md).
//
// Upstream selectDevice(pattern) calls Open() (libusb open + ClaimInterface, and sometimes a
// GetDeviceInfo) on EVERY MTP candidate before it matches the pattern against the ID string, so
// a name pattern would still claim other connected MTP devices. This variant drops candidates
// whose cached USB device descriptor has a different idVendor BEFORE anything is opened, then
// runs the unchanged upstream selectDevice on the remainder (pattern matched against
// "manufacturer product serial").

import (
	"fmt"

	"github.com/ganeshrvel/usb"
)

func SelectDeviceByVendorWithDebugging(vendor uint16, pattern string, allowDebugging bool) (*Device, error) {
	c := usb.NewContext()

	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}

	var match []*Device
	for _, d := range devs {
		if d.devDescr.IdVendor == vendor {
			match = append(match, d)
		} else {
			d.Done() // unref only; never opened
		}
	}
	if len(match) == 0 {
		return nil, fmt.Errorf("no MTP device with idVendor %#04x", vendor)
	}

	if allowDebugging {
		for _, _dev := range match {
			_dev.USBDebug = allowDebugging
			_dev.DataDebug = allowDebugging
			_dev.MTPDebug = allowDebugging
		}
	}

	return selectDevice(match, pattern)
}

// ListCandidates returns idVendor/idProduct of MTP candidates without opening any of them.
func ListCandidates() ([][2]uint16, error) {
	c := usb.NewContext()
	devs, err := FindDevices(c)
	if err != nil {
		return nil, err
	}
	var out [][2]uint16
	for _, d := range devs {
		out = append(out, [2]uint16{d.devDescr.IdVendor, d.devDescr.IdProduct})
		d.Done()
	}
	return out, nil
}
