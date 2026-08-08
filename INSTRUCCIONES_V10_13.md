# ERP EI V10.13 · Inteligencia operacional

Base requerida: V10.12 con la migración 028 aplicada.

## Objetivo

Esta versión no añade una capa visual aislada. Reconstruye y amplía cuatro capacidades del motor operativo:

1. SLA y escalamiento de Novedades, Reportes y Aprobaciones.
2. Centro de Excepciones unificado.
3. Analítica causal / Pareto para mejora continua.
4. Optimización de carretos en Corte.

## Instalación en una base existente

1. Reemplazar únicamente las rutas incluidas en `RUTAS_A_REEMPLAZAR.txt`.
2. Ejecutar una sola vez `sql/migrations/029_operational_intelligence_v10_13.sql`.
3. NO ejecutar `sql/00_INSTALL_ALL.sql` en una base existente. Este archivo se reemplaza solo para que instalaciones nuevas incorporen V10.13.
4. Desplegar el repositorio fusionado.
5. Desregistrar el Service Worker, limpiar datos del sitio y recargar con Ctrl+Shift+R.

## Motor SLA

- Novedad: alerta a 2 h laborales, escalamiento a 4 h, crítico a 8 h.
- Reporte: alerta a 1 h laboral, escalamiento a 2 h, crítico a 4 h.
- Aprobación: alerta a 1 h laboral, escalamiento a 2 h, crítico a 4 h.
- Los tiempos usan el calendario laboral configurado del ERP.
- Se crean alertas persistentes y se cierran automáticamente al resolver/decidir.
- La migración intenta habilitar/programar pg_cron cada 5 minutos de forma segura. Si el proyecto no lo permite, los RPC refrescan el SLA al consultar el ERP sin hacer fallar la instalación.

## Centro de Excepciones

La ruta existente `approvals` se reconstruye como Centro de Excepciones para no crear un permiso/module paralelo innecesario. Contiene:

- Novedades abiertas.
- Reportes abiertos.
- Aprobaciones pendientes.
- Casos escalados por SLA.
- Historial cerrado.
- Resolución directa cuando el usuario tiene permiso.
- Decisión de aprobaciones para Jefatura Logística, Auditoría, Gerencia y Superadministración.

## Analítica causal

El módulo Reportes incorpora una analítica interactiva agregada por:

- Causa.
- Referencia/material.
- Asesor.
- Proveedor.
- Proceso.

Consolida Novedades/Reportes, mercancía no encontrada, asignaciones incorrectas de Corte y rechazos de Recepción. Incluye Pareto visual y exportación CSV.

## Optimización de Corte

Cada grupo de Corte consulta los carretos registrados para la misma referencia y devuelve:

- Recomendación operacional: menor remanente posible sin forzar aprobación cuando existe alternativa.
- Opción de mayor aprovechamiento de material.
- Hasta 8 alternativas comparables.
- Remanente proyectado.
- Porcentaje de utilización.
- Indicador de aprobación si el remanente queda entre 0 y 50 m.

La recomendación no ejecuta automáticamente el corte: el operario conserva la decisión y confirma el carreto antes de descontar inventario.
