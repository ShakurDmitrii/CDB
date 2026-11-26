-- PostgreSQL 18. Normalized logical model: exactly 12 tables.
-- Execute in a dedicated, empty lab database. Never drops existing objects.
CREATE SCHEMA shop;
SET LOCAL search_path = shop, public;

CREATE TABLE regions (
    region_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code varchar(16) NOT NULL UNIQUE,
    name varchar(120) NOT NULL,
    CHECK (btrim(code) <> ''), CHECK (btrim(name) <> '')
);
CREATE TABLE users (
    user_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email varchar(254) NOT NULL UNIQUE,
    password_hash text NOT NULL,
    full_name varchar(160) NOT NULL,
    phone varchar(20),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (email = lower(email) AND position('@' IN email) > 1),
    CHECK (length(password_hash) >= 20),
    CHECK (btrim(full_name) <> ''),
    CHECK (phone IS NULL OR phone ~ '^\+[1-9][0-9]{7,14}$')
);
-- Addresses are physical delivery locations, not exclusively owned by a user.
-- Several users can save the same address through user_addresses.
CREATE TABLE delivery_addresses (
    address_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_id bigint NOT NULL REFERENCES regions ON DELETE RESTRICT,
    postal_code varchar(12) NOT NULL,
    city varchar(120) NOT NULL,
    street varchar(160) NOT NULL,
    house varchar(32) NOT NULL,
    apartment varchar(32),
    CHECK (btrim(postal_code) <> ''), CHECK (btrim(city) <> ''),
    CHECK (btrim(street) <> ''), CHECK (btrim(house) <> '')
);
CREATE TABLE user_addresses (
    user_id bigint NOT NULL REFERENCES users ON DELETE CASCADE,
    address_id bigint NOT NULL REFERENCES delivery_addresses ON DELETE RESTRICT,
    label varchar(80),
    is_default boolean NOT NULL DEFAULT false,
    PRIMARY KEY (user_id, address_id)
);
CREATE UNIQUE INDEX user_addresses_one_default
    ON user_addresses (user_id) WHERE is_default;
CREATE INDEX user_addresses_address_idx ON user_addresses (address_id);
CREATE INDEX delivery_addresses_region_idx ON delivery_addresses (region_id);

CREATE TABLE brands (
    brand_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(120) NOT NULL UNIQUE,
    CHECK (btrim(name) <> '')
);
CREATE TABLE categories (
    category_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name varchar(120) NOT NULL UNIQUE,
    CHECK (btrim(name) <> '')
);
CREATE TABLE products (
    product_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku varchar(64) NOT NULL UNIQUE,
    brand_id bigint NOT NULL REFERENCES brands ON DELETE RESTRICT,
    name varchar(200) NOT NULL,
    description text,
    current_price numeric(12,2) NOT NULL CHECK (current_price >= 0),
    stock integer NOT NULL DEFAULT 0 CHECK (stock >= 0),
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (btrim(sku) <> ''), CHECK (btrim(name) <> '')
);
CREATE INDEX products_brand_idx ON products (brand_id);
CREATE TABLE product_categories (
    product_id bigint NOT NULL REFERENCES products ON DELETE CASCADE,
    category_id bigint NOT NULL REFERENCES categories ON DELETE RESTRICT,
    PRIMARY KEY (product_id, category_id)
);
CREATE INDEX product_categories_category_idx
    ON product_categories (category_id, product_id);

CREATE TABLE orders (
    order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users ON DELETE RESTRICT,
    delivery_address_id bigint NOT NULL,
    recipient_name varchar(160) NOT NULL,
    recipient_phone varchar(20) NOT NULL,
    status varchar(16) NOT NULL DEFAULT 'new'
        CHECK (status IN ('new','paid','shipped','completed','cancelled')),
    sales_channel varchar(16) NOT NULL
        CHECK (sales_channel IN ('website','mobile','marketplace')),
    ordered_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id, delivery_address_id)
        REFERENCES user_addresses (user_id, address_id) ON DELETE RESTRICT,
    CHECK (btrim(recipient_name) <> ''),
    CHECK (recipient_phone ~ '^\+[1-9][0-9]{7,14}$')
);
CREATE INDEX orders_user_date_idx ON orders (user_id, ordered_at DESC);
CREATE INDEX orders_address_idx ON orders (delivery_address_id);
CREATE INDEX orders_date_idx ON orders (ordered_at);
CREATE TABLE order_items (
    order_id bigint NOT NULL REFERENCES orders ON DELETE CASCADE,
    line_no smallint NOT NULL CHECK (line_no > 0),
    product_id bigint NOT NULL REFERENCES products ON DELETE RESTRICT,
    quantity integer NOT NULL CHECK (quantity > 0),
    -- Historical contractual price, independent of the current catalog price.
    unit_price numeric(12,2) NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, line_no),
    UNIQUE (order_id, product_id)
);
CREATE INDEX order_items_product_idx ON order_items (product_id);
CREATE TABLE payments (
    payment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id bigint NOT NULL REFERENCES orders ON DELETE RESTRICT,
    provider varchar(40) NOT NULL,
    provider_payment_id varchar(120) NOT NULL,
    amount numeric(14,2) NOT NULL CHECK (amount > 0),
    status varchar(16) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','succeeded','failed','refunded')),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    paid_at timestamptz,
    UNIQUE (provider, provider_payment_id),
    CHECK (status NOT IN ('succeeded','refunded') OR paid_at IS NOT NULL)
);
CREATE INDEX payments_order_idx ON payments (order_id);
CREATE TABLE reviews (
    review_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id bigint NOT NULL REFERENCES users ON DELETE RESTRICT,
    product_id bigint NOT NULL REFERENCES products ON DELETE RESTRICT,
    rating smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
    body text NOT NULL CHECK (btrim(body) <> ''),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (user_id, product_id)
);
CREATE INDEX reviews_product_date_idx ON reviews (product_id, created_at DESC);

-- Historical addresses cannot be edited once referenced by an order.
-- Edit an address by creating a new row and a new user_addresses link.
CREATE FUNCTION shop.protect_used_address() RETURNS trigger LANGUAGE plpgsql
SET search_path = shop, pg_temp AS $$
BEGIN
    IF ROW(NEW.region_id,NEW.postal_code,NEW.city,NEW.street,NEW.house,NEW.apartment)
       IS DISTINCT FROM
       ROW(OLD.region_id,OLD.postal_code,OLD.city,OLD.street,OLD.house,OLD.apartment)
       AND EXISTS (SELECT 1 FROM orders WHERE delivery_address_id=OLD.address_id)
    THEN RAISE EXCEPTION 'Address used in an order is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER delivery_addresses_history_guard
BEFORE UPDATE ON delivery_addresses FOR EACH ROW
EXECUTE FUNCTION shop.protect_used_address();
-- Lock the chosen address to serialize concurrent address edits/order writes.
CREATE FUNCTION shop.lock_order_address() RETURNS trigger LANGUAGE plpgsql
SET search_path = shop, pg_temp AS $$
BEGIN
    PERFORM 1 FROM delivery_addresses WHERE address_id=NEW.delivery_address_id FOR SHARE;
    RETURN NEW;
END $$;
CREATE TRIGGER orders_address_lock BEFORE INSERT OR UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION shop.lock_order_address();
