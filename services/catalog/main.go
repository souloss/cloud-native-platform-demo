package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/redis/go-redis/v9"
	"gofr.dev/pkg/gofr"
	"gofr.dev/pkg/gofr/migration"
)

type item struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

type itemInput struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

const createCatalogTable = `
CREATE TABLE IF NOT EXISTS catalog_items (
  id VARCHAR(120) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  description TEXT NOT NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
)`

const catalogCacheMetric = "catalog_cache_operations"

func main() {
	app := gofr.New()
	// 缓存结果是基数受控的业务信号。商品 ID 保留在链路和日志中，不放入指标标签，
	// 避免 Prometheus 序列数量随着商品目录规模增长。
	app.Metrics().NewCounter(catalogCacheMetric, "Catalog cache operations by result")
	migrations := map[int64]migration.Migrate{
		2026091901: {UP: func(d migration.Datasource) error {
			if _, err := d.SQL.Exec(createCatalogTable); err != nil {
				return err
			}
			_, err := d.SQL.Exec(`
INSERT INTO catalog_items (id, name, description)
VALUES ('sku-001', 'K3s starter', 'A small Kubernetes playground'),
       ('sku-002', 'Gateway API route', 'A portable HTTP routing contract')
ON DUPLICATE KEY UPDATE name = VALUES(name), description = VALUES(description)`)
			return err
		}},
		2026091902: {UP: func(d migration.Datasource) error {
			_, err := d.SQL.Exec(`
INSERT INTO catalog_items (id, name, description)
VALUES ('sku-1', 'Legacy starter item', 'Compatibility item for orders created by the original demo')
ON DUPLICATE KEY UPDATE name = VALUES(name), description = VALUES(description)`)
			return err
		}},
	}
	app.OnStart(func(*gofr.Context) error {
		app.Migrate(migrations)
		return nil
	})

	app.GET("/api/catalog", listItems)
	app.GET("/api/catalog/{id}", getItem)
	app.POST("/api/catalog", createItem)
	app.PUT("/api/catalog/{id}", updateItem)
	app.PATCH("/api/catalog/{id}", updateItem)
	app.DELETE("/api/catalog/{id}", deleteItem)
	app.GET("/api/catalog/health", func(*gofr.Context) (any, error) {
		return map[string]string{"service": "catalog", "status": "ok", "version": os.Getenv("SERVICE_VERSION")}, nil
	})
	app.Run()
}

func validateItemInput(input itemInput) error {
	if input.Name == "" || input.Description == "" {
		return errors.New("name and description are required")
	}

	return nil
}

func listItems(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("catalog.list").End()
	rows, err := ctx.SQL.QueryContext(ctx, "SELECT id, name, description FROM catalog_items ORDER BY id")
	if err != nil {
		return nil, fmt.Errorf("list catalog: %w", err)
	}
	defer rows.Close()
	items := make([]item, 0)
	for rows.Next() {
		var current item
		if err := rows.Scan(&current.ID, &current.Name, &current.Description); err != nil {
			return nil, fmt.Errorf("scan catalog item: %w", err)
		}
		items = append(items, current)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate catalog: %w", err)
	}
	ctx.Info("catalog listed", "count", len(items))
	return items, nil
}

func getItem(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("catalog.get").End()
	id := ctx.PathParam("id")
	if id == "" {
		return nil, errors.New("catalog id is required")
	}

	cacheKey := "catalog:item:" + id
	if cached, err := ctx.Redis.Get(ctx, cacheKey).Result(); err == nil {
		var cachedItem item
		if err := json.Unmarshal([]byte(cached), &cachedItem); err == nil {
			ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "read", "result", "hit")
			ctx.Info("catalog cache hit", "id", id)
			return cachedItem, nil
		}
		ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "read", "result", "invalid")
		ctx.Warn("catalog cache value is invalid", "id", id)
	} else if errors.Is(err, redis.Nil) {
		ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "read", "result", "miss")
	} else {
		ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "read", "result", "error")
		ctx.Warn("catalog cache unavailable", "error", err)
	}

	var current item
	err := ctx.SQL.QueryRowContext(ctx, "SELECT id, name, description FROM catalog_items WHERE id = ?", id).
		Scan(&current.ID, &current.Name, &current.Description)
	if err != nil {
		return nil, fmt.Errorf("read catalog item %q: %w", id, err)
	}
	encoded, err := json.Marshal(current)
	if err == nil {
		if cacheErr := ctx.Redis.Set(ctx, cacheKey, encoded, 0).Err(); cacheErr != nil {
			ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "write", "result", "error")
			ctx.Warn("catalog cache write failed", "error", cacheErr)
		} else {
			ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "write", "result", "success")
		}
	}
	ctx.Info("catalog cache miss", "id", id)
	return current, nil
}

func createItem(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("catalog.create").End()
	var input itemInput
	if err := ctx.Bind(&input); err != nil {
		return nil, fmt.Errorf("invalid catalog body: %w", err)
	}
	if err := validateItemInput(input); err != nil {
		return nil, err
	}
	id := fmt.Sprintf("sku-%d", time.Now().UnixNano())
	if _, err := ctx.SQL.ExecContext(ctx, "INSERT INTO catalog_items (id, name, description) VALUES (?, ?, ?)", id, input.Name, input.Description); err != nil {
		return nil, fmt.Errorf("create catalog item: %w", err)
	}
	return item{ID: id, Name: input.Name, Description: input.Description}, nil
}

func updateItem(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("catalog.update").End()
	var input itemInput
	if err := ctx.Bind(&input); err != nil {
		return nil, fmt.Errorf("invalid catalog body: %w", err)
	}
	if err := validateItemInput(input); err != nil {
		return nil, err
	}
	result, err := ctx.SQL.ExecContext(ctx, "UPDATE catalog_items SET name = ?, description = ? WHERE id = ?", input.Name, input.Description, ctx.PathParam("id"))
	if err != nil {
		return nil, fmt.Errorf("update catalog item: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil || affected == 0 {
		return nil, fmt.Errorf("catalog item %q not found", ctx.PathParam("id"))
	}
	if err := ctx.Redis.Del(ctx, "catalog:item:"+ctx.PathParam("id")).Err(); err != nil {
		ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "invalidate", "result", "error")
		ctx.Warn("catalog cache invalidation failed", "error", err)
	} else {
		ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "invalidate", "result", "success")
	}
	return item{ID: ctx.PathParam("id"), Name: input.Name, Description: input.Description}, nil
}

func deleteItem(ctx *gofr.Context) (any, error) {
	defer ctx.Trace("catalog.delete").End()
	result, err := ctx.SQL.ExecContext(ctx, "DELETE FROM catalog_items WHERE id = ?", ctx.PathParam("id"))
	if err != nil {
		return nil, fmt.Errorf("delete catalog item: %w", err)
	}
	affected, err := result.RowsAffected()
	if err != nil || affected == 0 {
		return nil, fmt.Errorf("catalog item %q not found", ctx.PathParam("id"))
	}
	if err := ctx.Redis.Del(ctx, "catalog:item:"+ctx.PathParam("id")).Err(); err != nil {
		ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "invalidate", "result", "error")
		ctx.Warn("catalog cache invalidation failed", "error", err)
	} else {
		ctx.Metrics().IncrementCounter(ctx, catalogCacheMetric, "operation", "invalidate", "result", "success")
	}
	return map[string]string{"deleted": ctx.PathParam("id")}, nil
}
