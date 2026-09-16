package iec61850

// this file is used to import all the packages that are needed include cgo files
// if you want to use the cgo files, you should import this file

import (
	_ "github.com/Paashaas/iec61850/libiec61850/darwin_amd64/include"
	_ "github.com/Paashaas/iec61850/libiec61850/darwin_armv8/include"
	_ "github.com/Paashaas/iec61850/libiec61850/linux_amd64/include"
	_ "github.com/Paashaas/iec61850/libiec61850/linux_arm64/include"
	_ "github.com/Paashaas/iec61850/libiec61850/linux_armv7/include"
	_ "github.com/Paashaas/iec61850/libiec61850/windows_amd64/include"

	_ "github.com/Paashaas/iec61850/libiec61850/darwin_amd64/lib"
	_ "github.com/Paashaas/iec61850/libiec61850/darwin_armv8/lib"
	_ "github.com/Paashaas/iec61850/libiec61850/linux_amd64/lib"
	_ "github.com/Paashaas/iec61850/libiec61850/linux_arm64/lib"
	_ "github.com/Paashaas/iec61850/libiec61850/linux_armv7/lib"
	_ "github.com/Paashaas/iec61850/libiec61850/windows_amd64/lib"
)
