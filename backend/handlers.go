package main

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
)



func (a *App) listDepartments(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	rows, err := a.db.QueryContext(ctx, `
		SELECT d.id, d.code, d.name, d.is_paused,
		       (SELECT COUNT(*) FROM tokens t WHERE t.department_id=d.id AND t.status='waiting')
		FROM departments d ORDER BY d.id`)
	if err != nil {
		return err
	}
	type dep struct {
		ID        int    `json:"id"`
		Code      string `json:"code"`
		Name      string `json:"name"`
		IsPaused  bool   `json:"is_paused"`
		Waiting   int    `json:"waiting"`
		EstWait   int    `json:"estimated_wait_minutes"` // for a new (normal) token
		ServingNo string `json:"now_serving"`
	}
	var out []dep
	for rows.Next() {
		var d dep
		if err := rows.Scan(&d.ID, &d.Code, &d.Name, &d.IsPaused, &d.Waiting); err != nil {
			rows.Close()
			return err
		}
		out = append(out, d)
	}
	rows.Close()
	for i := range out {
		tm, err := a.deptTiming(ctx, a.db, out[i].ID)
		if err != nil {
			return err
		}
		out[i].EstWait = tm.estimate(out[i].Waiting)
		err = a.db.QueryRowContext(ctx,
			`SELECT token_number FROM tokens WHERE department_id=$1 AND status='serving'`, out[i].ID).Scan(&out[i].ServingNo)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
	}
	writeJSON(w, 200, out)
	return nil
}

func (a *App) createToken(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		DepartmentID int    `json:"department_id"`
		VisitorName  string `json:"visitor_name"`
		Phone        string `json:"phone"`
	}
	if err := readJSON(r, &in); err != nil {
		return err
	}
	in.VisitorName = strings.TrimSpace(in.VisitorName)
	in.Phone = strings.TrimSpace(in.Phone)
	if in.VisitorName == "" || len(in.VisitorName) > 60 || len(in.Phone) > 20 {
		return httpErr(400, "a visitor name (max 60 chars) is required")
	}
	ctx := r.Context()
	var id int
	err := a.tx(ctx, func(tx *sql.Tx) error {
		var code string
		var seq int
		err := tx.QueryRowContext(ctx,
			`UPDATE departments SET last_seq = last_seq + 1
			 WHERE id=$1 AND is_paused=FALSE RETURNING code, last_seq`, in.DepartmentID).Scan(&code, &seq)
		if errors.Is(err, sql.ErrNoRows) {
			var paused bool
			e2 := a.db.QueryRowContext(ctx, `SELECT is_paused FROM departments WHERE id=$1`, in.DepartmentID).Scan(&paused)
			if errors.Is(e2, sql.ErrNoRows) {
				return httpErr(404, "department not found")
			}
			return httpErr(409, "this department is currently paused and is not issuing tokens")
		}
		if err != nil {
			return err
		}
		number := fmt.Sprintf("%s-%03d", code, seq)
		if err := tx.QueryRowContext(ctx,
			`INSERT INTO tokens (token_number, department_id, visitor_name, visitor_phone, status)
			 VALUES ($1,$2,$3,$4,'waiting') RETURNING id`,
			number, in.DepartmentID, in.VisitorName, in.Phone).Scan(&id); err != nil {
			return err
		}
		return logEvent(ctx, tx, id, in.DepartmentID, "created", nil, "")
	})
	if err != nil {
		return err
	}
	t, err := a.getToken(ctx, a.db, id)
	if err != nil {
		return err
	}
	writeJSON(w, 201, t)
	return nil
}

func (a *App) getTokenHandler(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	t, err := a.getToken(r.Context(), a.db, id)
	if err != nil {
		return err
	}
	writeJSON(w, 200, t)
	return nil
}

func (a *App) cancelToken(w http.ResponseWriter, r *http.Request) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	err = a.tx(ctx, func(tx *sql.Tx) error {
		var dept int
		var status string
		e := tx.QueryRowContext(ctx, `SELECT department_id, status FROM tokens WHERE id=$1 FOR UPDATE`, id).Scan(&dept, &status)
		if errors.Is(e, sql.ErrNoRows) {
			return httpErr(404, "token not found")
		}
		if e != nil {
			return e
		}
		if status != "waiting" {
			return httpErr(409, "only a waiting token can be cancelled")
		}
		if _, e = tx.ExecContext(ctx,
			`UPDATE tokens SET status='cancelled', cancel_reason='cancelled_by_visitor' WHERE id=$1`, id); e != nil {
			return e
		}
		return logEvent(ctx, tx, id, dept, "cancelled", nil, "cancelled by visitor")
	})
	if err != nil {
		return err
	}
	return a.respondToken(w, r, id)
}

func (a *App) respondToken(w http.ResponseWriter, r *http.Request, id int) error {
	t, err := a.getToken(r.Context(), a.db, id)
	if err != nil {
		return err
	}
	writeJSON(w, 200, t)
	return nil
}



type lockedToken struct {
	dept   int
	status string
	number string
	noShow int
}

func lockToken(ctx context.Context, tx *sql.Tx, id int, s *Staff) (*lockedToken, error) {
	var lt lockedToken
	err := tx.QueryRowContext(ctx,
		`SELECT department_id, status, token_number, no_show_count FROM tokens WHERE id=$1 FOR UPDATE`, id,
	).Scan(&lt.dept, &lt.status, &lt.number, &lt.noShow)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, httpErr(404, "token not found")
	}
	if err != nil {
		return nil, err
	}
	if err := s.require(lt.dept); err != nil {
		return nil, err
	}
	return &lt, nil
}

func (a *App) callNext(w http.ResponseWriter, r *http.Request, s *Staff) error {
	dept, err := pathID(r)
	if err != nil {
		return err
	}
	if err := s.require(dept); err != nil {
		return err
	}
	ctx := r.Context()
	var tokenID int
	err = a.tx(ctx, func(tx *sql.Tx) error {
		var paused bool
		e := tx.QueryRowContext(ctx, `SELECT is_paused FROM departments WHERE id=$1 FOR UPDATE`, dept).Scan(&paused)
		if errors.Is(e, sql.ErrNoRows) {
			return httpErr(404, "department not found")
		}
		if e != nil {
			return e
		}
		if paused {
			return httpErr(409, "department is paused - resume it to call tokens")
		}
		var serving int
		if e = tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM tokens WHERE department_id=$1 AND status='serving'`, dept).Scan(&serving); e != nil {
			return e
		}
		if serving > 0 {
			return httpErr(409, "complete or mark no-show for the current token before calling the next one")
		}
		e = tx.QueryRowContext(ctx, `
			SELECT id FROM tokens WHERE department_id=$1 AND status='waiting'
			ORDER BY priority DESC, queue_time, id LIMIT 1 FOR UPDATE SKIP LOCKED`, dept).Scan(&tokenID)
		if errors.Is(e, sql.ErrNoRows) {
			return httpErr(404, "no tokens are waiting in this department")
		}
		if e != nil {
			return e
		}
		if _, e = tx.ExecContext(ctx,
			`UPDATE tokens SET status='serving', called_at=now(), served_by=$2 WHERE id=$1`, tokenID, s.ID); e != nil {
			return e
		}
		return logEvent(ctx, tx, tokenID, dept, "called", &s.ID, "")
	})
	if err != nil {
		return err
	}
	return a.respondToken(w, r, tokenID)
}

func (a *App) completeToken(w http.ResponseWriter, r *http.Request, s *Staff) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	err = a.tx(ctx, func(tx *sql.Tx) error {
		lt, e := lockToken(ctx, tx, id, s)
		if e != nil {
			return e
		}
		if lt.status != "serving" {
			return httpErr(409, "only the token currently being served can be completed")
		}
		if _, e = tx.ExecContext(ctx, `UPDATE tokens SET status='completed', completed_at=now() WHERE id=$1`, id); e != nil {
			return e
		}
		return logEvent(ctx, tx, id, lt.dept, "completed", &s.ID, "")
	})
	if err != nil {
		return err
	}
	return a.respondToken(w, r, id)
}

func (a *App) noShow(w http.ResponseWriter, r *http.Request, s *Staff) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	ctx := r.Context()
	err = a.tx(ctx, func(tx *sql.Tx) error {
		lt, e := lockToken(ctx, tx, id, s)
		if e != nil {
			return e
		}
		if lt.status != "serving" {
			return httpErr(409, "only a called (serving) token can be marked as no-show")
		}
		if lt.noShow+1 >= 2 {
			_, e = tx.ExecContext(ctx, `UPDATE tokens SET status='cancelled', cancel_reason='no_show_twice',
				no_show_count=no_show_count+1 WHERE id=$1`, id)
		} else {
			_, e = tx.ExecContext(ctx, `UPDATE tokens SET status='waiting', called_at=NULL, served_by=NULL,
				queue_time=now(), priority=0, no_show_count=no_show_count+1 WHERE id=$1`, id)
		}
		if e != nil {
			return e
		}
		detail := "moved to end of queue"
		if lt.noShow+1 >= 2 {
			detail = "second no-show - auto cancelled"
		}
		return logEvent(ctx, tx, id, lt.dept, "no_show", &s.ID, detail)
	})
	if err != nil {
		return err
	}
	return a.respondToken(w, r, id)
}

func (a *App) transferToken(w http.ResponseWriter, r *http.Request, s *Staff) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	var in struct {
		DepartmentID int `json:"department_id"`
	}
	if err := readJSON(r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	err = a.tx(ctx, func(tx *sql.Tx) error {
		lt, e := lockToken(ctx, tx, id, s)
		if e != nil {
			return e
		}
		if lt.status != "waiting" && lt.status != "serving" {
			return httpErr(409, "only waiting or serving tokens can be transferred")
		}
		if in.DepartmentID == lt.dept {
			return httpErr(400, "token is already in that department")
		}
		var code string
		var seq int
		e = tx.QueryRowContext(ctx,
			`UPDATE departments SET last_seq=last_seq+1 WHERE id=$1 AND is_paused=FALSE RETURNING code, last_seq`,
			in.DepartmentID).Scan(&code, &seq)
		if errors.Is(e, sql.ErrNoRows) {
			return httpErr(409, "target department does not exist or is paused")
		}
		if e != nil {
			return e
		}
		newNumber := fmt.Sprintf("%s-%03d", code, seq)
		if _, e = tx.ExecContext(ctx, `
			UPDATE tokens SET department_id=$2, token_number=$3, transferred_from=$4, status='waiting',
			       queue_time=now(), called_at=NULL, served_by=NULL WHERE id=$1`,
			id, in.DepartmentID, newNumber, lt.number); e != nil {
			return e
		}
		return logEvent(ctx, tx, id, in.DepartmentID, "transferred", &s.ID, lt.number+" -> "+newNumber)
	})
	if err != nil {
		return err
	}
	return a.respondToken(w, r, id)
}

func (a *App) setPriority(w http.ResponseWriter, r *http.Request, s *Staff) error {
	id, err := pathID(r)
	if err != nil {
		return err
	}
	var in struct {
		Priority bool `json:"priority"`
	}
	if err := readJSON(r, &in); err != nil {
		return err
	}
	ctx := r.Context()
	err = a.tx(ctx, func(tx *sql.Tx) error {
		lt, e := lockToken(ctx, tx, id, s)
		if e != nil {
			return e
		}
		if lt.status != "waiting" {
			return httpErr(409, "priority can only be changed for waiting tokens")
		}
		p, ev := 0, "priority_off"
		if in.Priority {
			p, ev = 1, "priority_on"
		}
		if _, e = tx.ExecContext(ctx, `UPDATE tokens SET priority=$2 WHERE id=$1`, id, p); e != nil {
			return e
		}
		return logEvent(ctx, tx, id, lt.dept, ev, &s.ID, "")
	})
	if err != nil {
		return err
	}
	return a.respondToken(w, r, id)
}

func (a *App) setPaused(w http.ResponseWriter, r *http.Request, s *Staff) error {
	dept, err := pathID(r)
	if err != nil {
		return err
	}
	if err := s.require(dept); err != nil {
		return err
	}
	var in struct {
		Paused bool `json:"paused"`
	}
	if err := readJSON(r, &in); err != nil {
		return err
	}
	res, err := a.db.ExecContext(r.Context(), `UPDATE departments SET is_paused=$2 WHERE id=$1`, dept, in.Paused)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return httpErr(404, "department not found")
	}
	writeJSON(w, 200, map[string]any{"department_id": dept, "is_paused": in.Paused})
	return nil
}

func (a *App) adminQueue(w http.ResponseWriter, r *http.Request, s *Staff) error {
	dept, _ := strconv.Atoi(r.URL.Query().Get("department_id"))
	if dept == 0 && s.DepartmentID != nil {
		dept = *s.DepartmentID
	}
	if dept == 0 {
		return httpErr(400, "department_id is required")
	}
	if err := s.require(dept); err != nil {
		return err
	}
	ctx := r.Context()
	var info struct {
		ID         int     `json:"id"`
		Code       string  `json:"code"`
		Name       string  `json:"name"`
		IsPaused   bool    `json:"is_paused"`
		AvgService float64 `json:"avg_service_minutes"`
	}
	err := a.db.QueryRowContext(ctx, `SELECT id, code, name, is_paused FROM departments WHERE id=$1`, dept).
		Scan(&info.ID, &info.Code, &info.Name, &info.IsPaused)
	if errors.Is(err, sql.ErrNoRows) {
		return httpErr(404, "department not found")
	}
	if err != nil {
		return err
	}
	tm, err := a.deptTiming(ctx, a.db, dept)
	if err != nil {
		return err
	}
	info.AvgService = math.Round(tm.avg*10) / 10

	var serving *TokenView
	t, err := scanToken(a.db.QueryRowContext(ctx, tokenSelect+` WHERE t.department_id=$1 AND t.status='serving'`, dept))
	if err == nil {
		serving = t
	} else if !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	waiting, err := a.waitingList(ctx, a.db, dept)
	if err != nil {
		return err
	}
	writeJSON(w, 200, map[string]any{"department": info, "serving": serving, "waiting": waiting})
	return nil
}

func (a *App) dashboard(w http.ResponseWriter, r *http.Request, s *Staff) error {
	filter := 0
	if s.Role != "admin" && s.DepartmentID != nil {
		filter = *s.DepartmentID
	}
	ctx := r.Context()
	rows, err := a.db.QueryContext(ctx, `
		SELECT d.id, d.code, d.name, d.is_paused,
		  (SELECT COUNT(*) FROM tokens t WHERE t.department_id=d.id AND t.status='waiting'),
		  (SELECT COUNT(*) FROM tokens t WHERE t.department_id=d.id AND t.status='serving'),
		  (SELECT COUNT(*) FROM tokens t WHERE t.department_id=d.id AND t.status='completed' AND t.completed_at >= date_trunc('day', now())),
		  (SELECT COUNT(*) FROM token_events e WHERE e.department_id=d.id AND e.event='no_show' AND e.created_at >= date_trunc('day', now())),
		  (SELECT COUNT(*) FROM tokens t WHERE t.department_id=d.id AND t.status='cancelled' AND t.created_at >= date_trunc('day', now())),
		  COALESCE((SELECT AVG(EXTRACT(EPOCH FROM (t.called_at - t.created_at)))/60.0 FROM tokens t
		            WHERE t.department_id=d.id AND t.called_at >= date_trunc('day', now())), 0)
		FROM departments d WHERE ($1 = 0 OR d.id = $1) ORDER BY d.id`, filter)
	if err != nil {
		return err
	}
	defer rows.Close()

	type stat struct {
		ID        int     `json:"id"`
		Code      string  `json:"code"`
		Name      string  `json:"name"`
		IsPaused  bool    `json:"is_paused"`
		Waiting   int     `json:"waiting"`
		Serving   int     `json:"serving"`
		Completed int     `json:"completed"`
		NoShows   int     `json:"no_shows"`
		Cancelled int     `json:"cancelled"`
		AvgWait   float64 `json:"avg_wait_minutes"`
	}
	depts := []stat{}
	totals := stat{Name: "All departments"}
	for rows.Next() {
		var d stat
		if err := rows.Scan(&d.ID, &d.Code, &d.Name, &d.IsPaused, &d.Waiting, &d.Serving,
			&d.Completed, &d.NoShows, &d.Cancelled, &d.AvgWait); err != nil {
			return err
		}
		d.AvgWait = math.Round(d.AvgWait*10) / 10
		totals.Waiting += d.Waiting
		totals.Serving += d.Serving
		totals.Completed += d.Completed
		totals.NoShows += d.NoShows
		totals.Cancelled += d.Cancelled
		depts = append(depts, d)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	var avg float64
	if err := a.db.QueryRowContext(ctx, `
		SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (t.called_at - t.created_at)))/60.0, 0) FROM tokens t
		WHERE t.called_at >= date_trunc('day', now()) AND ($1 = 0 OR t.department_id = $1)`, filter).Scan(&avg); err != nil {
		return err
	}
	totals.AvgWait = math.Round(avg*10) / 10
	writeJSON(w, 200, map[string]any{"totals": totals, "departments": depts})
	return nil
}
