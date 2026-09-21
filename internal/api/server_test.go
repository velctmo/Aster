package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"aster/internal/app"
	"aster/internal/state"
)

func TestEvaluateRule_Unauthorized(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}

	srv := &Server{App: a}
	h := srv.Handler()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/rules/evaluate?target=google.com", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 Unauthorized, got %d", rr.Code)
	}
}

func TestEvaluateRule_MissingTarget(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	token := a.APIToken()

	srv := &Server{App: a}
	h := srv.Handler()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/rules/evaluate", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 Bad Request when target is missing, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	var errResp map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("failed to decode error response: %v", err)
	}
	if errResp["error"] == "" {
		t.Fatalf("expected non-empty error message, got %v", errResp)
	}
}

func TestEvaluateRule_Success(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	token := a.APIToken()

	if _, err := a.Store().Update(func(f *state.File) error {
		f.Rules = []state.Rule{
			{ID: "r1", Match: "domain_suffix", Value: "google.com", Action: "proxy"},
		}
		f.Selected = "tokyo-proxy-01"
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	srv := &Server{App: a}
	h := srv.Handler()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/rules/evaluate?target=google.com&process=curl&port=443&network=tcp", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	var res app.RuleEvaluateResult
	if err := json.Unmarshal(rr.Body.Bytes(), &res); err != nil {
		t.Fatalf("failed to unmarshal RuleEvaluateResult: %v", err)
	}

	if res.Target != "google.com" {
		t.Errorf("expected target google.com, got %s", res.Target)
	}
	if !res.Matched {
		t.Errorf("expected matched true, got false")
	}
	if res.RuleType != "domain_suffix" {
		t.Errorf("expected ruleType domain_suffix, got %s", res.RuleType)
	}
	if res.Outbound != "proxy" {
		t.Errorf("expected outbound proxy, got %s", res.Outbound)
	}
	if res.SelectedNode != "tokyo-proxy-01" {
		t.Errorf("expected selectedNode tokyo-proxy-01, got %s", res.SelectedNode)
	}
	if res.EvaluationTimeMs < 0 {
		t.Errorf("expected evaluationTimeMs >= 0, got %f", res.EvaluationTimeMs)
	}
}

func TestEvaluateRule_QueryToken(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	token := a.APIToken()

	srv := &Server{App: a}
	h := srv.Handler()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/rules/evaluate?target=google.com&token="+token, nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200 OK with query token, got %d (body: %s)", rr.Code, rr.Body.String())
	}
}

func TestGetConfigContent(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("ASTER_DATA_DIR", dir)
	a, err := app.New()
	if err != nil {
		t.Fatal(err)
	}
	token := a.APIToken()

	raw := `{"outbounds":[{"type":"direct","tag":"direct"},{"type":"shadowsocks","tag":"ss-node","server":"1.1.1.1","server_port":443,"method":"aes-128-gcm","password":"p"}]}`
	if err := a.CreateSubscriptionProfile("API内容测试", "", raw); err != nil {
		t.Fatal(err)
	}
	profiles := a.Store().Get().Profiles
	var targetID string
	for _, p := range profiles {
		if p.Name == "API内容测试" {
			targetID = p.ID
			break
		}
	}
	if targetID == "" {
		t.Fatal("profile not found")
	}

	srv := &Server{App: a}
	h := srv.Handler()

	// Unauthorized
	req := httptest.NewRequest(http.MethodGet, "/api/v1/configs/"+targetID+"/content", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rr.Code)
	}

	// 404 Not Found
	req = httptest.NewRequest(http.MethodGet, "/api/v1/configs/nonexistent/content", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", rr.Code)
	}

	// 200 OK
	req = httptest.NewRequest(http.MethodGet, "/api/v1/configs/"+targetID+"/content", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	var res app.ProfileContentJSON
	if err := json.Unmarshal(rr.Body.Bytes(), &res); err != nil {
		t.Fatalf("failed to decode ProfileContentJSON: %v", err)
	}
	if res.ID != targetID || res.Format != "json" || res.NodeCount != 1 {
		t.Fatalf("unexpected res: %+v", res)
	}
}

