-- =====================================================================
--  SUPERMART POS  --  05 : SEED DATA  (demo catalogue + settings)
--  Run AFTER 04_rls_policies.sql.  Safe to re-run.
--  Delete this file's data later from  Admin > Settings > Reset demo data.
--
--  >>> CHANGE THE STORE NAME / ADDRESS / PHONE / NTN BELOW to your real ones
--  >>> or simply edit them later in the app: Super Admin > Settings.
-- =====================================================================

begin;  -- one transaction: the whole seed either lands or doesn't

-- ------------------------------ STORE --------------------------------
insert into public.stores (is_default, name, legal_name, address, phone, currency_code, currency_symbol,
                           tax_percent, tax_label, receipt_footer)
select true, 'Supermart Superstore', 'Supermart Superstore (Pvt) Ltd',
       'Main Road, Islamabad, Pakistan', '051-0000000', 'PKR', 'Rs',
       0, 'GST', 'Thank you for shopping with us!  Please come again.'
where not exists (select 1 from public.stores);

-- Categories are filled from Excel import rows or from the app itself. This
-- demo seed intentionally does not create fake default categories.

-- ----------------------------- SUPPLIERS ------------------------------
insert into public.suppliers (name, contact_person, phone, city)
select x.name, x.person, x.phone, x.city from (values
  ('Al-Karam Traders','Imran Khan','0300-1234567','Islamabad'),
  ('Nestle Distributor','Rashid Ali','0301-7654321','Rawalpindi'),
  ('Unilever Distributor','Sajid Mehmood','0333-1122334','Islamabad')
) as x(name, person, phone, city)
where not exists (select 1 from public.suppliers s where s.name = x.name);

-- ------------------------------ PRODUCTS ------------------------------
-- barcode / sku / name / unit / cost / sale / reorder / category / supplier
create temp table _seed_products (
  barcode text, sku text, name text, unit text, cost numeric, price numeric,
  reorder numeric, category text, supplier text, opening numeric
) on commit drop;

insert into _seed_products values
 ('8964000100017','GRC-001','Sunridge Chakki Atta 10kg','bag',1080,1150,5,'Grocery','Al-Karam Traders',40),
 ('8964000100024','GRC-002','Sunridge Chakki Atta 5kg','bag',555,590,8,'Grocery','Al-Karam Traders',50),
 ('8964000100031','GRC-003','Basmati Rice Super Kernel 5kg','bag',1450,1590,5,'Grocery','Al-Karam Traders',30),
 ('8964000100048','GRC-004','Dalda Cooking Oil 5L','bottle',2350,2490,6,'Grocery','Al-Karam Traders',25),
 ('8964000100055','GRC-005','Dalda Cooking Oil 1L','bottle',480,510,12,'Grocery','Al-Karam Traders',60),
 ('8964000100062','GRC-006','Sugar Refined 1kg','kg',135,148,40,'Grocery','Al-Karam Traders',200),
 ('8964000100079','GRC-007','Salt National 800g','pkt',45,55,30,'Grocery','Al-Karam Traders',120),
 ('8964000100086','GRC-008','Red Chilli Powder 200g','pkt',180,199,20,'Grocery','Al-Karam Traders',70),
 ('8964000100093','GRC-009','Turmeric Powder 200g','pkt',160,180,20,'Grocery','Al-Karam Traders',65),
 ('8964000100109','GRC-010','Daal Chana 1kg','kg',290,320,25,'Grocery','Al-Karam Traders',90),
 ('8964000100116','GRC-011','Daal Masoor 1kg','kg',270,299,25,'Grocery','Al-Karam Traders',85),
 ('8964000100123','GRC-012','Tea Tapal Danedar 950g','pkt',1450,1550,10,'Grocery','Al-Karam Traders',35),
 ('8964000200016','BEV-001','Coca Cola 1.5L','bottle',170,200,24,'Beverages','Nestle Distributor',80),
 ('8964000200023','BEV-002','Coca Cola 500ml','bottle',85,100,36,'Beverages','Nestle Distributor',120),
 ('8964000200030','BEV-003','Pepsi 1.5L','bottle',165,195,24,'Beverages','Nestle Distributor',75),
 ('8964000200047','BEV-004','Sprite 1.5L','bottle',165,195,24,'Beverages','Nestle Distributor',60),
 ('8964000200054','BEV-005','Nestle Water 1.5L','bottle',55,70,48,'Beverages','Nestle Distributor',150),
 ('8964000200061','BEV-006','Nestle Juice Orange 1L','pkt',290,330,18,'Beverages','Nestle Distributor',45),
 ('8964000200078','BEV-007','Nescafe Classic 100g','jar',1090,1190,8,'Beverages','Nestle Distributor',24),
 ('8964000200085','BEV-008','Tang Orange 750g','jar',890,970,10,'Beverages','Nestle Distributor',30),
 ('8964000300015','SNK-001','Lays Masala 40g','pkt',45,50,60,'Snacks & Biscuits','Unilever Distributor',300),
 ('8964000300022','SNK-002','Lays Cheese 40g','pkt',45,50,60,'Snacks & Biscuits','Unilever Distributor',260),
 ('8964000300039','SNK-003','Kurkure Chatpata 40g','pkt',40,50,60,'Snacks & Biscuits','Unilever Distributor',280),
 ('8964000300046','SNK-004','Peek Freans Sooper 6-pack','pkt',150,170,30,'Snacks & Biscuits','Unilever Distributor',140),
 ('8964000300053','SNK-005','Oreo Original 66g','pkt',60,70,40,'Snacks & Biscuits','Unilever Distributor',180),
 ('8964000300060','SNK-006','Dairy Milk Chocolate 38g','pkt',130,150,40,'Snacks & Biscuits','Unilever Distributor',160),
 ('8964000300077','SNK-007','Prince Chocolate 50g','pkt',60,70,40,'Snacks & Biscuits','Unilever Distributor',170),
 ('8964000400014','DRY-001','Olpers Milk 1L','pkt',230,250,36,'Dairy & Eggs','Nestle Distributor',140),
 ('8964000400021','DRY-002','Olpers Cream 200ml','pkt',145,160,24,'Dairy & Eggs','Nestle Distributor',90),
 ('8964000400038','DRY-003','Nestle Milkpak 1L','pkt',235,255,36,'Dairy & Eggs','Nestle Distributor',120),
 ('8964000400045','DRY-004','Eggs Desi (dozen)','dozen',290,320,20,'Dairy & Eggs','Al-Karam Traders',60),
 ('8964000400052','DRY-005','Adams Butter 200g','pkt',390,420,15,'Dairy & Eggs','Nestle Distributor',40),
 ('8964000400069','DRY-006','Yogurt Fresh 1kg','pkt',190,210,20,'Dairy & Eggs','Al-Karam Traders',55),
 ('8964000500013','BKY-001','Bake Parlour Bread Large','pcs',130,150,30,'Bakery','Al-Karam Traders',70),
 ('8964000500020','BKY-002','Bake Parlour Bread Small','pcs',90,100,30,'Bakery','Al-Karam Traders',60),
 ('8964000500037','BKY-003','Rusk Sooper 350g','pkt',180,199,20,'Bakery','Unilever Distributor',75),
 ('8964000500044','BKY-004','Cake Slice Chocolate','pcs',60,80,25,'Bakery','Al-Karam Traders',50),
 ('8964000600012','FRZ-001','K&Ns Chicken Nuggets 500g','pkt',690,750,12,'Frozen','Al-Karam Traders',35),
 ('8964000600029','FRZ-002','K&Ns Chicken Kabab 500g','pkt',650,720,12,'Frozen','Al-Karam Traders',30),
 ('8964000600036','FRZ-003','Menu Chicken Samosa 20pcs','pkt',340,380,15,'Frozen','Al-Karam Traders',45),
 ('8964000700011','PRS-001','Head & Shoulders Shampoo 185ml','bottle',560,620,15,'Personal Care','Unilever Distributor',40),
 ('8964000700028','PRS-002','Lifebuoy Soap 100g','pcs',85,100,40,'Personal Care','Unilever Distributor',200),
 ('8964000700035','PRS-003','Colgate Toothpaste 125g','pcs',250,275,20,'Personal Care','Unilever Distributor',90),
 ('8964000700042','PRS-004','Safeguard Soap 110g','pcs',120,140,40,'Personal Care','Unilever Distributor',150),
 ('8964000700059','PRS-005','Dove Shampoo 200ml','bottle',690,760,12,'Personal Care','Unilever Distributor',30),
 ('8964000800010','HOM-001','Surf Excel 1kg','pkt',540,590,20,'Home Care','Unilever Distributor',70),
 ('8964000800027','HOM-002','Vim Dishwash Bar 200g','pcs',95,110,40,'Home Care','Unilever Distributor',160),
 ('8964000800034','HOM-003','Harpic Toilet Cleaner 500ml','bottle',380,420,15,'Home Care','Unilever Distributor',50),
 ('8964000800041','HOM-004','Dettol Antiseptic 250ml','bottle',340,380,15,'Home Care','Unilever Distributor',45),
 ('8964000900019','BAB-001','Pampers Small 20pcs','pkt',780,850,12,'Baby Care','Nestle Distributor',35),
 ('8964000900026','BAB-002','Johnson Baby Powder 100g','pcs',290,320,15,'Baby Care','Nestle Distributor',40),
 ('8964000900033','BAB-003','Cerelac Wheat 350g','box',690,750,10,'Baby Care','Nestle Distributor',28),
 ('8964001000018','STA-001','Dollar Notebook 100pg','pcs',70,90,30,'Stationery','Al-Karam Traders',120),
 ('8964001000025','STA-002','Piano Ball Pen (blue)','pcs',15,20,100,'Stationery','Al-Karam Traders',500),
 ('8964001100017','CIG-001','Marlboro Regular','pkt',390,420,30,'Cigarettes','Al-Karam Traders',90),
 ('8964001100024','CIG-002','Gold Leaf Regular','pkt',180,200,30,'Cigarettes','Al-Karam Traders',100),
 ('8964001200016','FRS-001','Banana (per kg)','kg',150,180,20,'Fresh Produce','Al-Karam Traders',40),
 ('8964001200023','FRS-002','Apple Kala Kulu (per kg)','kg',220,260,20,'Fresh Produce','Al-Karam Traders',45),
 ('8964001200030','FRS-003','Tomato (per kg)','kg',70,95,25,'Fresh Produce','Al-Karam Traders',50),
 ('8964001200047','FRS-004','Potato (per kg)','kg',55,75,40,'Fresh Produce','Al-Karam Traders',80),
 ('8964001200054','FRS-005','Onion (per kg)','kg',60,85,40,'Fresh Produce','Al-Karam Traders',75);

-- insert products only if the barcode is not already there
insert into public.products (barcode, sku, name, unit, cost_price, sale_price, reorder_level,
                             category_id, supplier_id, tax_percent)
select s.barcode, s.sku, s.name, s.unit, s.cost, s.price, s.reorder,
       (select id from public.categories where name = s.category limit 1),
       (select id from public.suppliers  where name = s.supplier limit 1),
       null
  from _seed_products s
 where not exists (select 1 from public.products p where p.barcode = s.barcode);

-- opening stock goes through the inventory ledger so the numbers tie up
insert into public.inventory_movements (product_id, qty_change, movement_type, note)
select p.id, s.opening, 'opening', 'Seed opening stock'
  from _seed_products s
  join public.products p on p.barcode = s.barcode
 where s.opening <> 0
   and not exists (select 1 from public.inventory_movements m
                    where m.product_id = p.id and m.movement_type = 'opening');

-- ------------------------------ CUSTOMERS ----------------------------
insert into public.customers (name, phone, address, credit_limit)
select x.name, x.phone, x.address, x.limit_amt
  from (values
   ('Walk-in Customer', null, null, 0::numeric),
   ('Ahmed Raza','0300-5551111','Street 5, G-11, Islamabad',5000),
   ('Fatima Bibi','0333-4442222','Sector I-8, Islamabad',3000),
   ('Bilal Traders (shop)','0345-9998888','Bara Kahu, Islamabad',20000)
  ) as x(name, phone, address, limit_amt)
 where x.phone is null or not exists (select 1 from public.customers c where c.phone = x.phone);

-- ------------------------------ DISCOUNTS ----------------------------
insert into public.discounts (code, name, kind, value, scope, min_subtotal, requires_manager,
                              applies_automatically, is_active, max_discount)
select 'EID10','Eid Promotion 10%','percent',10,'all',1000,true,false,true,500
where not exists (select 1 from public.discounts where upper(coalesce(code,'')) = 'EID10');

insert into public.discounts (code, name, kind, value, scope, min_subtotal, applies_automatically,
                              is_active, max_discount, max_uses)
select 'WELCOME50','Welcome Rs 50 off','amount',50,'all',500,false,true,50,100
where not exists (select 1 from public.discounts where upper(coalesce(code,'')) = 'WELCOME50');

insert into public.discounts (code, name, kind, value, scope, min_subtotal, applies_automatically,
                              is_active, max_discount)
select null,'Happy Hour 3% over Rs 2000','percent',3,'all',2000,true,true,1000
where not exists (select 1 from public.discounts where name = 'Happy Hour 3% over Rs 2000');

-- ---------------------------- APP SETTINGS ---------------------------
insert into public.app_settings(key, value) values
  ('pos', '{"receipt_copies":1,"auto_print":true,"barcode_beep":true,"quick_cash":[100,500,1000,5000]}'::jsonb),
  ('low_stock_alert', '{"enabled":true,"notify_managers":true}'::jsonb)
on conflict (key) do nothing;

commit;

-- =====================================================================
--  SUPER ADMIN LOGIN
--  The seed cannot create a login (that is Supabase Auth's job), so:
--    1. Supabase Dashboard > Authentication > Users > Add user
--         email:    admin@supermart.local
--         password: (choose a strong one)
--         tick "Auto Confirm User"
--    2. then run the statement below once with that user's id.
--    3. sign in with that email on PC 1, then create the other 3 users
--       from  Admin > Employees  inside the app.
-- =====================================================================
-- update public.profiles
--    set role = 'super_admin', full_name = 'Store Owner', username = 'owner'
--  where email = 'admin@supermart.local';
