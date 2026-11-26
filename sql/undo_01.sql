DROP TABLE shop.reviews, shop.payments, shop.order_items, shop.orders, shop.product_categories, shop.products, shop.categories, shop.brands, shop.user_addresses, shop.delivery_addresses, shop.users, shop.regions;
DROP FUNCTION shop.protect_used_address(), shop.lock_order_address();
DROP SCHEMA shop;
