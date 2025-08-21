-- =================================================================
-- LENS DISPATCH SYSTEM - FINAL PRODUCTION SCHEMA V3
-- This schema combines the best features of all previous versions.
-- It is designed for robustness, automation, and scalability.
-- =================================================================

-- To ensure a clean setup, drop existing objects in reverse dependency order.
DROP TABLE IF EXISTS public.shipment_items;
DROP TABLE IF EXISTS public.shipments;
DROP TABLE IF EXISTS public.label_logs;
DROP TABLE IF EXISTS public.activity_logs;
DROP TABLE IF EXISTS public.delivery_confirmations;
DROP TABLE IF EXISTS public.returns;
DROP TABLE IF EXISTS public.orders;
DROP TABLE IF EXISTS public.boxes;
DROP TABLE IF EXISTS public.stores;
DROP TABLE IF EXISTS public.delivery_groups;
DROP TABLE IF EXISTS public.couriers;
DROP TABLE IF EXISTS public.users;

-- Drop custom ENUM types if they exist to prevent conflicts.
DROP TYPE IF EXISTS public.box_status;
DROP TYPE IF EXISTS public.order_status;
DROP TYPE IF EXISTS public.shipment_status;
DROP TYPE IF EXISTS public.delivery_status;

-- =================================================================
-- 1. CUSTOM TYPES (ENUMs)
-- Defines controlled vocabularies for status fields to power UI dropdowns.
-- =================================================================

CREATE TYPE public.box_status AS ENUM ('Pending', 'Packing', 'Packed');
CREATE TYPE public.order_status AS ENUM ('Pending', 'Packed', 'Returned');
CREATE TYPE public.shipment_status AS ENUM ('Created', 'Dispatched', 'In Transit', 'Delivered', 'Issue Reported');
CREATE TYPE public.delivery_status AS ENUM ('Received', 'Issue Reported');

-- =================================================================
-- 2. HELPER FUNCTIONS & TRIGGERS
-- Automates key processes like timestamp updates and delivery grouping.
-- =================================================================

-- Utility function to automatically update 'updated_at' timestamps.
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- This function finds or creates a delivery_group and assigns its ID.
CREATE OR REPLACE FUNCTION public.assign_delivery_group()
RETURNS TRIGGER AS $$
DECLARE
    v_group_id BIGINT;
    v_address_hash TEXT;
BEGIN
    -- Create a consistent hash from the address and pincode to identify the group.
    v_address_hash := md5(lower(trim(NEW.address)) || trim(COALESCE(NEW.pincode, 'NO-PIN')));

    -- Look for an existing delivery group with the same address hash.
    SELECT id INTO v_group_id FROM public.delivery_groups WHERE address_hash = v_address_hash;

    -- If no group is found, create a new one.
    IF v_group_id IS NULL THEN
        INSERT INTO public.delivery_groups (address_hash, full_address, city, pincode)
        VALUES (v_address_hash, NEW.address, NEW.city, NEW.pincode)
        RETURNING id INTO v_group_id;
    END IF;

    -- Assign the found or newly created group ID to the store record.
    NEW.delivery_group_id := v_group_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =================================================================
-- 3. TABLE DEFINITIONS
-- =================================================================

-- 👤 USERS: Manages system operators. Links to Supabase auth.
CREATE TABLE public.users (
    id UUID PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    full_name TEXT,
    role TEXT NOT NULL DEFAULT 'packer',
    CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE
);
CREATE TRIGGER on_users_update BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION handle_updated_at();

-- 🚚 COURIERS: Stores information about courier services.
CREATE TABLE public.couriers (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    name TEXT UNIQUE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 📍 DELIVERY_GROUPS: A master table of unique physical delivery locations.
CREATE TABLE public.delivery_groups (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    address_hash TEXT UNIQUE NOT NULL, -- MD5 hash for quick lookups
    full_address TEXT NOT NULL,
    city TEXT,
    pincode TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 🏬 STORES: The master address book for all destination stores.
CREATE TABLE public.stores (
    store_code TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    store_name TEXT NOT NULL,
    address TEXT NOT NULL,
    city TEXT NOT NULL,
    state TEXT,
    pincode TEXT,
    mobile TEXT,
    courier_id BIGINT REFERENCES public.couriers(id),
    delivery_group_id BIGINT REFERENCES public.delivery_groups(id),
    updated_by UUID REFERENCES public.users(id)
);
CREATE TRIGGER on_stores_update BEFORE UPDATE ON public.stores FOR EACH ROW EXECUTE FUNCTION handle_updated_at();
-- This is the trigger that automates the delivery grouping.
CREATE TRIGGER set_delivery_group_on_store_change
BEFORE INSERT OR UPDATE OF address, pincode ON public.stores
FOR EACH ROW EXECUTE FUNCTION assign_delivery_group();
CREATE INDEX ON public.stores(courier_id);
CREATE INDEX ON public.stores(delivery_group_id);

-- 📦 BOXES: Represents a physical dispatch box.
CREATE TABLE public.boxes (
    box_id TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    dispatch_date DATE NOT NULL DEFAULT CURRENT_DATE,
    delivery_group_id BIGINT NOT NULL REFERENCES public.delivery_groups(id),
    status public.box_status NOT NULL DEFAULT 'Pending',
    updated_by UUID REFERENCES public.users(id)
);
CREATE TRIGGER on_boxes_update BEFORE UPDATE ON public.boxes FOR EACH ROW EXECUTE FUNCTION handle_updated_at();
CREATE INDEX ON public.boxes(delivery_group_id);
CREATE INDEX ON public.boxes(dispatch_date);

-- 👁️ ORDERS: Contains individual lens order details.
CREATE TABLE public.orders (
    gkb_order_no TEXT PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    customer_ref TEXT,
    store_code TEXT NOT NULL REFERENCES public.stores(store_code),
    box_id TEXT NOT NULL REFERENCES public.boxes(box_id),
    status public.order_status NOT NULL DEFAULT 'Pending',
    order_date DATE NOT NULL,
    updated_by UUID REFERENCES public.users(id)
);
CREATE TRIGGER on_orders_update BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION handle_updated_at();
CREATE INDEX ON public.orders(store_code);
CREATE INDEX ON public.orders(box_id);

-- ✈️ SHIPMENTS: Tracks a courier shipment, which can contain multiple boxes.
CREATE TABLE public.shipments (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    docket_number TEXT UNIQUE NOT NULL,
    courier_id BIGINT NOT NULL REFERENCES public.couriers(id),
    shipment_date DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    status public.shipment_status NOT NULL DEFAULT 'Created'
);
CREATE INDEX ON public.shipments(courier_id);

-- 🔗 SHIPMENT_ITEMS: Links boxes to a specific shipment.
CREATE TABLE public.shipment_items (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    shipment_id BIGINT NOT NULL REFERENCES public.shipments(id),
    box_id TEXT NOT NULL REFERENCES public.boxes(box_id)
);
CREATE INDEX ON public.shipment_items(shipment_id);
CREATE INDEX ON public.shipment_items(box_id);

-- Other tables remain for logging and confirmation
CREATE TABLE public.returns ( id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), gkb_order_no TEXT NOT NULL REFERENCES public.orders(gkb_order_no), reason TEXT NOT NULL, returned_by_user_id UUID NOT NULL REFERENCES public.users(id) );
CREATE TABLE public.delivery_confirmations ( id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), shipment_id BIGINT NOT NULL REFERENCES public.shipments(id), confirmed_by_name TEXT, status public.delivery_status NOT NULL, notes TEXT );
CREATE TABLE public.activity_logs ( id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), user_id UUID REFERENCES public.users(id), action TEXT NOT NULL, details JSONB );
CREATE TABLE public.label_logs ( id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), box_id TEXT NOT NULL REFERENCES public.boxes(box_id), generated_by_user_id UUID NOT NULL REFERENCES public.users(id), label_details JSONB );

-- =================================================================
-- END OF SCHEMA
-- =================================================================
