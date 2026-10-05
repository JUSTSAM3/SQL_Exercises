-- =====================================================================
-- ARCHIVO DE RESPUESTAS (PARTE 3 Y 4)
-- En este archivo se presentaran todas las sentencias de la parte
-- 3 y 4. Se enviará junto al archivo .pdf y el video.
-- INTEGRANTES:
-- Samuel Andres Mesa Comaz
-- Juan Felipe Lozada Jara
-- =====================================================================

-- PARTE 3 - 03_SQL_AVANZADO
-- #####################################################################
-- EJERCICIO 3.1 — Ranking dentro de grupos
--
-- La vicepresidencia comercial quiere los 3 productos que más saldo
-- captan dentro de cada FAMILIA de productos, solo cuentas activas.
-- #####################################################################

-- MODELO (resuelto)
WITH captacion AS (
  SELECT f.id_producto  AS id_familia,
         f.nombre       AS familia,
         p.id_producto,
         p.nombre       AS producto,
         SUM(c.saldo)   AS saldo_captado,
         COUNT(*)       AS cuentas
    FROM cuenta c
    JOIN catalogo_producto p ON p.id_producto = c.id_producto
    JOIN catalogo_producto f ON f.id_producto = p.id_padre
   WHERE c.estado = 'ACTIVA'
   GROUP BY f.id_producto, f.nombre, p.id_producto, p.nombre
)
SELECT familia, producto, cuentas, ROUND(saldo_captado) AS saldo_captado, puesto
  FROM (SELECT v.*,
               ROW_NUMBER() OVER (PARTITION BY id_familia
                                  ORDER BY saldo_captado DESC) AS puesto
          FROM captacion v)
 WHERE puesto <= 3
 ORDER BY familia, puesto;

--  ESCRIBA 3.1 — La misma consulta, pero mostrando además qué porcentaje
--  representa cada producto sobre el saldo total captado por su familia.
--  Use RATIO_TO_REPORT o una función de ventana con SUM() OVER.
--  Cuidado: el porcentaje debe ser sobre la familia COMPLETA, no sobre
--  el top 3.

WITH captacion AS (
  SELECT f.id_producto  AS id_familia,
         f.nombre       AS familia,
         p.id_producto,
         p.nombre       AS producto,
         SUM(c.saldo)   AS saldo_captado,
         COUNT(*)       AS cuentas
    FROM cuenta c
    JOIN catalogo_producto p ON p.id_producto = c.id_producto
    JOIN catalogo_producto f ON f.id_producto = p.id_padre
   WHERE c.estado = 'ACTIVA'
   GROUP BY f.id_producto, f.nombre, p.id_producto, p.nombre
),
con_metricas AS (
  SELECT v.*,
         DENSE_RANK() OVER (PARTITION BY id_familia
                            ORDER BY saldo_captado DESC)      AS puesto,
         RATIO_TO_REPORT(saldo_captado)
             OVER (PARTITION BY id_familia)                   AS pct_familia
    FROM captacion v
)
SELECT familia, producto, cuentas,
       ROUND(saldo_captado)         AS saldo_captado,
       puesto,
       ROUND(pct_familia * 100, 2)  AS pct_sobre_familia
  FROM con_metricas
 WHERE puesto <= 3
 ORDER BY familia, puesto;


-- #####################################################################
-- EJERCICIO 3.2 — Series de tiempo: acumulado y variación
--
-- Riesgo operativo quiere la evolución mensual del valor transferido
-- durante 2026, con el acumulado del año y la variación contra el mes
-- anterior. Es la base de las alertas por comportamiento atípico.
-- #####################################################################

-- MODELO (resuelto)
WITH mensual AS (
  SELECT TRUNC(fecha_transf, 'MM') AS mes,
         SUM(valor)                AS valor_transferido,
         COUNT(*)                  AS operaciones
    FROM transferencia
   WHERE fecha_transf >= DATE '2026-01-01'
     AND fecha_transf <  DATE '2027-01-01'
     AND estado = 'APLICADA'
   GROUP BY TRUNC(fecha_transf, 'MM')
)
SELECT TO_CHAR(mes,'YYYY-MM')                          AS mes,
       operaciones,
       ROUND(valor_transferido)                        AS valor,
       ROUND(SUM(valor_transferido) OVER (ORDER BY mes
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS acumulado,
       ROUND(LAG(valor_transferido) OVER (ORDER BY mes)) AS mes_anterior,
       ROUND(100 * (valor_transferido - LAG(valor_transferido) OVER (ORDER BY mes))
                 / NULLIF(LAG(valor_transferido) OVER (ORDER BY mes),0), 1) AS var_pct
  FROM mensual
 ORDER BY mes;

--  ESCRIBA 3.2 — Agregue una columna con el promedio móvil de los
--  últimos 3 meses (mes actual y los dos anteriores), que es la línea
--  base contra la que riesgo compara cada mes.

WITH mensual AS (
  SELECT TRUNC(fecha_transf, 'MM') AS mes,
         SUM(valor)                AS valor_transferido,
         COUNT(*)                  AS operaciones
    FROM transferencia
   WHERE fecha_transf >= DATE '2026-01-01'
     AND fecha_transf <  DATE '2027-01-01'
     AND estado = 'APLICADA'
   GROUP BY TRUNC(fecha_transf, 'MM')
)
SELECT TO_CHAR(mes,'YYYY-MM')                          AS mes,
       operaciones,
       ROUND(valor_transferido)                        AS valor,
       ROUND(SUM(valor_transferido) OVER (ORDER BY mes
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS acumulado,
       ROUND(LAG(valor_transferido) OVER (ORDER BY mes)) AS mes_anterior,
       ROUND(100 * (valor_transferido - LAG(valor_transferido) OVER (ORDER BY mes))
                 / NULLIF(LAG(valor_transferido) OVER (ORDER BY mes),0), 1) AS var_pct,
       ROUND(AVG(valor_transferido) OVER (ORDER BY mes
             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))  AS prom_movil_3m
  FROM mensual
 ORDER BY mes;

-- #####################################################################
-- EJERCICIO 3.3 — La misma respuesta, dos planes muy distintos
--
-- Se necesita, por cada cliente PREFERENCIAL, su última transferencia.
-- #####################################################################

-- VERSIÓN A — subconsulta correlacionada  (la que sale sola al escribir)
EXPLAIN PLAN FOR
SELECT cl.id_cliente, cl.nombre, t.id_transferencia, t.fecha_transf, t.valor
  FROM cliente       cl
  JOIN cuenta        c ON c.id_cliente = cl.id_cliente
  JOIN transferencia t ON t.cuenta_origen = c.id_cuenta
 WHERE cl.segmento = 'PREFERENCIAL'
   AND t.fecha_transf = (SELECT MAX(t2.fecha_transf)
                           FROM transferencia t2
                           JOIN cuenta c2 ON c2.id_cuenta = t2.cuenta_origen
                          WHERE c2.id_cliente = cl.id_cliente);

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +COST +ROWS'));

-- VERSIÓN B — función analítica
EXPLAIN PLAN FOR
SELECT id_cliente, nombre, id_transferencia, fecha_transf, valor
  FROM (SELECT cl.id_cliente, cl.nombre, t.id_transferencia,
               t.fecha_transf, t.valor,
               ROW_NUMBER() OVER (PARTITION BY cl.id_cliente
                                  ORDER BY t.fecha_transf DESC) AS rn
          FROM cliente       cl
          JOIN cuenta        c ON c.id_cliente = cl.id_cliente
          JOIN transferencia t ON t.cuenta_origen = c.id_cuenta
         WHERE cl.segmento = 'PREFERENCIAL')
 WHERE rn = 1;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +COST +ROWS'));

-- #####################################################################
-- EJERCICIO 3.4 — Jerarquías: la CTE recursiva
--
-- El catálogo tiene tres niveles: línea de negocio, familia y producto.
-- #####################################################################

-- MODELO (resuelto) — ruta completa de cada nodo del catálogo
WITH arbol (id_producto, nombre, id_padre, nivel, ruta) AS (
  SELECT id_producto, nombre, id_padre, 1, CAST(nombre AS VARCHAR2(400))
    FROM catalogo_producto
   WHERE id_padre IS NULL
  UNION ALL
  SELECT c.id_producto, c.nombre, c.id_padre, a.nivel + 1,
         a.ruta || ' > ' || c.nombre
    FROM catalogo_producto c
    JOIN arbol a ON c.id_padre = a.id_producto
)
SELECT LPAD(' ', (nivel-1)*3) || nombre AS jerarquia, nivel, ruta
  FROM arbol
 ORDER BY ruta;

-- El equivalente con CONNECT BY, sintaxis propia de Oracle
SELECT LPAD(' ', (LEVEL-1)*3) || nombre AS jerarquia,
       LEVEL AS nivel,
       SYS_CONNECT_BY_PATH(nombre, ' > ') AS ruta
  FROM catalogo_producto
 START WITH id_padre IS NULL
CONNECT BY PRIOR id_producto = id_padre
 ORDER SIBLINGS BY nombre;

--  ESCRIBA 3.3 — Saldo total captado por LÍNEA DE NEGOCIO.
--  Es decir: el saldo de "Cuenta de ahorros" debe sumar dentro de
--  "Banca Personas". Use la CTE recursiva para resolver a qué línea
--  pertenece cada producto hoja, y únala con los saldos de CUENTA.
--  Muestre además cuántas cuentas activas tiene cada línea.

WITH arbol (id_producto, nombre, id_padre, nivel, id_linea, linea) AS (
  SELECT id_producto, nombre, id_padre, 1, id_producto, nombre
    FROM catalogo_producto
   WHERE id_padre IS NULL
  UNION ALL
  SELECT c.id_producto, c.nombre, c.id_padre, a.nivel + 1,
         a.id_linea, a.linea
    FROM catalogo_producto c
    JOIN arbol a ON c.id_padre = a.id_producto
)
SELECT a.linea                AS linea_negocio,
       ROUND(SUM(cu.saldo))   AS saldo_total,
       COUNT(*)               AS cuentas_activas
  FROM cuenta cu
  JOIN arbol a ON a.id_producto = cu.id_producto
 WHERE cu.estado = 'ACTIVA'
 GROUP BY a.linea
 ORDER BY saldo_total DESC;

-- #####################################################################
-- EJERCICIO 3.5 — MERGE: aplicar los ajustes del cierre mensual
--
-- Cada fin de mes se aplican intereses y cuotas de manejo. La tabla
-- AJUSTE_SALDO ya los tiene cargados.
-- #####################################################################

-- PASO 1  Antes
SELECT ROUND(SUM(saldo)) AS saldo_total, COUNT(*) AS cuentas FROM cuenta;
SELECT concepto, COUNT(*), SUM(delta) FROM ajuste_saldo GROUP BY concepto;

-- MODELO (resuelto)
MERGE INTO cuenta c
USING (SELECT id_cuenta, SUM(delta) AS delta
         FROM ajuste_saldo
        GROUP BY id_cuenta) a
   ON (c.id_cuenta = a.id_cuenta)
 WHEN MATCHED THEN
   UPDATE SET c.saldo   = GREATEST(c.saldo + a.delta, 0),
              c.version = c.version + 1;
--> Mire el mensaje de SQL Developer: cuántas filas fusionó. -> Fusionó 500 filas
COMMIT;

-- PASO 2  Después
SELECT ROUND(SUM(saldo)) AS saldo_total FROM cuenta;

--  ESCRIBA 3.4 — Reescriba el MERGE para que las cuentas cuyo ajuste no
--  se pueda aplicar completo NO se toquen, y en cambio queden
--  identificadas. Pista: la cláusula WHERE de la actualización dentro
--  del MERGE, más una consulta que liste las excluidas.

MERGE INTO cuenta c
USING (SELECT id_cuenta, SUM(delta) AS delta
         FROM ajuste_saldo
        GROUP BY id_cuenta) a
   ON (c.id_cuenta = a.id_cuenta)
 WHEN MATCHED THEN
   UPDATE SET c.saldo   = c.saldo + a.delta,
              c.version = c.version + 1
   WHERE c.saldo + a.delta >= 0;

COMMIT;

SELECT c.id_cuenta, c.saldo AS saldo_actual, a.delta,
       c.saldo + a.delta    AS saldo_que_habria_quedado
  FROM cuenta c
  JOIN (SELECT id_cuenta, SUM(delta) AS delta
          FROM ajuste_saldo
         GROUP BY id_cuenta) a ON a.id_cuenta = c.id_cuenta
 WHERE c.saldo + a.delta < 0
 ORDER BY saldo_que_habria_quedado;

-- #####################################################################
-- EJERCICIO 3.6 — PIVOT y LISTAGG
-- #####################################################################

-- MODELO (resuelto) — valor transferido por canal y trimestre, en columnas
SELECT *
  FROM (SELECT canal,
               'T' || TO_CHAR(fecha_transf,'Q') AS trimestre,
               valor
          FROM transferencia
         WHERE fecha_transf >= DATE '2026-01-01'
           AND fecha_transf <  DATE '2027-01-01'
           AND estado = 'APLICADA')
 PIVOT (ROUND(SUM(valor)) FOR trimestre IN ('T1' AS t1, 'T2' AS t2,
                                            'T3' AS t3, 'T4' AS t4))
 ORDER BY canal;
 
--  La sentencia anterior no ejecutaba, por lo cual se implementó la siguiente:
SELECT canal,
       ROUND(t1) AS t1,
       ROUND(t2) AS t2,
       ROUND(t3) AS t3,
       ROUND(t4) AS t4
  FROM (SELECT canal,
               'T' || TO_CHAR(fecha_transf, 'Q') AS trimestre,
               valor
          FROM transferencia
         WHERE fecha_transf >= DATE '2026-01-01'
           AND fecha_transf <  DATE '2027-01-01'
           AND estado = 'APLICADA')
 PIVOT (SUM(valor) FOR trimestre IN ('T1' AS t1,
                                     'T2' AS t2,
                                     'T3' AS t3,
                                     'T4' AS t4))
 ORDER BY canal;

-- MODELO (resuelto) — los 10 clientes con más saldo y qué productos tienen
SELECT cl.id_cliente, cl.nombre, cl.segmento,
       ROUND(SUM(c.saldo)) AS saldo_total,
       COUNT(*)            AS cuentas,
       LISTAGG(DISTINCT p.nombre, ', ')
         WITHIN GROUP (ORDER BY p.nombre) AS productos
  FROM cliente cl
  JOIN cuenta  c ON c.id_cliente  = cl.id_cliente
  JOIN catalogo_producto p ON p.id_producto = c.id_producto
 WHERE c.estado = 'ACTIVA'
 GROUP BY cl.id_cliente, cl.nombre, cl.segmento
 ORDER BY saldo_total DESC
 FETCH FIRST 10 ROWS WITH TIES;

--  ESCRIBA 3.5 — Un informe de "clientes en fuga": clientes
--  PREFERENCIAL cuya última transferencia tiene más de 120 días,
--  mostrando cuántos días llevan inactivos, su saldo total y cuántos
--  productos tienen contratados.

WITH ultima_transf AS (
  SELECT cu.id_cliente, MAX(t.fecha_transf) AS ultima_fecha
    FROM cuenta cu
    JOIN transferencia t ON t.cuenta_origen = cu.id_cuenta
   WHERE t.estado = 'APLICADA'
   GROUP BY cu.id_cliente
)
SELECT cl.id_cliente,
       cl.nombre,
       ut.ultima_fecha,
       TRUNC(SYSDATE - ut.ultima_fecha)     AS dias_inactivo,
       ROUND(SUM(cu.saldo))                 AS saldo_total,
       COUNT(DISTINCT cu.id_producto)       AS productos_contratados
  FROM cliente cl
  JOIN cuenta  cu ON cu.id_cliente = cl.id_cliente
  LEFT JOIN ultima_transf ut ON ut.id_cliente = cl.id_cliente
 WHERE cl.segmento = 'PREFERENCIAL'
   AND cu.estado = 'ACTIVA'
   AND (ut.ultima_fecha IS NULL OR ut.ultima_fecha < SYSDATE - 120)
 GROUP BY cl.id_cliente, cl.nombre, ut.ultima_fecha
 ORDER BY dias_inactivo DESC NULLS FIRST;
 
-- =====================================================================

-- PARTE 4 - 04_RETO

-- ---------------------------------------------------------------------
-- EL TICKET
--
--   De:    Gerencia de Operaciones, Banco Andino
--   Para:  Equipo de Base de Datos
--   Asunto: CRÍTICO — descuadres en transferencias
--
--   "Desde el puente festivo tenemos tres problemas:
--
--    1. La cuenta de compensación no cuadra. Hay días en que el total
--       debitado no coincide con el total acreditado, por montos
--       pequeños pero constantes. Contraloría ya abrió un caso.
--
--    2. Aparecieron transferencias donde al cliente le descontaron la
--       plata y nunca le llegó al destinatario. Otras al revés: llegó
--       al destino sin haber salido del origen. Nadie sabe cuántas son.
--
--    3. El tablero de la Vicepresidencia se demora casi un minuto en
--       abrir, y lo consultan cada media hora.
--
--    Adjunto la secuencia de sentencias que ejecuta el core cada vez
--    que se aplica una transferencia, y la consulta del tablero.
--    Necesitamos un diagnóstico y la corrección."
-- ---------------------------------------------------------------------


-- #####################################################################
-- PIEZA 1 — Lo que ejecuta el core al aplicar una transferencia
--
-- Caso real: la transferencia 950001, de la cuenta 1001 a la 1002,
-- por 300.000 pesos.
--
-- Ejecútelo tal como está y observe qué hace. NO lo corrija todavía.
-- #####################################################################

-- Deje las cuentas en un valor conocido antes de probar
UPDATE cuenta SET saldo = 1000000, version = 0 WHERE id_cuenta IN (1001, 1002);
UPDATE transferencia SET estado = 'REGISTRADA' WHERE id_transferencia = 950001;
COMMIT;

SELECT id_cuenta, saldo FROM cuenta WHERE id_cuenta IN (1001,1002) ORDER BY id_cuenta;


--- inicio de lo que ejecuta el core -----------------------------------

-- 1. Débito del origen: la aplicación lee el saldo...
SELECT saldo FROM cuenta WHERE id_cuenta = 1001;
--> ...guarda ese número, le resta 300.000, y escribe el resultado:
-- Leo el número 1000000 y le resto 200000, escribiendo 800000
UPDATE cuenta SET saldo = 800000 WHERE id_cuenta = 1001;
COMMIT;

-- 2. Crédito del destino: lo mismo al otro lado
SELECT saldo FROM cuenta WHERE id_cuenta = 1002;
--> ...le suma 300.000 y escribe:
UPDATE cuenta SET saldo = 1300000 WHERE id_cuenta = 1002;
COMMIT;

-- 3. Los dos movimientos contables
INSERT INTO movimiento (id_movimiento, id_cuenta, id_transferencia, fecha_mov, tipo, valor)
VALUES (9500001, 1001, 950001, SYSDATE, 'DEBITO', 300000);
COMMIT;

INSERT INTO movimiento (id_movimiento, id_cuenta, id_transferencia, fecha_mov, tipo, valor)
VALUES (9500002, 1002, 950001, SYSDATE, 'CREDITO', 300000);
COMMIT;

-- 4. Y al final marca la transferencia
UPDATE transferencia SET estado = 'APLICADA' WHERE id_transferencia = 950001;
COMMIT;

--- fin de lo que ejecuta el core --------------------------------------

SELECT id_cuenta, saldo FROM cuenta WHERE id_cuenta IN (1001,1002) ORDER BY id_cuenta;
SELECT id_transferencia, estado FROM transferencia WHERE id_transferencia = 950001;


-- #####################################################################
-- PIEZA 2 — La consulta del tablero de la Vicepresidencia
-- #####################################################################

EXPLAIN PLAN FOR
SELECT s.ciudad,
       COUNT(DISTINCT t.id_transferencia)  AS operaciones,
       ROUND(SUM(t.valor))                 AS valor_total,
       ROUND(AVG(t.valor))                 AS ticket
  FROM transferencia t
  JOIN cuenta        c ON c.id_cuenta   = t.cuenta_origen
  JOIN sucursal      s ON s.id_sucursal = c.id_sucursal
 WHERE TO_CHAR(t.fecha_transf, 'YYYY-MM') = '2026-03'
   AND t.estado = 'APLICADA'
 GROUP BY s.ciudad
 ORDER BY valor_total DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +COST +ROWS'));

-- #####################################################################
-- LO QUE HAY QUE ENTREGAR
-- #####################################################################
--
-- A. DIAGNÓSTICO: ARCHIVO .PDF (RESPUESTAS Y EVIDENCIAS DE REPRODUCCIÓN DE ERRORES)

-- B. CORRECCIÓN  
SELECT id_cuenta, saldo
  FROM cuenta
 WHERE id_cuenta IN (1001, 1002)
 ORDER BY id_cuenta
   FOR UPDATE;

UPDATE cuenta
   SET saldo = saldo - 300000
 WHERE id_cuenta = 1001;
-- Acá debe mencionar "1 fila afectadas.". Si no aparece ("0 filas afectadas"), es donde se tiene que evaluar que está pasando.
-- Nota no se es necesario verificar el saldo antes de hacer la actualización
-- porque en el setup se usa CHECK ck_cta_saldo (saldo >= 0) que ya existe en la tabla.
UPDATE cuenta
   SET saldo = saldo + 300000
 WHERE id_cuenta = 1002;
--> Igual que el punto anterior.

INSERT INTO movimiento (id_movimiento, id_cuenta, id_transferencia, fecha_mov, tipo, valor)
VALUES (9500001, 1001, 950001, SYSDATE, 'DEBITO', 300000);

INSERT INTO movimiento (id_movimiento, id_cuenta, id_transferencia, fecha_mov, tipo, valor)
VALUES (9500002, 1002, 950001, SYSDATE, 'CREDITO', 300000);

UPDATE transferencia
   SET estado = 'APLICADA'
 WHERE id_transferencia = 950001
   AND estado = 'REGISTRADA';
-- De igual forma, revisar las filas actualizadas. Además, acá también es un punto de control, puesto que indica
-- Si existe algún error o algo así.
-- Hacer solo un COMMIT (o si algo de los pasos anteriores despertó dudas, ROLLBACK)
COMMIT;

-- C. OPTIMIZACIÓN DE LA CONSULTA: EVIDENCIAS Y EXPLICACIÓN EN EL ARCHIVO .PDF
CREATE INDEX idx_transf_tablero_comp ON transferencia (fecha_transf, estado, cuenta_origen, valor);
EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'TRANSFERENCIA', cascade => TRUE);

EXPLAIN PLAN FOR
SELECT s.ciudad,
       COUNT(DISTINCT t.id_transferencia)  AS operaciones,
       ROUND(SUM(t.valor))                 AS valor_total,
       ROUND(AVG(t.valor))                 AS ticket
  FROM transferencia t
  JOIN cuenta        c ON c.id_cuenta   = t.cuenta_origen
  JOIN sucursal      s ON s.id_sucursal = c.id_sucursal
 WHERE t.fecha_transf >= DATE '2026-03-01'
   AND t.fecha_transf <  DATE '2026-04-01'
   AND t.estado = 'APLICADA'
 GROUP BY s.ciudad
 ORDER BY valor_total DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +COST +ROWS'));

-- D. UNA RECOMENDACIÓN: ARCHIVO .PDF