SELECT
  (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'shop') AS tables,
  (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'shop'
    AND column_name IN ('line_total', 'total_amount', 'delivery_region_id')) AS added_columns,
  (SELECT count(*) FROM public.databasechangelog) AS changesets;
