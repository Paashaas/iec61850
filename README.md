# iec61850

[![License](https://img.shields.io/badge/license-GPL--3.0-green.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![PkgGoDev](https://pkg.go.dev/badge/mod/github.com/Paashaas/iec61850)](https://pkg.go.dev/mod/github.com/Paashaas/iec61850)
![Go Version](https://img.shields.io/badge/go%20version-%3E=1.0-61CFDD.svg?style=flat-square)
[![Go Report Card](https://goreportcard.com/badge/github.com/Paashaas/iec61850?style=flat-square)](https://goreportcard.com/report/github.com/Paashaas/iec61850)

cgo version of IEC 61850 library, reference [libiec61850](https://github.com/mz-automation/libiec61850)

## What is IEC 61850?

IEC 61850 is the international standard for communication networks and systems in electrical
substations and power grids. It was originally designed for substation automation, but its
Edition 2 extended it to distributed energy resources such as inverters, wind turbines and
storage systems (IEC 61850-7-420). Instead of a bag of registers, the standard defines a
complete, vendor-neutral information model plus the services to exchange that information,
so that devices from different manufacturers interoperate out of the box.

### The data model

Every device (an "IED" — Intelligent Electronic Device) exposes its data as a tree:

```
Server
  └── Logical Device (LD)          e.g. "simpleIOGenericIO"
        └── Logical Node (LN)      e.g. "GGIO1" (a generic I/O node)
              └── Data Object (DO) e.g. "AnIn1" (an analogue input)
                    └── Data Attribute (DA) e.g. "mag.f" (the float value)
```

Each data attribute is addressed by an object reference and a functional constraint (FC)
that describes its role — the most common being `ST` (status), `MX` (measurement) and
`SP` (setpoint). An object reference like `simpleIOGenericIO/GGIO1.Ind1.stVal` therefore
uniquely identifies one value in one logical node.

### The communication services

The standard defines several ways to move that data between devices. This library covers the
three most used ones:

- **MMS** (Manufacturing Message Specification, mapped per IEC 61850-8-1): a client/server
  protocol over TCP/IP used to read and write data values, browse the data model, manage
  data sets, and operate control objects.
- **GOOSE** (IEC 61850-8-1): fast peer-to-peer events published directly over Ethernet
  (layer 2 multicast). Used where milliseconds matter, e.g. interlocking and trip signals.
- **Sampled Values (SV)** (IEC 61850-9-2): continuous streaming of digitised measurements
  (current/voltage samples) at fixed sample rates.

### Reports and control

Two concepts are worth knowing up front:

- **Report control blocks (RCB)** let a client subscribe to data changes. The server reports
  a data set whenever a trigger fires (data change, quality change, periodic integrity, ...).
  Buffered (BRCB) and unbuffered (URCB) variants exist for different delivery guarantees.
- **Control models** (status-only, direct, and select-before-operate, each with normal or
  enhanced security) describe how a client operates switchgear or other controllable objects.

### Configuration: SCL / ICD files

IEDs exchange their data model and service configuration as machine-readable SCL files
(IEC 61850-6): `.icd` for a single device's capability and `.scd/.cid` for configured
systems. This library can load the compiled static model that such files produce, so a
server serves exactly the model declared in its ICD.

### Where this library fits

This library is a Go binding around [libiec61850](https://github.com/mz-automation/libiec61850)
(via cgo). It lets you write, in plain Go:

- **MMS clients** that connect to an IED, browse the model, read/write values, control
  objects, configure reports and setting groups
- **MMS servers** that serve a data model and handle writes, controls and client connections
- **GOOSE publishers and subscribers** on a raw Ethernet interface
- **SV publishers and subscribers** for sampled measured values

## Features

The library supports the following IEC 61850 protocol features:

- MMS client/server, GOOSE (IEC 61850-8-1)
- Sampled Values (SV - IEC 61850-9-2)
- Support for buffered and unbuffered reports
- Online report control block configuration
- Data access service (get data, set data)
- Online data model discovery and browsing
- All data set services (get values, set values, browse)
- Dynamic data set services (create and delete)
- Log service
- MMS file services (browse, get file, set file, delete/rename file)
- Setting group handling
- Support for service tracking
- GOOSE and SV control block handling
- TLS support

## How to use

```shell
go get -u github.com/Paashaas/iec61850
```

>For Windows environments, it is recommended to use [GCC 14.2.0](https://github.com/brechtsanders/winlibs_mingw/releases/download/14.2.0posix-19.1.1-12.0.0-ucrt-r2/winlibs-x86_64-posix-seh-gcc-14.2.0-llvm-19.1.1-mingw-w64ucrt-12.0.0-r2.zip) as the GCC compiler.

## Examples

The snippets below are taken from the runnable test programs in [`test/`](test/). They assume
a server (such as the one from [test/server](test/server), or any other IEC 61850 server) is
reachable at the configured host and port.

### Client: connect, read and write data values

Create a client with default host/port settings (localhost:102), read a status value and a
float measurement, and write a setpoint. From [test/client_rw](test/client_rw) and
[test/common.go](test/common.go):

```go
settings := iec61850.NewSettings()

client, err := iec61850.NewClient(settings)
if err != nil {
    panic(err)
}
defer client.Close()

value, err := client.ReadBool("simpleIOGenericIO/GGIO1.Ind1.stVal", iec61850.ST)
if err != nil {
    panic(err)
}

fValue, err := client.ReadFloat("simpleIOGenericIO/GGIO1.AnIn1.mag.f", iec61850.MX)
if err != nil {
    panic(err)
}

if err := client.Write("ied1Inverter/ZINV1.OutVarSet.setMag.f", iec61850.SP, 100); err != nil {
    panic(err)
}
```

Typed readers exist for bool/int32/int64/uint32/float/string, while `Read(objectRef, fc)`
returns the value generically. `GetLogicalDeviceList()` browses the whole data model.

### Client: report control blocks (RCB)

Read a report control block, reconfigure its trigger options and enable reporting. The RCB
reference selects an unbuffered (`RP.`) or buffered (`BR.`) control block of the server. From
[test/client_rcb/client_rcb_test.go](test/client_rcb/client_rcb_test.go):

```go
rbcRef := "simpleIOGenericIO/LLN0.RP.EventsRCB01"

rcbValue, err := client.GetRCBValues(rbcRef)
if err != nil {
    panic(err)
}

err = client.SetRCBValues(rbcRef, iec61850.ClientReportControlBlock{
    Ena:    true,
    IntgPd: 500,
    OptFlds: iec61850.OptFlds{
        SequenceNumber:     true,
        TimeOfEntry:        true,
        ReasonForInclusion: true,
        DataSetName:        true,
        DataReference:      true,
        BufferOverflow:     true,
        EntryID:            true,
        ConfigRevision:     true,
    },
    TrgOps: iec61850.TrgOps{
        DataChange:            true,
        QualityChange:         true,
        DataUpdate:            true,
        TriggeredPeriodically: true,
        Gi:                    true,
    },
})
if err != nil {
    panic(err)
}
```

### Client: control operations

Operate a controllable object (`SPCSO1`) using a specific control model. All four
select-before-operate / direct variants are supported via `ControlByControlModel`, plus
convenience wrappers per model. From [test/client_control/client_control_test.go](test/client_control/client_control_test.go):

```go
objectRef := "simpleIOGenericIO/GGIO1.SPCSO1"

param := iec61850.NewControlObjectParam(true)
param.OrIdent = "test"
if err := client.ControlByControlModel(objectRef, iec61850.CONTROL_MODEL_DIRECT_NORMAL, param); err != nil {
    panic(err)
}

value, err := client.ReadBool(objectRef+".stVal", iec61850.ST)
if err != nil {
    panic(err)
}
```

### Client: setting groups

Read the setting group control block and change a value in a setting group. From
[test/client_sg/client_sg_test.go](test/client_sg/client_sg_test.go):

```go
sgInfo, err := client.GetSG("DEMOPROT/LLN0.SGCB")
if err != nil {
    panic(err)
}

err = client.WriteSG("DEMOPROT", "LLN0", "DEMOPROT/PTOC1.StrVal.setMag.f", iec61850.SE, 2, float32(1.0))
if err != nil {
    panic(err)
}
```

### Server: load a data model and serve it

Load the static IED model from a configuration file, register handlers, and run the server
on TCP port 102. From [test/server/complexModel_test.go](test/server/complexModel_test.go)
and [test/server/simpleIO_control_test.go](test/server/simpleIO_control_test.go):

```go
model, err := iec61850.CreateModelFromConfigFileEx("complexModel.cfg")
if err != nil {
    panic(err)
}

server := iec61850.NewServerWithConfig(iec61850.NewServerConfig(), model)

modelNode := model.GetModelNodeByObjectReference("ied1Inverter/ZINV1.OutVarSet.setMag.f")
server.SetHandleWriteAccess(modelNode, func(node *iec61850.ModelNode, mmsValue *iec61850.MmsValue) iec61850.MmsDataAccessError {
    return iec61850.DATA_ACCESS_ERROR_SUCCESS
})

server.Start(102)
defer server.Destroy()
defer server.Stop()
```

To accept control operations on the server side, register a control handler on the control
object instead:

```go
modelNode := model.GetModelNodeByObjectReference("simpleIOGenericIO/GGIO1.SPCSO1")
server.SetControlHandler(modelNode, func(node *iec61850.ModelNode, action *iec61850.ControlAction, mmsValue *iec61850.MmsValue, test bool) iec61850.ControlHandlerResult {
    return iec61850.CONTROL_RESULT_OK
})
```

A server can also update values at runtime (which triggers connected clients' reports), as
shown in [test/server/simpleIO_direct_control_goose_test.go](test/server/simpleIO_direct_control_goose_test.go):

```go
node := model.GetModelNodeByObjectReference("simpleIOGenericIO/GGIO1.AnIn1.mag.f")

server.LockDataModel()
server.UpdateFloatAttributeValue(node, 233.3)
server.UnlockDataModel()
```

### GOOSE publisher

Publish GOOSE messages on layer 2 of a network interface, with a live dataset. From
[test/goose_publisher/goose_publisher_test.go](test/goose_publisher/goose_publisher_test.go):

```go
publisher, err := iec61850.NewGoosePublisher(iec61850.GoosePublisherConf{
    InterfaceID: "eth0",
    AppID:       1000,
    DstAddr:     [6]uint8{0x01, 0x0c, 0xcd, 0x01, 0x00, 0x01},
    VlanPriority: 4,
})
if err != nil {
    panic(err)
}
defer publisher.Close()

publisher.SetGoCbRef("simpleIOGenericIO/LLN0$GO$gcbAnalogValues")
publisher.SetDataSetRef("simpleIOGenericIO/LLN0$AnalogValues")
publisher.SetConfRev(1)
publisher.SetTimeAllowedToLive(500)

lVal := iec61850.NewLinkedListValue()
defer lVal.Destroy()
lVal.Add(&iec61850.MmsValue{Type: iec61850.Int64, Value: time.Now().UnixMilli()})
lVal.Add(&iec61850.MmsValue{Type: iec61850.Float, Value: 233.3})

if err := publisher.Publish(lVal); err != nil {
    panic(err)
}
```

### GOOSE subscriber

Receive GOOSE messages: create a receiver on the interface, register subscribers matched by
AppID and destination MAC, and handle reports in a callback. From
[test/goose_subscriber/goose_subscriber_test.go](test/goose_subscriber/goose_subscriber_test.go):

```go
gooseReceiver := iec61850.NewGooseReceiver()
defer gooseReceiver.Stop().Destroy()

subscriber := iec61850.NewGooseSubscriber(iec61850.SubscriberConf{
    InterfaceID: "eth0",
    AppID:       1000,
    DstMacAddr:  [6]uint8{0x01, 0x0c, 0xcd, 0x01, 0x00, 0x01},
    Subscriber:  "simpleIOGenericIO/LLN0$GO$gcbAnalogValues",
    ReportHandler: func(report *iec61850.GooseReport) {
        fmt.Printf("[appID: %d, goID: %s, stNum: %d]\n", report.GetAppID(), report.GetGoID(), report.GetStNum())
    },
})

if !gooseReceiver.AddSubscriber(subscriber).Start().IsRunning() {
    panic("can't start goose receiver")
}
```

### SV publisher

Publish Sampled Values (IEC 61850-9-2): build one or more ASDUs with float and timestamp
entries, then publish them periodically on the interface. From
[test/sv_publisher/sv_pubisher_test.go](test/sv_publisher/sv_pubisher_test.go):

```go
publisher := iec61850.NewSVPublisher(iec61850.SvPublisherConf{
    EtherName:    "eth0",
    AppID:        12401,
    VlanID:       1,
    VlanPriority: 4,
})
defer publisher.Destroy()

timestamp := iec61850.NewTimestamp()

asdu := publisher.AddSvASDU("svpub1", "svpub1", 1)
floatIndex := asdu.AddFloat()
timeIndex := asdu.AddTimestamp()
publisher.SetupComplete()

publisher.Publish()
```

### SV subscriber

Receive Sampled Values on one interface for one or more AppIDs and decode the ASDU values.
From [test/sv_subscriber/sv_subscriber_test.go](test/sv_subscriber/sv_subscriber_test.go):

```go
receiver := iec61850.NewSvReceiver(iec61850.SvReceiverConf{
    InterfaceID: "eth0",
})
defer receiver.Stop().Destroy()

subscriber := iec61850.NewSvSubscriber(iec61850.SvSubscriberConf{
    AppID: 12401,
    Handler: func(report *iec61850.SvReport) {
        asdu := report.ReceiverASDU
        fmt.Printf("svID: %s; smpCnt: %d; DATA[0]: %f\n", asdu.GetSvID(), asdu.GetSmpCnt(), asdu.GetFloat32(0))
    },
})

if !receiver.AddSubscriber(subscriber).Start().IsRunning() {
    panic("can not start sv receiver")
}
```

### TLS server

Serve MMS over TLS: build a `TLSConfig` with the server key/certificate, CA and allowed
client certificates, then start the server on the TLS port (`-1`). From
[test/tls_server/tls_server_test.go](test/tls_server/tls_server_test.go):

```go
model, err := iec61850.CreateModelFromConfigFileEx("model.cfg")
if err != nil {
    panic(err)
}

tlsConfig := iec61850.NewTLSConfig()
tlsConfig.KeyFile = "server_CA1_1.key"
tlsConfig.CertFile = "server_CA1_1.pem"
tlsConfig.AddCACertificateFromFile("root_CA1.pem")
tlsConfig.AddAllowedCertificateFromFile("client_CA1_1.pem")
tlsConfig.AllowOnlyKnownCertificates = true

server, err := iec61850.NewServerWithTlsSupport(iec61850.NewServerConfig(), tlsConfig, model)
if err != nil {
    panic(err)
}
defer server.Destroy()
server.Start(-1)
```

### TLS client

Connect to a TLS-enabled server with the client key/certificate and the CA to validate the
server chain. From [test/tls_client/client_read_test.go](test/tls_client/client_read_test.go)
and [test/common.go](test/common.go):

```go
settings := iec61850.NewSettings()
settings.Port = -1

tlsConfig := iec61850.NewTLSConfig()
tlsConfig.KeyFile = "client_CA1_1.key"
tlsConfig.CertFile = "client_CA1_1.pem"
tlsConfig.ChainValidation = true
tlsConfig.AllowOnlyKnownCertificates = false
tlsConfig.AddCACertificateFromFile("root_CA1.pem")

client, err := iec61850.NewClientWithTlsSupport(settings, tlsConfig)
if err != nil {
    panic(err)
}
defer client.Close()
```

## SCL / ICD file parsing

Besides the compiled static model format used above, this repository also provides an XML
based reader for ICD files in the [`scl_xml`](scl_xml) package, used by
[test/scl/scl_test.go](test/scl/scl_test.go) with [`test/scl/test.icd`](test/scl/test.icd).

## License

iec61850 is based on the [GPL-3.0 license](./LICENSE) agreement, and iec61850 relies on some third-party components whose open source agreement is GPL-3.0 and MIT.