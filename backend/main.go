package main

import (
	"database/sql"
	_ "embed"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"
)

var schemaSQL string

type App struct {
	db     *sql.DB
	secret []byte
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	dsn := env("DATABASE_URL", "postgres://queue:queue@localhost:5432/queuedb?sslmode=disable")
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(20)

	for i := 0; i < 30; i++ { 
		if err = db.Ping(); err == nil {
			break
		}
		log.Printf("waiting for database... (%v)", err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("database unreachable: %v", err)
	}

	a := &App{db: db, secret: []byte(env("AUTH_SECRET", "dev-secret-change-me"))}
	if _, err := db.Exec(schemaSQL); err != nil {
		log.Fatalf("applying schema: %v", err)
	}
	if err := a.seedStaff(); err != nil {
		log.Fatalf("seeding staff: %v", err)
	}

	addr := ":" + env("PORT", "8080")
	log.Printf("ServeNext API listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, cors(a.routes())))
}

func (a *App) routes() http.Handler {
	m := http.NewServeMux()

	
	m.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]string{"status": "ok"})
	})
	m.HandleFunc("GET /api/departments", wrap(a.listDepartments))
	m.HandleFunc("POST /api/tokens", wrap(a.createToken))
	m.HandleFunc("GET /api/tokens/{id}", wrap(a.getTokenHandler))
	m.HandleFunc("POST /api/tokens/{id}/cancel", wrap(a.cancelToken))

	
	m.HandleFunc("POST /api/auth/login", wrap(a.login))
	m.HandleFunc("GET /api/admin/me", a.authed(a.me))
	m.HandleFunc("GET /api/admin/dashboard", a.authed(a.dashboard))
	m.HandleFunc("GET /api/admin/queue", a.authed(a.adminQueue))
	m.HandleFunc("POST /api/admin/departments/{id}/call-next", a.authed(a.callNext))
	m.HandleFunc("POST /api/admin/departments/{id}/pause", a.authed(a.setPaused))
	m.HandleFunc("POST /api/admin/tokens/{id}/complete", a.authed(a.completeToken))
	m.HandleFunc("POST /api/admin/tokens/{id}/no-show", a.authed(a.noShow))
	m.HandleFunc("POST /api/admin/tokens/{id}/transfer", a.authed(a.transferToken))
	m.HandleFunc("POST /api/admin/tokens/{id}/priority", a.authed(a.setPriority))
	return m
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
