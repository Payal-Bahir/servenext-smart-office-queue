package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"math"
	"net/http"
	"strconv"
	"time"
)



type apiErr struct {
	Code int
	Msg  string
}

func (e *apiErr) Error() string { return e.Msg }

func httpErr(code int, msg string) error { return &apiErr{code, msg} }

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func wrap(fn func(http.ResponseWriter, *http.Request) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := fn(w, r); err != nil {
			var ae *apiErr
			if errors.As(err, &ae) {
				writeJSON(w, ae.Code, map[string]string{"error": ae.Msg})
				return
			}
			log.Printf("ERROR %s %s: %v", r.Method, r.URL.Path, err)
			writeJSON(w, 500, map[string]string{"error": "internal server error"})
		}
	}
}

func readJSON(r *http.Request, v any) error {
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(v); err != nil {
		return httpErr(400, "invalid JSON body")
	}
	return nil
}

func pathID(r *http.Request) (int, error) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil || id <= 0 {
		return 0, httpErr(400, "invalid id")
	}
	return id, nil
}


type dbq interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func (a *App) tx(ctx context.Context, fn func(*sql.Tx) error) error {
	t, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(t); err != nil {
		_ = t.Rollback()
		return err
	}
	return t.Commit()
}

func logEvent(ctx context.Context, q dbq, tokenID, deptID int, event string, staffID *int, detail string) error {
	_, err := q.ExecContext(ctx,
		`INSERT INTO token_events (token_id, department_id, event, staff_id, detail) VALUES ($1,$2,$3,$4,$5)`,
		tokenID, deptID, event, staffID, detail)
	return err
}



type TokenView struct {
	ID                   int        `json:"id"`
	TokenNumber          string     `json:"token_number"`
	DepartmentID         int        `json:"department_id"`
	DepartmentCode       string     `json:"department_code"`
	DepartmentName       string     `json:"department_name"`
	DepartmentPaused     bool       `json:"department_paused"`
	VisitorName          string     `json:"visitor_name"`
	IsPriority           bool       `json:"is_priority"`
	Status               string     `json:"status"` 
	NoShowCount          int        `json:"no_show_count"`
	CancelReason         string     `json:"cancel_reason,omitempty"`
	TransferredFrom      string     `json:"transferred_from,omitempty"`
	CreatedAt            time.Time  `json:"created_at"`
	CalledAt             *time.Time `json:"called_at,omitempty"`
	Position             int        `json:"position"` 
	PeopleAhead          int        `json:"people_ahead"`
	EstimatedWaitMinutes int        `json:"estimated_wait_minutes"`
	NowServing           string     `json:"now_serving"`
}

const tokenSelect = `
SELECT t.id, t.token_number, t.department_id, d.code, d.name, d.is_paused,
       t.visitor_name, t.priority, t.status, t.no_show_count,
       COALESCE(t.cancel_reason,''), COALESCE(t.transferred_from,''),
       t.created_at, t.called_at,
       CASE WHEN t.status='waiting' THEN (
            SELECT COUNT(*) FROM tokens o
            WHERE o.department_id=t.department_id AND o.status='waiting'
              AND (o.priority > t.priority
                   OR (o.priority = t.priority AND (o.queue_time < t.queue_time
                        OR (o.queue_time = t.queue_time AND o.id < t.id))))
       ) ELSE 0 END,
       COALESCE((SELECT s.token_number FROM tokens s
                 WHERE s.department_id=t.department_id AND s.status='serving' LIMIT 1), '')
FROM tokens t JOIN departments d ON d.id=t.department_id`

type scanner interface{ Scan(dest ...any) error }

func scanToken(s scanner) (*TokenView, error) {
	var t TokenView
	var prio, ahead int
	var called sql.NullTime
	if err := s.Scan(&t.ID, &t.TokenNumber, &t.DepartmentID, &t.DepartmentCode, &t.DepartmentName,
		&t.DepartmentPaused, &t.VisitorName, &prio, &t.Status, &t.NoShowCount, &t.CancelReason,
		&t.TransferredFrom, &t.CreatedAt, &called, &ahead, &t.NowServing); err != nil {
		return nil, err
	}
	t.IsPriority = prio == 1
	if called.Valid {
		t.CalledAt = &called.Time
	}
	if t.Status == "waiting" {
		t.PeopleAhead = ahead
		t.Position = ahead + 1
	}
	return &t, nil
}


type timing struct{ avg, remaining float64 } 

func (t timing) estimate(ahead int) int {
	return int(math.Ceil(float64(ahead)*t.avg + t.remaining))
}

func (a *App) deptTiming(ctx context.Context, q dbq, dept int) (timing, error) {
	var def int
	if err := q.QueryRowContext(ctx, `SELECT default_service_minutes FROM departments WHERE id=$1`, dept).Scan(&def); err != nil {
		return timing{}, err
	}
	var avg float64
	if err := q.QueryRowContext(ctx, `
		SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (completed_at - called_at)))/60.0, 0) FROM (
		  SELECT completed_at, called_at FROM tokens
		  WHERE department_id=$1 AND status='completed' AND called_at IS NOT NULL
		  ORDER BY completed_at DESC LIMIT 20) x`, dept).Scan(&avg); err != nil {
		return timing{}, err
	}
	if avg < 0.5 { 
		avg = float64(def)
	}
	t := timing{avg: avg}
	var called sql.NullTime
	err := q.QueryRowContext(ctx, `SELECT called_at FROM tokens WHERE department_id=$1 AND status='serving'`, dept).Scan(&called)
	if err == nil && called.Valid {
		if rem := avg - time.Since(called.Time).Minutes(); rem > 0 {
			t.remaining = rem
		}
	} else if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return timing{}, err
	}
	return t, nil
}


func (a *App) getToken(ctx context.Context, q dbq, id int) (*TokenView, error) {
	t, err := scanToken(q.QueryRowContext(ctx, tokenSelect+` WHERE t.id=$1`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, httpErr(404, "token not found")
	}
	if err != nil {
		return nil, err
	}
	if t.Status == "waiting" {
		tm, err := a.deptTiming(ctx, q, t.DepartmentID)
		if err != nil {
			return nil, err
		}
		t.EstimatedWaitMinutes = tm.estimate(t.PeopleAhead)
	}
	return t, nil
}

func (a *App) waitingList(ctx context.Context, q dbq, dept int) ([]*TokenView, error) {
	tm, err := a.deptTiming(ctx, q, dept)
	if err != nil {
		return nil, err
	}
	rows, err := q.QueryContext(ctx, tokenSelect+
		` WHERE t.department_id=$1 AND t.status='waiting' ORDER BY t.priority DESC, t.queue_time, t.id`, dept)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := []*TokenView{}
	for rows.Next() {
		t, err := scanToken(rows)
		if err != nil {
			return nil, err
		}
		t.EstimatedWaitMinutes = tm.estimate(t.PeopleAhead)
		list = append(list, t)
	}
	return list, rows.Err()
}
