import gleam/option
import otel/attribute
import otel/trace

type Order {
  Order(id: String, sku: String, quantity: Int, total_cents: Int)
}

type CheckoutError {
  InventoryUnavailable
  PaymentDeclined
}

fn application_marker() -> Nil {
  Nil
}

pub fn main() -> Nil {
  let assert Ok(tracer) = trace.tracer_for(application_marker)
  let order =
    Order(
      id: "order-123",
      sku: "coffee-beans-1kg",
      quantity: 2,
      total_cents: 4200,
    )
  let assert Ok(_) = checkout(tracer:, order:)
  Nil
}

fn checkout(
  tracer tracer: trace.Tracer,
  order order: Order,
) -> Result(String, CheckoutError) {
  let Order(order_id, sku, quantity, total_cents) = order
  let assert Ok(span_name) = trace.span_name("checkout")
  let assert Ok(order_id_key) = attribute.key("app.order.id")
  let options =
    trace.options(trace.Internal)
    |> trace.attributes([attribute.string(order_id_key, order_id)])

  use checkout_span <- trace.with_span(
    tracer,
    span_name,
    trace.Current,
    options,
  )

  case reserve_inventory(tracer:, sku:, quantity:) {
    False -> {
      trace.set_status(
        checkout_span,
        trace.StatusError(option.Some("inventory_unavailable")),
      )
      Error(InventoryUnavailable)
    }
    True ->
      case authorize_payment(tracer:, order_id:, total_cents:) {
        Error(error) -> {
          trace.set_status(
            checkout_span,
            trace.StatusError(option.Some("payment_declined")),
          )
          Error(error)
        }
        Ok(payment_id) -> {
          publish_confirmation(tracer:, order_id:, payment_id:)
          trace.add_event(checkout_span, "checkout.completed", [])
          trace.set_status(checkout_span, trace.StatusOk)
          Ok(payment_id)
        }
      }
  }
}

fn reserve_inventory(
  tracer tracer: trace.Tracer,
  sku sku: String,
  quantity quantity: Int,
) -> Bool {
  let assert Ok(span_name) = trace.span_name("inventory.reserve")
  let assert Ok(sku_key) = attribute.key("app.product.sku")
  let assert Ok(quantity_key) = attribute.key("app.product.quantity")
  let options =
    trace.options(trace.Client)
    |> trace.attributes([
      attribute.string(sku_key, sku),
      attribute.int(quantity_key, quantity),
    ])

  use span <- trace.with_span(tracer, span_name, trace.Current, options)

  case quantity > 0 {
    True -> {
      trace.add_event(span, "inventory.reserved", [])
      trace.set_status(span, trace.StatusOk)
      True
    }
    False -> {
      trace.set_status(span, trace.StatusError(option.Some("invalid_quantity")))
      False
    }
  }
}

fn authorize_payment(
  tracer tracer: trace.Tracer,
  order_id order_id: String,
  total_cents total_cents: Int,
) -> Result(String, CheckoutError) {
  let assert Ok(span_name) = trace.span_name("payment.authorize")
  let assert Ok(order_id_key) = attribute.key("app.order.id")
  let assert Ok(amount_key) = attribute.key("app.payment.amount_cents")
  let options =
    trace.options(trace.Client)
    |> trace.attributes([
      attribute.string(order_id_key, order_id),
      attribute.int(amount_key, total_cents),
    ])

  use span <- trace.with_span(tracer, span_name, trace.Current, options)

  case total_cents > 0 {
    True -> {
      trace.add_event(span, "payment.authorized", [])
      trace.set_status(span, trace.StatusOk)
      Ok("payment-456")
    }
    False -> {
      trace.set_status(
        span,
        trace.StatusError(option.Some("invalid_payment_amount")),
      )
      Error(PaymentDeclined)
    }
  }
}

fn publish_confirmation(
  tracer tracer: trace.Tracer,
  order_id order_id: String,
  payment_id payment_id: String,
) -> Nil {
  let assert Ok(span_name) = trace.span_name("confirmation.publish")
  let assert Ok(order_id_key) = attribute.key("app.order.id")
  let assert Ok(payment_id_key) = attribute.key("app.payment.id")
  let options =
    trace.options(trace.Producer)
    |> trace.attributes([
      attribute.string(order_id_key, order_id),
      attribute.string(payment_id_key, payment_id),
    ])

  use span <- trace.with_span(tracer, span_name, trace.Current, options)

  trace.add_event(span, "confirmation.enqueued", [])
  trace.set_status(span, trace.StatusOk)
}
