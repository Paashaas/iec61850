package server

import (
	"testing"
	"time"

	"github.com/Paashaas/iec61850"
)

// TestConnectionHandlerAbortNoDeadlock is a regression test for the abort deadlock
// (libiec61850 LIB61850-608): ClientConnection_abort deadlocked in multi-threaded
// mode. It claims ownership of a connection inside the handler, aborts it from
// application code, and fails via watchdog timeouts if any step hangs.
func TestConnectionHandlerAbortNoDeadlock(t *testing.T) {
	const port = 10402

	model, err := iec61850.CreateModelFromConfigFileEx("simpleIO_control_tests.cfg")
	if err != nil {
		t.Fatalf("create model: %v", err)
	}
	server := iec61850.NewServerWithConfig(iec61850.NewServerConfig(), model)

	type event struct {
		conn      *iec61850.ClientConnection
		connected bool
		peer      string
	}
	events := make(chan event, 8)
	server.SetConnectionHandler(func(conn *iec61850.ClientConnection, connected bool) {
		peer := conn.GetPeerAddress()
		var owned *iec61850.ClientConnection
		if connected {
			owned = conn.ClaimOwnership()
		}
		events <- event{conn: owned, connected: connected, peer: peer}
	})

	server.Start(port)
	defer server.Stop()
	time.Sleep(300 * time.Millisecond)

	settings := iec61850.NewSettings()
	settings.Host = "localhost"
	settings.Port = port
	client, err := iec61850.NewClient(settings)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	defer client.Close()

	var owned *iec61850.ClientConnection
	select {
	case ev := <-events:
		if !ev.connected {
			t.Fatalf("expected a connect indication first, got disconnect")
		}
		t.Logf("connect indication received, peer=%q", ev.peer)
		owned = ev.conn
	case <-time.After(2 * time.Second):
		t.Fatal("connection handler never fired on connect — possible deadlock")
	}
	if owned == nil {
		t.Fatal("ClaimOwnership returned nil")
	}

	done := make(chan bool, 1)
	go func() {
		aborted := owned.Abort()
		owned.Release()
		done <- aborted
	}()
	select {
	case aborted := <-done:
		t.Logf("ClientConnection.Abort() returned %v without deadlocking", aborted)
	case <-time.After(3 * time.Second):
		t.Fatal("ClientConnection.Abort() did not return — deadlock still present")
	}

	deadline := time.Now().Add(2 * time.Second)
	for server.GetNumberOfOpenConnections() > 0 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if n := server.GetNumberOfOpenConnections(); n != 0 {
		t.Errorf("after abort, open connections = %d, want 0", n)
	}
}
