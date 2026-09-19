package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"

	"gofr.dev/pkg/gofr"
	"gofr.dev/pkg/gofr/migration"
)

type order struct {
	ID        string    `json:"id"`
	ItemID    string    `json:"itemId"`
	Quantity  int       `json:"quantity"`
	State     string    `json:"state"`
	Item      any       `json:"item,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}

type orderInput struct {
	ItemID   string `json:"itemId"`
	Quantity int    `json:"quantity"`
	State    string `json:"state"`
}

const createOrdersTable = `
CREATE TABLE IF NOT EXISTS orders (
  id VARCHAR(80) PRIMARY KEY,
  item_id VARCHAR(120) NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  state VARCHAR(32) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
)`

const orderLifecycleMetric = "order_lifecycle_operations"

func main() {
	app := gofr.New()
	// Operation/result are deliberately bounded labels. Order and item IDs are
	// logged and traced, but never attached to metrics where they would create
	// unbounded Prometheus cardinality.
	app.Metrics().NewCounter(orderLifecycleMetric, "Successful order lifecycle operations")
	migrations := map[int64]migration.Migrate{
		2026091901: {UP: func(d migration.Datasource) error {
			if _, err := d.SQL.Exec(createOrdersTable); err != nil {
				return err
			}
			_, err := d.SQL.Exec(`
INSERT INTO orders (id, item_id, quantity, state)
VALUES ('order-demo-001', 'sku-001', 1, 'ready')
ON CONFLICT (id) DO NOTHING`)
			return err
		}},
	}
	app.OnStart(func(*gofr.Context) error {
		app.Migrate(migrations)
		return nil
	})

	catalogURL := os.Getenv("CATALOG_URL")
	if catalogURL == "" {
		catalogURL = "http://catalog:8000"
	}
	app.AddHTTPService("catalog", catalogURL)

	app.GET("/api/orders", listOrders)
	app.GET("/api/orders/{id}", getOrder)
	app.POST("/api/orders", createOrder)
	app.PUT("/api/orders/{id}", updateOrder)
	app.PATCH("/api/orders/{id}", updateOrder)
	app.DELETE("/api/orders/{id}", deleteOrder)
	app.GET("/api/orders/health", func(*gofr.Context) (any, error) {
		return map[string]string{"service": "orders", "status": "ok", "version": os.Getenv("SERVICE_VERSION")}, nil
	})
	app.Run()
}

func validateOrderInput(input orderInput) error {
	if input.ItemID == "" || input.Quantity < 1 {
		return errors.New("itemId and a positive quantity are required")
	}

	return nil
}

func listOrders(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("orders.list").End()
	rows, err := ctx.SQL.QueryContext(ctx, `
SELECT id, item_id, quantity, state, created_at, updated_at
FROM orders ORDER BY created_at DESC`)
	if err != nil {
		return nil, fmt.Errorf("list orders: %w", err)
	}
	defer rows.Close()

	orders := make([]order, 0)
	for rows.Next() {
		var current order
		if err := rows.Scan(&current.ID, &current.ItemID, &current.Quantity, &current.State, &current.CreatedAt, &current.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan order: %w", err)
		}
		current.Item, err = catalogItem(ctx, current.ItemID)
		if err != nil {
			return nil, err
		}
		orders = append(orders, current)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate orders: %w", err)
	}
	ctx.Info("orders listed", "count", len(orders))
	return orders, nil
}

func getOrder(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("orders.get").End()
	current, err := readOrder(ctx, ctx.PathParam("id"))
	if err != nil {
		return nil, err
	}
	current.Item, err = catalogItem(ctx, current.ItemID)
	if err != nil {
		return nil, err
	}
	return current, nil
}

func createOrder(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("orders.create").End()
	var input orderInput
	if err := ctx.Bind(&input); err != nil {
		return nil, fmt.Errorf("invalid order body: %w", err)
	}
	if err := validateOrderInput(input); err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	current := order{ID: fmt.Sprintf("order-%d", now.UnixNano()), ItemID: input.ItemID, Quantity: input.Quantity, State: "created", CreatedAt: now, UpdatedAt: now}
	if _, err := ctx.SQL.ExecContext(ctx, `
INSERT INTO orders (id, item_id, quantity, state, created_at, updated_at)
VALUES ($1, $2, $3, $4, $5, $6)`, current.ID, current.ItemID, current.Quantity, current.State, current.CreatedAt, current.UpdatedAt); err != nil {
		return nil, fmt.Errorf("create order: %w", err)
	}
	var err error
	current.Item, err = catalogItem(ctx, current.ItemID)
	if err != nil {
		return nil, err
	}
	ctx.Info("order created", "order_id", current.ID, "item_id", current.ItemID)
	ctx.Metrics().IncrementCounter(ctx, orderLifecycleMetric, "operation", "create", "result", "success")
	return current, nil
}

func updateOrder(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("orders.update").End()
	var input orderInput
	if err := ctx.Bind(&input); err != nil {
		return nil, fmt.Errorf("invalid order body: %w", err)
	}
	if err := validateOrderInput(input); err != nil {
		return nil, err
	}
	if input.State == "" {
		input.State = "updated"
	}
	result, err := ctx.SQL.ExecContext(ctx, `
UPDATE orders SET item_id = $1, quantity = $2, state = $3, updated_at = CURRENT_TIMESTAMP WHERE id = $4`, input.ItemID, input.Quantity, input.State, ctx.PathParam("id"))
	if err != nil {
		return nil, fmt.Errorf("update order: %w", err)
	}
	if affected, err := result.RowsAffected(); err != nil || affected == 0 {
		return nil, fmt.Errorf("order %q not found", ctx.PathParam("id"))
	}
	current, err := getOrder(ctx)
	if err == nil {
		ctx.Metrics().IncrementCounter(ctx, orderLifecycleMetric, "operation", "update", "result", "success")
		ctx.Info("order updated", "order_id", ctx.PathParam("id"), "state", input.State)
	}
	return current, err
}

func deleteOrder(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("orders.delete").End()
	result, err := ctx.SQL.ExecContext(ctx, "DELETE FROM orders WHERE id = $1", ctx.PathParam("id"))
	if err != nil {
		return nil, fmt.Errorf("delete order: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil || affected == 0 {
		return nil, fmt.Errorf("order %q not found", ctx.PathParam("id"))
	}
	ctx.Info("order deleted", "order_id", ctx.PathParam("id"))
	ctx.Metrics().IncrementCounter(ctx, orderLifecycleMetric, "operation", "delete", "result", "success")
	return map[string]string{"deleted": ctx.PathParam("id")}, nil
}

func readOrder(ctx *gofr.Context, id string) (order, error) {
	var current order
	err := ctx.SQL.QueryRowContext(ctx, `
SELECT id, item_id, quantity, state, created_at, updated_at FROM orders WHERE id = $1`, id).
		Scan(&current.ID, &current.ItemID, &current.Quantity, &current.State, &current.CreatedAt, &current.UpdatedAt)
	if err != nil {
		return order{}, fmt.Errorf("read order %q: %w", id, err)
	}
	return current, nil
}

func catalogItem(ctx *gofr.Context, id string) (any, error) {
	response, err := ctx.GetHTTPService("catalog").Get(ctx, "/api/catalog/"+url.PathEscape(id), nil)
	if err != nil {
		return nil, fmt.Errorf("catalog request: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode >= http.StatusBadRequest {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4<<10))
		return nil, fmt.Errorf("catalog returned %s: %s", response.Status, string(body))
	}
	var envelope struct {
		Data any `json:"data"`
	}
	if err := json.NewDecoder(response.Body).Decode(&envelope); err != nil {
		return nil, fmt.Errorf("decode catalog response: %w", err)
	}
	return envelope.Data, nil
}
