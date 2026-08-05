# Importación histórica

La importación es únicamente para pedidos anteriores. Los pedidos quedan con:

- `source = CSV_HISTORY`
- `is_history = true`
- Estado cerrado o cancelado.
- Sin tareas operativas activas.

## Encabezados recomendados

```text
orderNumber
externalReference
orderType
paymentCondition
deliveryRoute
clientName
clientDocument
clientCity
status
priority
requiresCut
requiresPurchase
createdAt
updatedAt
closedAt
```

La interfaz procesa lotes de 200 filas para no superar límites de solicitud.
