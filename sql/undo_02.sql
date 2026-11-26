DROP TRIGGER order_items_refresh ON shop.order_items;
DROP TRIGGER order_items_lock ON shop.order_items;
DROP TRIGGER orders_derive_fields ON shop.orders;
DROP FUNCTION shop.refresh_item_orders(), shop.lock_item_orders(), shop.derive_order_fields();
DROP INDEX shop.orders_region_date_idx;
ALTER TABLE shop.orders DROP COLUMN delivery_region_id, DROP COLUMN total_amount;
ALTER TABLE shop.order_items DROP COLUMN line_total;
