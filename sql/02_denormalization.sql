-- Three explicit physical optimizations AFTER the 3NF baseline.
SET LOCAL search_path = shop, public;
-- D1: stored derived line amount; PostgreSQL recomputes it automatically.
ALTER TABLE order_items ADD COLUMN line_total numeric(22,2)
    GENERATED ALWAYS AS (quantity::numeric * unit_price) STORED NOT NULL;
-- D2: materialized order total; canonical value remains SUM(order_items).
ALTER TABLE orders ADD COLUMN total_amount numeric(24,2) NOT NULL DEFAULT 0
    CHECK (total_amount >= 0);
-- D3: regional routing/reporting key, copied from the canonical address.
ALTER TABLE orders ADD COLUMN delivery_region_id bigint REFERENCES regions;
UPDATE orders o SET delivery_region_id=a.region_id
FROM delivery_addresses a WHERE a.address_id=o.delivery_address_id;
ALTER TABLE orders ALTER COLUMN delivery_region_id SET NOT NULL;
CREATE INDEX orders_region_date_idx ON orders (delivery_region_id, ordered_at DESC);

CREATE FUNCTION shop.derive_order_fields() RETURNS trigger LANGUAGE plpgsql
SET search_path = shop, pg_temp AS $$
BEGIN
    SELECT region_id INTO NEW.delivery_region_id
    FROM delivery_addresses WHERE address_id=NEW.delivery_address_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown delivery address %', NEW.delivery_address_id USING ERRCODE='23503';
    END IF;
    IF TG_OP='INSERT' THEN NEW.total_amount:=0;
    ELSE
        SELECT COALESCE(sum(line_total),0) INTO NEW.total_amount
        FROM order_items WHERE order_id=NEW.order_id;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER orders_derive_fields BEFORE INSERT OR UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION shop.derive_order_fields();

-- Lock order headers BEFORE item changes, so concurrent sessions serialize.
-- For a move between orders, lock both headers in increasing ID order.
CREATE FUNCTION shop.lock_item_orders() RETURNS trigger LANGUAGE plpgsql
SET search_path = shop, pg_temp AS $$
DECLARE ids bigint[] := ARRAY[]::bigint[];
BEGIN
    IF TG_OP <> 'INSERT' THEN ids:=array_append(ids,OLD.order_id); END IF;
    IF TG_OP <> 'DELETE' THEN ids:=array_append(ids,NEW.order_id); END IF;
    PERFORM 1 FROM orders WHERE order_id=ANY(ids) ORDER BY order_id FOR UPDATE;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE FUNCTION shop.refresh_item_orders() RETURNS trigger LANGUAGE plpgsql
SET search_path = shop, pg_temp AS $$
DECLARE ids bigint[] := ARRAY[]::bigint[]; v_id bigint;
BEGIN
    IF TG_OP <> 'INSERT' THEN ids:=array_append(ids,OLD.order_id); END IF;
    IF TG_OP <> 'DELETE' THEN ids:=array_append(ids,NEW.order_id); END IF;
    FOR v_id IN SELECT DISTINCT unnest(ids) ORDER BY 1 LOOP
        -- The BEFORE trigger recomputes the canonical sum and region.
        UPDATE orders SET total_amount=total_amount WHERE order_id=v_id;
    END LOOP;
    RETURN NULL;
END $$;
CREATE TRIGGER order_items_lock BEFORE INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION shop.lock_item_orders();
CREATE TRIGGER order_items_refresh AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW EXECUTE FUNCTION shop.refresh_item_orders();
-- Also initialize caches when applying the migration to non-empty tables.
UPDATE orders SET total_amount=total_amount;
