batch_update_order_amounts
declare
  item jsonb;
  v_order_number text;
  v_org_id uuid;
  v_amount numeric(10,2);
begin
  -- Loop through each item in the input array
  for item in select * from jsonb_array_elements(orders)
  loop
    v_order_number := item->>'order_number';
    v_org_id := (item->>'organization_id')::uuid;
    v_amount := (item->>'amount')::numeric;

    update orders o
    set 
      total_amount = v_amount,
      outstanding_balance = v_amount,
      updated_at = now()
    where o.order_number = v_order_number and o.organization_id = v_org_id;
  end loop;
end;

---------------------------------
calculate_item_total_price
BEGIN
    NEW.total_price := NEW.quantity * NEW.unit_price;
    RETURN NEW;
END;
---------------------------------

create_order
DECLARE
    v_order orders;
    v_worker JSONB;
    v_service JSONB;
    v_custom_field JSONB;
    v_order_number TEXT;
    v_next_seq INT;
    v_attempts INTEGER := 0;
    v_max_attempts INTEGER := 10;
    v_current_year TEXT;
BEGIN
    -- Get the current year (e.g., 2025 -> '25')
    v_current_year := TO_CHAR(CURRENT_DATE, 'YYMM');

    -- Generate order number with retry logic
    LOOP
         -- Find the last inserted order number and lock the row
        SELECT CAST(SUBSTRING(order_number FROM 10) AS INTEGER) 
        INTO v_next_seq
        FROM orders
        WHERE organization_id = p_organization_id
        AND order_number LIKE 'ORD-' || v_current_year || '%'
        ORDER BY CAST(SUBSTRING(order_number FROM 10) AS INTEGER) DESC
        LIMIT 1
        FOR UPDATE SKIP LOCKED;

        -- If no previous order exists, start from 1
        v_next_seq := COALESCE(v_next_seq, 0) + 1;

        -- Generate the new order number
        v_order_number := 'ORD-' || v_current_year || '-' || v_next_seq;

        -- Try to insert the order
        BEGIN
            INSERT INTO orders (
                organization_id,
                order_number,
                client_id,
                description,
                due_date,
                status,
                total_amount,
                outstanding_balance,
                payment_status
            ) VALUES (
                p_organization_id,
                v_order_number,
                p_client_id,
                p_description,
                p_due_date,
                'pending',
                p_total_amount,
                p_total_amount,
                'unpaid'
            ) RETURNING * INTO v_order;
            EXIT; -- Success, exit the loop
        EXCEPTION WHEN unique_violation THEN
            v_attempts := v_attempts + 1;
            IF v_attempts >= v_max_attempts THEN
                RAISE EXCEPTION 'Failed to generate unique order number after % attempts', v_order_number;
            END IF;
            -- Wait a bit before retrying
            PERFORM pg_sleep(0.1);
        END;
    END LOOP;

    -- Insert order workers
    FOR v_worker IN SELECT * FROM jsonb_array_elements(p_workers)
    LOOP
        INSERT INTO order_workers (
            order_id,
            worker_id,
            project_id,
            status
        ) VALUES (
            v_order.id,
            (v_worker->>'worker_id')::UUID,
            (v_worker->>'project_id')::UUID,
            'assigned'
        );
    END LOOP;

    -- Insert order services
    FOR v_service IN SELECT * FROM jsonb_array_elements(p_services)
    LOOP
        INSERT INTO order_services (
            order_id,
            service_id,
            quantity,
            cost
        ) VALUES (
            v_order.id,
            (v_service->>'service_id')::UUID,
            (v_service->>'quantity')::INTEGER,
            (v_service->>'cost')::DECIMAL(10,2)
        );
    END LOOP;

    -- Insert order custom fields only if they exist and have valid IDs
    IF p_custom_fields IS NOT NULL AND jsonb_array_length(p_custom_fields) > 0 THEN
        FOR v_custom_field IN SELECT * FROM jsonb_array_elements(p_custom_fields)
        LOOP
            IF v_custom_field->>'id' IS NOT NULL THEN
                INSERT INTO order_custom_fields (
                    order_id,
                    custom_field_id,
                    value
                ) VALUES (
                    v_order.id,
                    (v_custom_field->>'id')::UUID,
                    v_custom_field->>'value'
                );
            END IF;
        END LOOP;
    END IF;

    RETURN v_order;
END;


---------------------------------

create_tasks_for_order_workers
DECLARE
  v_organization_id uuid;
  v_price numeric;
  v_order_number text;
BEGIN
  -- Get organization ID and order number first
  SELECT o.organization_id, o.order_number INTO v_organization_id, v_order_number
  FROM orders o
  WHERE o.id = NEW.order_id;

  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION 'Order not found or missing organization_id';
  END IF;

  -- Get the project price from worker_projects table
  SELECT price INTO v_price
  FROM worker_projects
  WHERE worker_id = NEW.worker_id 
    AND id = NEW.project_id 
    AND status = 'active';

  -- If no price found, use 0 as default
  IF v_price IS NULL THEN
    v_price := 0;
    RAISE NOTICE 'No price found for worker % and project %. Using default price of 0', NEW.worker_id, NEW.project_id;
  END IF;

  -- Create a task for the worker
  INSERT INTO tasks (
    organization_id,
    worker_id,
    project_id,
    description,
    due_date,
    status,
    status_changed_at,
    amount,
    order_id
  )
  SELECT
    v_organization_id,
    NEW.worker_id,
    NEW.project_id,
    CASE 
      WHEN o.description IS NOT NULL AND o.description != '' 
      THEN 'Order ' || o.order_number || ': ' || o.description
      ELSE 'Order ' || o.order_number
    END,
    COALESCE(o.due_date, CURRENT_DATE),
    'pending',
    now(),
    v_price,
    NEW.order_id
  FROM orders o
  WHERE o.id = NEW.order_id;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION 'Failed to create task for order % (worker: %, project: %): %', 
      v_order_number, NEW.worker_id, NEW.project_id, SQLERRM;
END;


----------------------------------------
generate_order_number
BEGIN
    NEW.order_number := 'ORD-' || to_char(NOW(), 'YYMMDD') || '-' || 
                       LPAD(COALESCE(
                           (SELECT COUNT(*) + 1 FROM orders 
                            WHERE organization_id = NEW.organization_id 
                            AND DATE(created_at) = CURRENT_DATE)::text,
                           '1'
                       ), 4, '0');
    RETURN NEW;
END;

----------------------------------------
generate_sales_order_number
DECLARE
    org_prefix TEXT;
    current_ym TEXT;
    next_number INTEGER;
    sequence_name TEXT;
    org_exists BOOLEAN;
BEGIN
    -- Validate organization exists
    SELECT EXISTS (
        SELECT 1 FROM organizations WHERE id = NEW.organization_id
    ) INTO org_exists;

    IF NOT org_exists THEN
        RAISE EXCEPTION 'Organization not found';
    END IF;

    -- Get organization name prefix
    SELECT COALESCE(
        (SELECT string_agg(LEFT(word, 1), '')
        FROM (
            SELECT regexp_split_to_table(UPPER(name), '\s+') as word
            FROM organizations
            WHERE id = NEW.organization_id
        ) words),
        'SO'
    ) INTO org_prefix;

    -- Get current year and month
    current_ym := to_char(NEW.created_at, 'YYYYMM');
    
    -- Create sequence name (include organization_id and year-month)
    sequence_name := 'sales_order_seq_' || NEW.organization_id || '_' || current_ym;
    
    -- Create sequence if needed
    EXECUTE format('
        CREATE SEQUENCE IF NOT EXISTS %I 
        START WITH 1001 
        INCREMENT BY 1 
        NO MINVALUE 
        NO MAXVALUE 
        CACHE 1', 
        sequence_name
    );
    
    -- Get next number with retry logic
    BEGIN
        EXECUTE format('SELECT nextval(%L)', sequence_name) INTO next_number;
    EXCEPTION WHEN OTHERS THEN
        -- If sequence doesn't exist, create it and try again
        EXECUTE format('
            CREATE SEQUENCE IF NOT EXISTS %I 
            START WITH 1001 
            INCREMENT BY 1 
            NO MINVALUE 
            NO MAXVALUE 
            CACHE 1', 
            sequence_name
        );
        EXECUTE format('SELECT nextval(%L)', sequence_name) INTO next_number;
    END;

    -- Set order number with format: ORG-PREFIX-YYYYMM-XXXX
    NEW.order_number := org_prefix || '-' || current_ym || '-' || LPAD(next_number::TEXT, 4, '0');
    
    RETURN NEW;
EXCEPTION
    WHEN OTHERS THEN
        -- Log error and raise exception
        RAISE EXCEPTION 'Error generating sales order number: %', SQLERRM;
END;



----------------------------------------
handle_new_user

BEGIN
    -- Insert the new user into public.users
    INSERT INTO public.users (id, auth_id, email, name, created_at)
    VALUES (
        gen_random_uuid(), -- Generate a new UUID for the public user
        NEW.id,           -- Store the auth.users id as auth_id
        NEW.email,        -- Copy the email from auth.users
        COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email), -- Try to get name from metadata, fallback to email
        NEW.created_at    -- Use the same creation timestamp
    )
    -- Handle case where user might already exist
    ON CONFLICT (auth_id) DO UPDATE SET
        email = EXCLUDED.email,
        name = COALESCE(EXCLUDED.name, users.name);

    RETURN NEW;
END;

----------------------------------------

record_payment

DECLARE
    v_payment_id INTEGER;
    v_payment JSONB;
    v_is_sales_order BOOLEAN;
    v_order_exists BOOLEAN;
BEGIN
    -- Validate inputs
    IF p_order_id IS NULL THEN
        RAISE EXCEPTION 'order_id cannot be null';
    END IF;
    
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'amount must be greater than 0';
    END IF;
    
    IF p_payment_method IS NULL THEN
        RAISE EXCEPTION 'payment_method cannot be null';
    END IF;
    
    IF p_recorded_by IS NULL THEN
        RAISE EXCEPTION 'recorded_by cannot be null';
    END IF;

    -- Check if order exists in either table
    SELECT EXISTS (
        SELECT 1 FROM sales_orders WHERE id = p_order_id
        UNION
        SELECT 1 FROM orders WHERE id = p_order_id
    ) INTO v_order_exists;

    IF NOT v_order_exists THEN
        RAISE EXCEPTION 'Order not found';
    END IF;

    -- Check if this is a sales order or a regular order
    SELECT EXISTS (
        SELECT 1 FROM sales_orders WHERE id = p_order_id
    ) INTO v_is_sales_order;

    -- Insert payment record
    INSERT INTO payments (
        reference_id,
        reference_type,
        organization_id,
        amount,
        payment_method,
        transaction_reference,
        recorded_by
    )
    VALUES (
        p_order_id,
        CASE WHEN v_is_sales_order THEN 'sales_order' ELSE 'service_order' END,
        p_organization_id,
        p_amount,
        p_payment_method,
        p_payment_reference,
        p_recorded_by
    )
    RETURNING id INTO v_payment_id;

    -- Update outstanding balance based on order type
    IF v_is_sales_order THEN
        UPDATE sales_orders
        SET 
            outstanding_balance = GREATEST(0, outstanding_balance - p_amount),
            payment_status = CASE 
                WHEN outstanding_balance - p_amount <= 0 THEN 'paid'
                ELSE 'partially_paid'
            END
        WHERE id = p_order_id;
    ELSE
        UPDATE orders
        SET 
            outstanding_balance = GREATEST(0, outstanding_balance - p_amount),
            payment_status = CASE 
                WHEN outstanding_balance - p_amount <= 0 THEN 'paid'
                ELSE 'partially_paid'
            END
        WHERE id = p_order_id;
    END IF;

    -- Get payment details
    SELECT jsonb_build_object(
        'id', p.id,
        'reference_id', p.reference_id,
        'reference_type', p.reference_type,
        'organization_id', p.organization_id,
        'amount', p.amount,
        'payment_method', p.payment_method,
        'transaction_reference', p.transaction_reference,
        'recorded_by', p.recorded_by,
        'created_at', p.created_at
    ) INTO v_payment
    FROM payments p
    WHERE p.id = v_payment_id;

    RETURN v_payment;
EXCEPTION
    WHEN OTHERS THEN
        -- Rollback any changes if there's an error
        RAISE EXCEPTION 'Error recording payment: %', SQLERRM;
END;

----------------------------------------
update_product_stock
BEGIN
    UPDATE products
    SET stock_quantity = NEW.new_quantity,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = NEW.product_id;
    RETURN NEW;
END;

----------------------------------------

update_sales_order_totals
DECLARE
    v_total numeric(10,2);
    v_payments numeric(10,2);
    v_outstanding numeric(10,2);
BEGIN
    -- Calculate total amount from items
    SELECT COALESCE(SUM(total_price), 0)
    INTO v_total
    FROM sales_order_items
    WHERE sales_order_id = NEW.sales_order_id;

    -- Calculate total payments
    SELECT COALESCE(SUM(amount), 0)
    INTO v_payments
    FROM payments
    WHERE sales_order_id = NEW.sales_order_id;

    -- Calculate outstanding balance
    v_outstanding := v_total - v_payments;

    -- Update sales order
    UPDATE sales_orders
    SET total_amount = v_total,
        outstanding_balance = v_outstanding,
        payment_status = CASE 
            WHEN v_outstanding <= 0 THEN 'paid'
            WHEN v_payments > 0 THEN 'partially_paid'
            ELSE 'unpaid'
        END,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = NEW.sales_order_id;

    RETURN NEW;
END;

----------------------------------------
update_updated_at_column
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;












