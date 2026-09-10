package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"aster/internal/app"
)

func TestAuthRejectsWithoutToken(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	token := a.APIToken()
	if token == "" {
		t.Fatal("expected token")
	}
	srv := &Server{App: a}
	h := srv.Handler()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/nodes", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rr.Code)
	}

	req2 := httptest.NewRequest(http.MethodGet, "/api/v1/nodes", nil)
	req2.Header.Set("Authorization", "Bearer "+token)
	rr2 := httptest.NewRecorder()
	h.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusOK {
		t.Fatalf("expected 200 with token, got %d body=%s", rr2.Code, rr2.Body.String())
	}

	req3 := httptest.NewRequest(http.MethodGet, "/api/v1/status", nil)
	rr3 := httptest.NewRecorder()
	h.ServeHTTP(rr3, req3)
	if rr3.Code != http.StatusOK {
		t.Fatalf("status should be public, got %d", rr3.Code)
	}
}

func TestWebSocketOriginAllowsOnlyExactLocalOrigins(t *testing.T) {
	for _, tc := range []struct {
		origin string
		want   bool
	}{
		{"", true},
		{"http://127.0.0.1:1780", true},
		{"https://localhost", true},
		{"http://[::1]:1780", true},
		{"file://", true},
		{"http://127.0.0.1.evil.example", false},
		{"https://localhost.evil.example", false},
		{"file://evil.example/path", false},
		{"chrome-extension://local", false},
	} {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/ws/status", nil)
		if tc.origin != "" {
			req.Header.Set("Origin", tc.origin)
		}
		if got := upgrader.CheckOrigin(req); got != tc.want {
			t.Fatalf("origin %q accepted=%v, want %v", tc.origin, got, tc.want)
		}
	}
}

func TestActivateFailureReturnsCurrentActiveProfile(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	active := a.Store().Get().ActiveConfigID
	h := (&Server{App: a}).Handler()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/configs/does-not-exist/activate", nil)
	req.Header.Set("Authorization", "Bearer "+a.APIToken())
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", rr.Code, rr.Body.String())
	}
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["activeConfigId"] != active || body["error"] == "" {
		t.Fatalf("unexpected response: %+v", body)
	}
}

func TestMalformedPowerRequestDoesNotChangeState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	h := (&Server{App: a}).Handler()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/power", bytes.NewBufferString("{"))
	req.Header.Set("Authorization", "Bearer "+a.APIToken())
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("code=%d", rr.Code)
	}
	if !a.Store().Get().Wanted {
		t.Fatal("malformed request changed power state")
	}
}

func TestConfigCreationRejectsCrossModeFieldsWithoutChangingState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	h := (&Server{App: a}).Handler()
	for _, body := range []string{
		`{"kind":"subscription","content":"{\"outbounds\":[]}","urls":["https://example.test/sub"]}`,
		`{"kind":"nodes","content":"vmess://ignored","urls":["https://example.test/sub"]}`,
	} {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/configs", bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer "+a.APIToken())
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("body=%s code=%d response=%s", body, rr.Code, rr.Body.String())
		}
	}
	if got := len(a.Store().Get().Profiles); got != 1 {
		t.Fatalf("cross-mode requests created profile count=%d", got)
	}
}

func TestTrailingJSONDoesNotChangeState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	h := (&Server{App: a}).Handler()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/power", bytes.NewBufferString(`{"on":false}{"on":true}`))
	req.Header.Set("Authorization", "Bearer "+a.APIToken())
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", rr.Code, rr.Body.String())
	}
	if !a.Store().Get().Wanted {
		t.Fatal("trailing JSON changed power state")
	}
}

func TestMissingRequiredBooleanDoesNotChangeState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get()
	h := (&Server{App: a}).Handler()
	for _, endpoint := range []string{"/api/v1/power", "/api/v1/capture"} {
		req := httptest.NewRequest(http.MethodPatch, endpoint, bytes.NewBufferString(`{}`))
		if endpoint == "/api/v1/power" {
			req.Method = http.MethodPost
		}
		req.Header.Set("Authorization", "Bearer "+a.APIToken())
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("endpoint=%s code=%d body=%s", endpoint, rr.Code, rr.Body.String())
		}
		after := a.Store().Get()
		if after.Wanted != before.Wanted || after.Capture != before.Capture {
			t.Fatalf("endpoint=%s changed state: before=%+v after=%+v", endpoint, before.Capture, after.Capture)
		}
	}
}

func TestUnknownPowerFieldDoesNotChangeState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	h := (&Server{App: a}).Handler()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/power", bytes.NewBufferString(`{"on":false,"unexpected":true}`))
	req.Header.Set("Authorization", "Bearer "+a.APIToken())
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", rr.Code, rr.Body.String())
	}
	if !a.Store().Get().Wanted {
		t.Fatal("unknown JSON field changed power state")
	}
}

func TestInvalidSettingsPatchDoesNotChangeState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get().Settings
	h := (&Server{App: a}).Handler()
	for _, body := range []string{
		`{"unexpected":true}`,
		`{"mixedPort":0}`,
		`{"delayTimeoutMs":"fast"}`,
		`{}`,
	} {
		req := httptest.NewRequest(http.MethodPatch, "/api/v1/settings", bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer "+a.APIToken())
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != http.StatusBadRequest {
			t.Fatalf("body=%s code=%d response=%s", body, rr.Code, rr.Body.String())
		}
		if got := a.Store().Get().Settings; !reflect.DeepEqual(got, before) {
			t.Fatalf("body=%s changed settings: got=%+v want=%+v", body, got, before)
		}
	}
}

func TestMissingCoreDownloadTagDoesNotChangeState(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	before := a.Store().Get().Settings.CorePath
	h := (&Server{App: a}).Handler()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/core/download", bytes.NewBufferString(`{}`))
	req.Header.Set("Authorization", "Bearer "+a.APIToken())
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := a.Store().Get().Settings.CorePath; got != before {
		t.Fatalf("missing tag changed core path: %q", got)
	}
	req = httptest.NewRequest(http.MethodPost, "/api/v1/core/download", bytes.NewBufferString(`{"tag":"v1.14.0"}`))
	req.Header.Set("Authorization", "Bearer "+a.APIToken())
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("missing checksum code=%d body=%s", rr.Code, rr.Body.String())
	}
	if got := a.Store().Get().Settings.CorePath; got != before {
		t.Fatalf("missing checksum changed core path: %q", got)
	}
}

func TestLegacySUIDEndpointsAreNotRegistered(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		method string
		path   string
	}{
		{http.MethodPost, "/api/v1/core/grant"},
		{http.MethodGet, "/api/v1/core/privilege"},
	} {
		req := httptest.NewRequest(tc.method, tc.path, nil)
		req.Header.Set("Authorization", "Bearer "+a.APIToken())
		rr := httptest.NewRecorder()
		(&Server{App: a}).Handler().ServeHTTP(rr, req)
		if rr.Code != http.StatusNotFound {
			t.Fatalf("legacy SUID endpoint %s %s must not be exposed: code=%d body=%s", tc.method, tc.path, rr.Code, rr.Body.String())
		}
	}
}

func TestStatusWebSocketSendsInitialAndIncrementalEnvelope(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer((&Server{App: a}).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/api/v1/ws/status?token=" + a.APIToken()
	conn, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	readEvent := func() app.Event {
		t.Helper()
		_ = conn.SetReadDeadline(time.Now().Add(time.Second))
		var event app.Event
		if err := conn.ReadJSON(&event); err != nil {
			t.Fatal(err)
		}
		if event.Type != "status" || event.Sequence == 0 || len(event.Data) == 0 {
			t.Fatalf("unexpected event: %+v", event)
		}
		return event
	}

	first := readEvent()
	a.Hub().Broadcast("status", a.Status())
	second := readEvent()
	if second.Sequence <= first.Sequence {
		t.Fatalf("sequence did not advance: first=%d second=%d", first.Sequence, second.Sequence)
	}
}

func TestConnectionsWebSocketSendsReplaceableInitialSnapshot(t *testing.T) {
	t.Setenv("ASTER_DATA_DIR", t.TempDir())
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer((&Server{App: a}).Handler())
	defer server.Close()

	endpoint := "ws" + strings.TrimPrefix(server.URL, "http") + "/api/v1/ws/connections?token=" + a.APIToken()
	conn, _, err := websocket.DefaultDialer.Dial(endpoint, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	var event app.Event
	if err := conn.ReadJSON(&event); err != nil {
		t.Fatal(err)
	}
	if event.Type != "connections" || event.Sequence == 0 {
		t.Fatalf("unexpected event: %+v", event)
	}
	var snapshot app.ConnectionsDelta
	if err := json.Unmarshal(event.Data, &snapshot); err != nil {
		t.Fatal(err)
	}
	if !snapshot.Snapshot || snapshot.Upserts == nil || snapshot.Closed == nil {
		t.Fatalf("connection stream needs a complete snapshot: %+v", snapshot)
	}
}
