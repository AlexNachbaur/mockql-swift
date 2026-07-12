# Working with Subscriptions

Push GraphQL subscription events from test code to exercise real-time UI.

## The model

MockQL subscriptions are **test-driven**: nothing fires until your test code publishes an
event. Clients subscribe (over the `graphql-transport-ws` WebSocket protocol when using the
`MockQL` server module, or via ``MockQLEngine/subscribe(_:)`` in-process), and each published
payload is resolved through every subscriber's own selection set:

```swift
try await engine.publish("orderStatusChanged", payload: [
    "id": "order-1",
    "status": .enumValue("SHIPPED"),
])
```

Publishing validates the field against the subscription root type (with a suggestion on typos)
and is a no-op when nobody is subscribed. The payload may:

- carry values directly, as above;
- reference stored records — `.reference("Order", id: "order-1")` resolves through the store;
- omit fields, which generate deterministically like any unseeded field.

Payloads are ephemeral event data: publishing does not modify server state. If the event should
also change state (an order becoming shipped), update the store via a mutation handler or
directly, then publish.

## In-process streams

``MockQLEngine/subscribe(_:)`` returns an `AsyncStream` of ``GraphQLResponse`` values — useful
for testing subscription resolution without a socket:

```swift
let stream = try await engine.subscribe(
    GraphQLRequest(query: "subscription { orderStatusChanged { id status } }")
)
try await engine.publish("orderStatusChanged", payload: ["id": "o1"])
for await event in stream {
    // event.data?["orderStatusChanged"]["id"] == "o1"
    break
}
```

The stream ends when the consuming task is cancelled or the engine shuts down.

## Synchronizing tests

Subscribing over a real WebSocket is asynchronous; publish *after* the subscriber is
registered. ``MockQLEngine/activeSubscriptionCount()`` exists for exactly this:

```swift
while await engine.activeSubscriptionCount() == 0 {
    try await Task.sleep(nanoseconds: 10_000_000)
}
try await server.publish("orderStatusChanged", payload: […])
```

## Wire protocol

The server module speaks `graphql-transport-ws` — `connection_init`/`connection_ack`,
`subscribe`/`next`/`complete`, `ping`/`pong`, and the protocol's close codes — which is what
Apollo, urql, and Relay clients use out of the box. Point clients at the server's
`webSocketURL`.
