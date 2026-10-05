--------------------------------------------------------------------------------
-- UNIVERSIDAD EL BOSQUE — INGENIERIA DE SISTEMAS
-- Asignatura: Bases de Datos 2
-- Docente: Ing., Esp., M.Ed. Christian Felipe Duarte
--
-- TALLER PL/SQL — PLANTILLA DE ENTREGA
--
-- GRUPO No.: 2
-- INTEGRANTES: 1) Luna Calderón Montenegro
--              2) Juan Felipe Lozada Jara
--              3) Samuel Andres Mesa Comaz
-- FECHA DE ENTREGA: 3 de octurbe de 2026
--------------------------------------------------------------------------------
--
-- COMO TRABAJAR
--   1. Ejecute primero, completo, el script 01_esquema_inventario.sql
--   2. Desarrolle cada punto en la seccion correspondiente de este archivo
--   3. No borre los encabezados de cada ejercicio ni cambie los nombres de los
--      objetos solicitados. La revision los busca por nombre: un objeto correcto
--      con otro nombre se califica como no entregado.
--   4. Los esqueletos de la Parte 5 no incluyen la clausula de disparo. Definirla
--      hace parte del ejercicio, de modo que esos bloques no compilan tal como se
--      entregan.
--
-- DISTRIBUCION DEL PUNTAJE                                     Total: 50 puntos
--   Parte 1  Procedimientos almacenados .................  8 puntos
--   Parte 2  Funciones ...................................  8 puntos
--   Parte 3  Cursores .................................... 10 puntos
--   Parte 4  Manejo de excepciones .......................  9 puntos
--   Parte 5  Disparadores ................................ 10 puntos
--   Parte 6  Caso integrador .............................  5 puntos
--
-- CRITERIOS DE EVALUACION
--   Correccion tecnica ....... 40%   El objeto compila y cumple el enunciado
--   Justificacion ............ 40%   Las decisiones de diseno estan argumentadas
--   Analisis operacional ..... 20%   Se anticipa el comportamiento ante
--                                    concurrencia, volumen y error
--
--   Cada objeto debe incluir su justificacion en el espacio marcado. Un ejercicio
--   sin justificacion obtiene como maximo el 40% de su puntaje aunque funcione.
--   Una justificacion que confunde la causa con el efecto no obtiene puntaje.
--   Describir lo que hace el codigo, sin argumentar por que se eligio esa
--   construccion y no otra, equivale a no justificar.
--
-- ENTREGA
--   Este archivo renombrado como TALLER_PLSQL_GRUPO_<n>.sql, junto con un
--   documento que contenga las salidas de DBMS_OUTPUT de cada bloque ejecutado.
--   Ambos archivos deben incluir los nombres de los tres integrantes.
--
-- SUSTENTACION
--   20 minutos por grupo. Los tres integrantes deben poder explicar cualquier
--   parte del codigo, no solamente la que desarrollaron.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED

--==============================================================================
-- PARTE 1 — PROCEDIMIENTOS ALMACENADOS                        (8 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 1.1 (2 pts)
-- SP_REGISTRAR_PRODUCTO
-- Registra un producto nuevo. Debe asignar el identificador desde SEQ_PRODUCTO,
-- validar que el precio de venta supere el costo unitario, verificar que la
-- categoria exista y manejar el caso de codigo duplicado. Devuelve el
-- identificador generado.
-------------------------------------------------------------------------------
-- JUSTIFICACION: 
--Validamos primero el precio y la categoría para después tomar el numero de la 
--secuencia porque un ROLLBACK no la devuelve. El código duplicado lo manejamos 
--capturando DUP_VAL_ON_INDEX porque UNIQUE evita los duplicados incluso con usuarios a la vez.
--No se hace COMMIT para que el quien use el procedimiento decida si lo hace o no. 
--
CREATE OR REPLACE PROCEDURE SP_REGISTRAR_PRODUCTO (
    p_codigo        IN  VARCHAR2,
    p_nombre        IN  VARCHAR2,
    p_id_categoria  IN  NUMBER,
    p_precio        IN  NUMBER,
    p_costo         IN  NUMBER,
    p_stock_minimo  IN  NUMBER DEFAULT 0,
    p_id_producto   OUT NUMBER
) IS
    vn_auxiliar NUMBER;
BEGIN
    --Que el precio de venta sea mayor al costo de uno solo
    if p_precio <= p_costo then
        raise_application_error(-20001, 'El precio de venta debe ser mayor al costo unitario');
    end if;

    --Que la categoria exista
    select count(*) into vn_auxiliar 
    from categoria 
    where id_categoria = p_id_categoria;
    if vn_auxiliar = 0 then
        raise_application_error(-20002, 'La categoría no existe');
    end if;

    --Que se tome el identificador desde la secuencia
    p_id_producto := SEQ_PRODUCTO.NEXTVAL;

    --Insertar
        INSERT INTO PRODUCTO (id_producto, codigo, nombre, id_categoria,
                          precio_unitario, costo_unitario, stock_minimo, activo)
    VALUES (p_id_producto, p_codigo, p_nombre, p_id_categoria,
            p_precio, p_costo, p_stock_minimo, 'S');
    EXCEPTION
    --Codigo duplicado
    WHEN DUP_VAL_ON_INDEX THEN
        RAISE_APPLICATION_ERROR(-20003,
            'Ya existe un producto con el codigo ' || p_codigo);
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error en SP_REGISTRAR_PRODUCTO: ' || SQLERRM);
        RAISE;
END SP_REGISTRAR_PRODUCTO;
/
--Prueba

DECLARE
    vn_aux NUMBER;
BEGIN
    SP_REGISTRAR_PRODUCTO('PP-0001','prueba', 1,100000, 50000,5,vn_aux);

    DBMS_OUTPUT.PUT_LINE(vn_aux);
END;
--prueba de que se registro
SELECT *
FROM   PRODUCTO
WHERE  codigo = 'PP-0001';
/

------------------------------------------------------------------- 1.2 (3 pts)
-- SP_AJUSTAR_STOCK
-- Registra una ENTRADA, SALIDA o AJUSTE de inventario sobre una bodega.
-- Debe actualizar EXISTENCIA e insertar el registro en MOVIMIENTO_INVENTARIO,
-- devolviendo el saldo resultante.
--   * Si la combinacion bodega-producto no existe y el tipo es ENTRADA, crearla
--   * Si el tipo es SALIDA y no existe la combinacion, rechazar la operacion
--   * Una SALIDA nunca puede dejar la existencia en negativo
-- Proteja la lectura de la existencia frente a modificaciones concurrentes.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/* 
El procedimiento centraliza las operaciones de inventario, permitiendo registrar 
ENTRADAS, SALIDAS y AJUSTES. La existencia se consulta con FOR UPDATE para bloquear 
la fila mientras se realiza la operación y evitar modificaciones al mismo tiempo 
sobre el mismo producto y bodega. 

Si la existencia no existe, solamente se permite crearla cuando la operación es 
una ENTRADA. Una SALIDA sobre una combinación inexistente se rechaza y una SALIDA 
nunca puede producir una existencia negativa. 

Cada operación realizada se registra en MOVIMIENTO_INVENTARIO. 
*/
CREATE OR REPLACE PROCEDURE SP_AJUSTAR_STOCK (
    p_id_producto  IN  NUMBER,
    p_id_bodega    IN  NUMBER,
    p_tipo         IN  VARCHAR2,
    p_cantidad     IN  NUMBER,
    p_observacion  IN  VARCHAR2 DEFAULT NULL,
    p_saldo_final  OUT NUMBER
) IS
    v_cantidad_existencia EXISTENCIA.cantidad%TYPE;
    v_nuevo_saldo         EXISTENCIA.cantidad%TYPE;
BEGIN

    IF p_tipo NOT IN ('ENTRADA', 'SALIDA', 'AJUSTE') THEN RAISE_APPLICATION_ERROR(-20001, 'Tipo de movimiento no valido');
    END IF;

    IF p_cantidad <= 0 THEN RAISE_APPLICATION_ERROR(-20002, 'La cantidad debe ser mayor que cero');
    END IF;

    BEGIN
        SELECT cantidad INTO v_cantidad_existencia FROM EXISTENCIA
            WHERE id_bodega = p_id_bodega AND id_producto = p_id_producto FOR UPDATE;

        IF p_tipo = 'ENTRADA' THEN v_nuevo_saldo := v_cantidad_existencia + p_cantidad;
        ELSIF p_tipo = 'SALIDA' THEN v_nuevo_saldo := v_cantidad_existencia - p_cantidad;
            IF v_nuevo_saldo < 0 THEN RAISE_APPLICATION_ERROR(-20003, 'La salida supera la existencia disponible');
            END IF;
        ELSE v_nuevo_saldo := v_cantidad_existencia + p_cantidad;
        END IF;

        UPDATE EXISTENCIA SET cantidad = v_nuevo_saldo WHERE id_bodega = p_id_bodega AND id_producto = p_id_producto;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            IF p_tipo = 'ENTRADA' THEN v_nuevo_saldo := p_cantidad;
                INSERT INTO EXISTENCIA (id_bodega, id_producto, cantidad)
                VALUES (p_id_bodega, p_id_producto, v_nuevo_saldo);
            ELSE
                RAISE_APPLICATION_ERROR(-20004, 'No existe existencia para esta bodega y producto');
            END IF;
    END;

    INSERT INTO MOVIMIENTO_INVENTARIO (id_movimiento, id_producto, id_bodega, 
    tipo, cantidad, fecha_mov, id_pedido, usuario_bd, observacion)
    VALUES (SEQ_MOVIMIENTO.NEXTVAL, p_id_producto, p_id_bodega, p_tipo, p_cantidad, 
    SYSDATE, NULL, USER, p_observacion);

    p_saldo_final := v_nuevo_saldo;

END SP_AJUSTAR_STOCK;
/
-- Pruebas
DECLARE
    v NUMBER;
    PROCEDURE intento(p_prod NUMBER, p_bod NUMBER, p_tipo VARCHAR2,
                      p_cant NUMBER, p_msg VARCHAR2) IS
    BEGIN
        SP_AJUSTAR_STOCK(p_prod, p_bod, p_tipo, p_cant, 'prueba 1.2', v);
        DBMS_OUTPUT.PUT_LINE(RPAD(p_msg, 34) || '-> saldo ' || v);
    EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE(RPAD(p_msg, 34) || '-> ' || SQLERRM);
    END;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Saldo inicial 1001/bodega 1: ' || FN_STOCK_DISPONIBLE(1001, 1));
    intento(1001, 1, 'ENTRADA', 10,    'ENTRADA existente');        
    intento(1001, 1, 'SALIDA',  30,    'SALIDA valida');            
    intento(1001, 1, 'AJUSTE',  5,     'AJUSTE');                   
    intento(1005, 2, 'ENTRADA', 7,     'ENTRADA crea combinacion'); 
    intento(1001, 1, 'SALIDA',  99999, 'SALIDA mayor a existencia'); 
    intento(1002, 2, 'SALIDA',  1,     'SALIDA combinacion inexist.');
    intento(1001, 1, 'OTRO',    5,     'tipo invalido');            
    intento(1001, 1, 'ENTRADA', 0,     'cantidad 0');               
    SELECT COUNT(*) INTO v FROM MOVIMIENTO_INVENTARIO WHERE observacion = 'prueba 1.2';
    DBMS_OUTPUT.PUT_LINE('Movimientos registrados: ' || v);         
    ROLLBACK;
END;
/


------------------------------------------------------------------- 1.3 (3 pts)
-- SP_CREAR_PEDIDO
-- Crea la cabecera de un pedido en estado BORRADOR y devuelve el identificador
-- generado. Debe rechazar clientes inactivos y clientes sin cupo de credito
-- disponible, con mensajes distinguibles entre si.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*¿Que hace? La siguiente sentencia crea un procedimiento almacenado que recibe como entrada
el id del cliente y como salida el id del pedido. Se nos pide crear un pedido con
el id del cliente recibido con estado BORRADOR, rechazando a los clientes sin cupo
o inactivos. Por lo que inicializamos las variables vc_activo de un solo character 
en 'N' (Inactivo), vn_cupo como numero en 0, y las excepciones e_inactivo y e_sincupo.
Consultamos las columnas activo, cupo_credito y saldo pendiente para asignar a las 
variables  vc_activo si el cliente esta activo o no (S/N) y a vn_cupo el cupo de 
credito menos el saldo pendiente. Luego condicionamos, si vc_activo se guarda en N
eleva 'Usuario inactivo', si vn_cupo es menor o igual a 0 eleva 'Usuario sin cupo disponible',
luego si ninguna de las anteriores se cumple ahi si crea un nuevo pedido con el 
id del usuario ingresado, el id del pedido siguiente secuencialmente y estado: 'BORRADOR'.
¿Porque? Se realiza la sentencia con un procedimiento almacenado ya que, como lo que 
se esta pidiendo es actualizar una tabla, se realiza una accion DML y se entregam el 
resultado mediante el OUT de los parametros. */

CREATE OR REPLACE PROCEDURE SP_CREAR_PEDIDO (
    p_id_cliente  IN  NUMBER,
    p_id_pedido   OUT NUMBER
) IS
    vc_activo CHAR(1) := 'N';
    vn_cupo NUMBER := 0;
    e_inactivo EXCEPTION;
    e_sin_cupo EXCEPTION;
    
BEGIN
    SELECT activo, cupo_credito - saldo_pendiente
    INTO vc_activo, vn_cupo
    FROM CLIENTE WHERE id_cliente = p_id_cliente;
    
    IF vc_activo = 'N' THEN 
        RAISE e_inactivo;
    ELSIF vn_cupo <= 0 THEN
        RAISE e_sin_cupo;
    END IF;
    
    INSERT INTO PEDIDO (id_pedido, id_cliente, estado)
        VALUES (seq_pedido.NEXTVAL, p_id_cliente, 'BORRADOR')
    RETURNING id_pedido INTO p_id_pedido;
    
EXCEPTION 
    WHEN e_inactivo THEN 
        dbms_output.put_line('Usuario Inactivo');
    WHEN e_sin_cupo THEN 
        dbms_output.put_line('Usuario sin cupo disponible');
    
    WHEN NO_DATA_FOUND THEN 
        dbms_output.put_line('Usuario no encontrado');
    
END SP_CREAR_PEDIDO;
/

-- PRUEBA PUNTO 1.3

DECLARE
    vn_id_pedido NUMBER;
BEGIN
    FOR i IN 501..507 LOOP
        SP_CREAR_PEDIDO(i,vn_id_pedido);
        dbms_output.put_line('Pedido ' || i || ' procesado. ID generado: ' || vn_id_pedido);
    END LOOP;
    
    ROLLBACK;
END;
/

--==============================================================================
-- PARTE 2 — FUNCIONES                                         (8 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 2.1 (2 pts)
-- FN_STOCK_DISPONIBLE
-- Retorna la cantidad disponible de un producto. Si se indica bodega, devuelve
-- el saldo de esa bodega; si p_id_bodega llega nulo, el consolidado de todas.
-- Un producto inexistente debe retornar cero y no una excepcion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos NVL(SUM(cantidad), 0) porque SUM da NULL cuando no hay filas y asi un
-- producto que no existe retorna 0 sin necesidad de excepciones.
-- Separamos los dos casos con un IF porque comparar id_bodega = NULL nunca 
-- es verdadero y devolveria 0 en vez de tomar todas las bodegas
-- La funcion solo lee datos entonces tambien puede usarse
-- dentro de una sentencia SELECT.
CREATE OR REPLACE FUNCTION FN_STOCK_DISPONIBLE (
    p_id_producto IN NUMBER,
    p_id_bodega   IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
vn_stock NUMBER;
BEGIN
    --Si no hay bodega,se miran todas
     IF p_id_bodega IS NULL THEN
     --Si no hay producto, se retorna 0
        SELECT NVL(SUM(cantidad), 0)
        INTO   vn_stock
        FROM   EXISTENCIA
        WHERE  id_producto = p_id_producto;
    ELSE
    --Si hay bodega, se mira solo esa
        SELECT NVL(SUM(cantidad), 0)
        INTO   vn_stock
        FROM   EXISTENCIA
        WHERE  id_producto = p_id_producto
        AND    id_bodega   = p_id_bodega;
    END IF;
    RETURN vn_stock;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error en FN_STOCK_DISPONIBLE: ' || SQLERRM);
        RAISE;
END FN_STOCK_DISPONIBLE;
/
--Prueba
SELECT * from EXISTENCIA where id_producto = 1001;

SELECT FN_STOCK_DISPONIBLE(1001,1) as pruebaConbodega1,
FN_STOCK_DISPONIBLE(1001,2) as pruebaConbodega2,
FN_STOCK_DISPONIBLE(1001) as pruebaSinbodega
from dual;
/
------------------------------------------------------------------- 2.2 (2 pts)
-- FN_CUPO_DISPONIBLE
-- Retorna el cupo de credito disponible del cliente, entendido como cupo menos
-- saldo pendiente. Un cliente inactivo retorna cero y el resultado nunca puede
-- ser negativo.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*¿Que hace? La funcion recibe como parametro el id del cliente y retorna su cupo
de credito disponible. Consulta el estado del cliente, su cupo de credito y su
saldo pendiente. Si el cliente esta inactivo retorna 0; si esta activo retorna
la resta entre el cupo de credito y el saldo pendiente. Se usa GREATEST(valor, 0)
para que el resultado nunca sea negativo (por ejemplo, cuando el cupo esta agotado),
y si el cliente no existe se captura NO_DATA_FOUND y tambien se retorna 0.
¿Por que? Se utiliza una funcion porque solo se necesita calcular y devolver un
unico valor numerico, sin modificar ninguna tabla. Al no tener efectos secundarios,
puede reutilizarse en otras reglas de negocio (como la creacion de pedidos) y
llamarse directamente desde una sentencia SELECT, como se hace en el punto 2.4.
*/


CREATE OR REPLACE FUNCTION FN_CUPO_DISPONIBLE (
    p_id_cliente IN NUMBER
) RETURN NUMBER IS
    vc_activo CHAR(1) := 'N';
    vn_cupo NUMBER := 0;
    
BEGIN
    SELECT activo, cupo_credito - saldo_pendiente
    INTO vc_activo, vn_cupo
    FROM CLIENTE WHERE id_cliente = p_id_cliente;
    
    IF vc_activo = 'N' THEN 
        RETURN 0;
    END IF;
    
    RETURN GREATEST(vn_cupo, 0);

EXCEPTION
    
    WHEN NO_DATA_FOUND THEN 
        return 0;
    
END FN_CUPO_DISPONIBLE;
/

-- PRUEBA 2.2

BEGIN
    FOR i IN 501..507 LOOP
        dbms_output.put_line('Cliente ' || i || ' | Cupo disponible: ' || FN_CUPO_DISPONIBLE(i));
    END LOOP;
   
END;
/
------------------------------------------------------------------- 2.3 (3 pts)
-- FN_CALCULAR_DESCUENTO
-- Retorna el VALOR en pesos del descuento aplicable, segun estas reglas
-- acumulables:
--     Monto mayor o igual a 2.000.000 ................. 8%
--     Monto entre 800.000 y 1.999.999 ................. 5%
--     Monto menor a 800.000 ........................... 0%
--     Adicional si el cliente no tiene saldo pendiente . 2%
--     Tope maximo acumulado ........................... 10%
-- La funcion retorna el valor del descuento, no el porcentaje.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
La función permite encapsular en un único lugar las reglas de negocio utilizadas 
para calcular el descuento de un cliente. Se determina inicialmente el porcentaje 
según el monto de la compra y posteriormente se adiciona el beneficio correspondiente 
a los clientes que no tienen saldo pendiente. El límite del 10 % evita que la suma de 
beneficios supere el máximo establecido.  La función retorna el valor monetario 
del descuento por lo que el resultado puede utilizarse directamente en cálculos 
de facturación o pedidos. 
*/
CREATE OR REPLACE FUNCTION FN_CALCULAR_DESCUENTO (
    p_id_cliente IN NUMBER,
    p_monto      IN NUMBER
) RETURN NUMBER 
IS

    vnPorcentaje NUMBER;
    vnDescuento  NUMBER;
    vcSaldo      CLIENTE.saldo_pendiente%TYPE;

BEGIN
    SELECT saldo_pendiente INTO vcSaldo FROM CLIENTE WHERE id_cliente = p_id_cliente;

    IF p_monto >= 2000000 THEN vnPorcentaje := 8;
    ELSIF p_monto BETWEEN 800000 AND 1999999 THEN vnPorcentaje := 5;
    ELSE vnPorcentaje := 0;
    END IF;

    IF vcSaldo = 0 THEN vnPorcentaje := vnPorcentaje + 2;
    END IF;

    IF vnPorcentaje > 10 THEN vnPorcentaje := 10;
    END IF;

    vnDescuento := p_monto * vnPorcentaje / 100;

    RETURN vnDescuento;

EXCEPTION
    WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20005, 'El cliente no existe');
    
END FN_CALCULAR_DESCUENTO;
/
--Pruebas
SELECT 'Cli 501 |       500.000 -> 0'            AS caso, FN_CALCULAR_DESCUENTO(501,  500000) AS valor FROM dual UNION ALL
SELECT 'Cli 501 |       800.000 -> 40.000 (5%)'  , FN_CALCULAR_DESCUENTO(501,  800000) FROM dual UNION ALL
SELECT 'Cli 501 |     2.000.000 -> 160.000 (8%)' , FN_CALCULAR_DESCUENTO(501, 2000000) FROM dual UNION ALL
SELECT 'Cli 503 |       500.000 -> 10.000 (0+2%)', FN_CALCULAR_DESCUENTO(503,  500000) FROM dual UNION ALL
SELECT 'Cli 503 |       800.000 -> 56.000 (5+2%)', FN_CALCULAR_DESCUENTO(503,  800000) FROM dual UNION ALL
SELECT 'Cli 503 |     2.000.000 -> 200.000 (10%)', FN_CALCULAR_DESCUENTO(503, 2000000) FROM dual UNION ALL
SELECT 'Cli 501 | 1.999.999,50 -> 99.999,98 (5%)', FN_CALCULAR_DESCUENTO(501, 1999999.5) FROM dual;
/


------------------------------------------------------------------- 2.4 (1 pt)
-- Escriba una consulta que liste los clientes activos con su cupo disponible,
-- usando la funcion del punto 2.2, ordenados de mayor a menor.
-- Explique por que una funcion definida por el usuario puede invocarse desde
-- una sentencia SQL y que restriccion debe cumplir para poder hacerlo.
-------------------------------------------------------------------------------
-- RESPUESTA:
/*
Una función puede invocarse desde SQL porque retorna un valor que puede utilizarse
como una expresión dentro de una sentencia SQL. Para poder invocarse desde SQL, 
la función debe tener un tipo de retorno compatible con SQL y cumplir las restricciones
de las funciones que se ejecutan desde SQL, como por ejemplo, no debe realizar 
operaciones DML no permitidas sobre las tablas involucradas en la sentencia.
*/

SELECT
    id_cliente,
    nombre,
    FN_CUPO_DISPONIBLE(id_cliente) AS cupo_disponible
FROM CLIENTE
WHERE activo = 'S'
ORDER BY cupo_disponible DESC;
/

--Evidencia en el pdf

--==============================================================================
-- PARTE 3 — CURSORES                                         (10 puntos / 90 min)
--==============================================================================

------------------------------------------------------------------- 3.1 (2 pts)
-- Bloque anonimo que recorra, con un CURSOR EXPLICITO, los productos cuyo stock
-- consolidado este por debajo del stock minimo, e imprima un reporte con codigo,
-- nombre, stock actual, stock minimo y unidades faltantes, mas el total de
-- productos en esa condicion.
-- Debe usar OPEN, FETCH y CLOSE de forma explicita. El ciclo FOR implicito no se
-- acepta en este punto.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Hicimos que la condicion %NOTFOUND
-- se evaluara despues del FETCH para no tomar una fila de mas.
-- Usamos el filtro stock_total < stock_minimo dentro del cursor en el WHERE para traer solo las
-- filas que cumplen.

DECLARE
    -- Declaración del cursor explícito
    CURSOR c_bajo_minimo IS
        SELECT codigo,
               producto,
               stock_total,
               stock_minimo,
               (stock_minimo - stock_total) AS faltantes
        FROM   V_STOCK_CONSOLIDADO
        WHERE  stock_total < stock_minimo
        ORDER  BY faltantes DESC;

    r_fila c_bajo_minimo%ROWTYPE;
    vn_total NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Reporte: Productos con stock por debajo del minimo');
    OPEN c_bajo_minimo;
    
    LOOP
        FETCH c_bajo_minimo INTO r_fila;
        EXIT WHEN c_bajo_minimo%NOTFOUND;
        --Para contar 
        vn_total := vn_total + 1;
        
        DBMS_OUTPUT.PUT_LINE('Código: ' || r_fila.codigo || 
                             ' | Producto: ' || r_fila.producto || 
                             ' | Stock Actual: ' || r_fila.stock_total || 
                             ' | Stock Mínimo: ' || r_fila.stock_minimo || 
                             ' | Faltantes: ' || r_fila.faltantes);
    END LOOP;
    
    CLOSE c_bajo_minimo;
    DBMS_OUTPUT.PUT_LINE('Total de productos por debajo del minimo: ' || vn_total);
END;
/

------------------------------------------------------------------- 3.2 (2 pts)
-- Bloque anonimo con un CURSOR PARAMETRIZADO que reciba identificador de cliente
-- y un rango de fechas, y muestre los pedidos CONFIRMADOS de ese cliente en ese
-- rango, con su total y la cantidad de lineas de cada pedido.
-- Pruebelo con el cliente 501 entre 2026-01-01 y 2026-12-31.
-- Los parametros deben declararse en el cursor, no tomarse del alcance del bloque.
-------------------------------------------------------------------------------
-- JUSTIFICACION
/*¿Que hace? Se crea un cursor sobre el que se recibe el id del cliente y un 
rango de fehcas, la consulta une PEDIDO con DETALLE_PEDIDO y devuelve,
por cada pedido en estado CONFIRMADO del cliente dentro del rango, su id, su fecha, 
su total y la cantidad de lineas, se imprimen todos los pedidos del usuario de el año,
Se usa p_hasta + 1 con el operador < para incluir todo el ultimo dia, aunque la fecha 
tenga hora.
¿Porque? Se usa un cursosor ya que se rreuqiere procesar el resultado fila por fila,
y se parametriza para que se pueda reutilizar el cursor con otro cliente u otro rango
de fechas. 
*/

DECLARE
    CURSOR c_pedidos (p_id_cliente NUMBER, p_desde DATE, p_hasta DATE) IS
        SELECT p.id_pedido, p.fecha_pedido, p.total, COUNT(d.linea) AS lineas
        FROM   pedido p
               LEFT JOIN detalle_pedido d ON p.id_pedido = d.id_pedido
        WHERE  p.id_cliente = p_id_cliente
        AND    p.estado = 'CONFIRMADO'
        AND    p.fecha_pedido >= p_desde
        AND    p.fecha_pedido <  p_hasta + 1
        GROUP  BY p.id_pedido, p.fecha_pedido, p.total
        ORDER  BY p.fecha_pedido;
BEGIN
    FOR r IN c_pedidos(501, DATE '2026-01-01', DATE '2026-12-31') LOOP
        DBMS_OUTPUT.PUT_LINE('Pedido: ' || r.id_pedido || ', ' || TO_CHAR(r.fecha_pedido, 'YYYY-MM-DD')
            || '. Total ' || TO_CHAR(r.total, 'FM999G999G990') || '. Lineas ' || r.lineas);
    END LOOP;
END;
/

------------------------------------------------------------------- 3.3 (3 pts)
-- Bloque anonimo con un CURSOR FOR UPDATE que recorra los productos de una
-- categoria y ajuste su precio un porcentaje dado, usando WHERE CURRENT OF.
--   * No debe modificar productos inactivos
--   * El precio resultante no puede quedar por debajo del costo mas el margen
--     minimo de la categoria
-- Explique que bloqueo genera FOR UPDATE, cuanto dura, y por que WHERE CURRENT OF
-- es preferible a un UPDATE por clave primaria.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
El cursor permite recorrer únicamente los productos activos de una determinada 
categoría y modificar su precio de forma individual. FOR UPDATE es necesario 
porque las filas seleccionadas serán modificadas posteriormente, por lo cual Oracle
las bloquea para evitar modificaciones al tiempo que el cursor las procesa.  

WHERE CURRENT OF permite actualizar la fila que está siendo procesada por el 
cursor, evitando tener que volver a localizarla mediante otra condición. Además, 
antes de actualizar se verifica el precio mínimo permitido, calculado a partir del 
costo del producto y el margen mínimo establecido para su categoría. De esta manera, 
el procedimiento no solamente modifica precios, sino que también respeta una regla 
de negocio: el precio no debe quedar por debajo del costo más el margen mínimo. La 
relación entre producto y categoría, así como el campo margen_minimo, están definidos 
en PRODUCTO y CATEGORIA. 
*/
DECLARE

    CURSOR c_productos (p_id_categoria CATEGORIA.id_categoria%TYPE) IS
        SELECT p.id_producto, p.precio_unitario, p.costo_unitario, c.margen_minimo
        FROM PRODUCTO p JOIN CATEGORIA c 
        ON c.id_categoria = p.id_categoria
        WHERE p.id_categoria = p_id_categoria AND p.activo = 'S'
        FOR UPDATE OF p.precio_unitario;

    vpNuevoPrecio PRODUCTO.precio_unitario%TYPE;
    vnPorcentaje NUMBER := 10;

BEGIN

    FOR r IN c_productos(1) LOOP vpNuevoPrecio := r.precio_unitario * (1 + vnPorcentaje / 100);
        IF vpNuevoPrecio < r.costo_unitario * (1 + r.margen_minimo / 100) THEN
            vpNuevoPrecio := r.costo_unitario * (1 + r.margen_minimo / 100);
        END IF;
        UPDATE PRODUCTO SET precio_unitario = vpNuevoPrecio WHERE CURRENT OF c_productos;
    END LOOP;

END;
/
--Pruebas
SELECT id_producto, precio_unitario FROM PRODUCTO WHERE id_categoria = 1 ORDER BY id_producto;
SELECT id_producto, precio_anterior, precio_nuevo, variacion_pct
FROM   AUDITORIA_PRECIO ORDER BY id_auditoria;
ROLLBACK;
/
------------------------------------------------------------------- 3.4 (2 pts)
-- SP_LISTAR_MOVIMIENTOS
-- Procedimiento que reciba un identificador de producto y devuelva un
-- SYS_REFCURSOR con los movimientos de inventario de ese producto, ordenados
-- por fecha. Incluya un bloque anonimo que consuma el cursor devuelto y lo cierre.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos SYS_REFCURSOR para abrir la consulta en el procedimiento y pasar la 
-- referencia sin cargar todos los registros en la memoria en bloque consumidor
-- se hace la extraccion de datos.
-- El bloque consumidor evalua %NOTFOUND despues del FETCH y es quien ejecuta 
-- el CLOSE, ya que quien consume el cursor es el que debe liberar la memoria.

CREATE OR REPLACE PROCEDURE SP_LISTAR_MOVIMIENTOS (
    p_id_producto IN  NUMBER,
    p_cursor      OUT SYS_REFCURSOR
) IS
BEGIN
    OPEN p_cursor FOR
        SELECT id_movimiento, 
               tipo, 
               cantidad, 
               fecha_mov, 
               observacion
        FROM   MOVIMIENTO_INVENTARIO
        WHERE  id_producto = p_id_producto
        ORDER  BY fecha_mov;
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error en SP_LISTAR_MOVIMIENTOS: ' || SQLERRM);
        RAISE;
END SP_LISTAR_MOVIMIENTOS;
/

-- Bloque consumidor:
DECLARE
    v_cursor      SYS_REFCURSOR;
    
    vn_id_mov     MOVIMIENTO_INVENTARIO.id_movimiento%TYPE;
    vn_tipo        MOVIMIENTO_INVENTARIO.tipo%TYPE;
    vn_cantidad    MOVIMIENTO_INVENTARIO.cantidad%TYPE;
    vd_fecha       MOVIMIENTO_INVENTARIO.fecha_mov%TYPE;
    vv_observacion MOVIMIENTO_INVENTARIO.observacion%TYPE;
BEGIN
    DBMS_OUTPUT.PUT_LINE('Movimientos del producto:');
    SP_LISTAR_MOVIMIENTOS(1001, v_cursor);
    
    LOOP
        FETCH v_cursor INTO vn_id_mov, vn_tipo, vn_cantidad, vd_fecha, vv_observacion;
        EXIT WHEN v_cursor%NOTFOUND;
        
        DBMS_OUTPUT.PUT_LINE('ID Mov: ' || vn_id_mov || 
                             ' | Fecha: ' || TO_CHAR(vd_fecha, 'YYYY-MM-DD') || 
                             ' | Tipo: ' || vn_tipo || 
                             ' | Cantidad: ' || vn_cantidad || 
                             ' | Obs: ' || vv_observacion);
    END LOOP;
    
    CLOSE v_cursor;
END;

------------------------------------------------------------------- 3.5 (1 pt)
-- Bloque anonimo que cargue con BULK COLLECT los productos de una categoria en
-- una coleccion y use FORALL para actualizar su stock minimo.
-- Explique que costo concreto elimina esta tecnica y a partir de que volumen
-- empieza a notarse.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
BULK COLLECT permite traer múltiples filas desde SQL hacia una colección PL/SQL 
en una sola operación.  
FORALL permite ejecutar el mismo DML para todos los elementos de la colección en bloque.  
La técnica reduce el intercambio entre el motor SQL y el motor PL/SQL (context 
switches), evitando ejecutar un UPDATE individual desde un LOOP para cada producto 
y mejorando el rendimiento cuando se procesan muchas filas. 
*/
DECLARE

    TYPE t_productos IS TABLE OF PRODUCTO.id_producto%TYPE;
    vtProductos t_productos;
    vcIdCategoria CATEGORIA.id_categoria%TYPE := 1;

BEGIN

    SELECT id_producto
    BULK COLLECT INTO vtProductos
    FROM PRODUCTO
    WHERE id_categoria = vcIdCategoria AND activo = 'S';

    FORALL i IN 1 .. vtProductos.COUNT
        UPDATE PRODUCTO SET stock_minimo = stock_minimo + 5 WHERE id_producto = vtProductos(i);

END;
/
--Pruebas:
SELECT id_producto, activo, stock_minimo
FROM   PRODUCTO WHERE id_categoria = 1 ORDER BY id_producto;
-- Ejecutar bloque anónimo
SELECT id_producto, stock_minimo FROM PRODUCTO WHERE id_categoria = 1 ORDER BY id_producto;
ROLLBACK;
/

--==============================================================================
-- PARTE 4 — MANEJO DE EXCEPCIONES                             (9 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 4.1 (2 pts)
-- FN_PRECIO_PRODUCTO
-- Funcion que reciba el CODIGO de un producto y retorne su precio, manejando
-- explicitamente NO_DATA_FOUND y TOO_MANY_ROWS, con retorno de -1 y -2
-- respectivamente, e imprimiendo un mensaje descriptivo en cada caso.
-- Explique en que situacion real se produciria TOO_MANY_ROWS sobre esta tabla,
-- considerando las restricciones que hoy tiene.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos SELECT INTO en lugar de un cursor explicito porque se espera una 
-- sola fila. Dejamos al motor mismo levantar automaticamente 
-- las excepciones NO_DATA_FOUND y TOO_MANY_ROWS y asi podemos capturarlas en EXCEPTION
-- sin usar IF o contadores manuales. Los mensajes (DBMS_OUTPUT) los pusimos antes del RETURN 
-- para que se impriman antes de que la funcion termine.
-- 
-- Situacion real: La tabla PRODUCTO tiene la restriccion 
-- UNIQUE (uk_producto_codigo).Entonces por diseñono puede devolver 
-- TOO_MANY_ROWS. En un entorno real, esta excepcion solo saldria si un alguien 
-- de base de datos con permisos suficientes deshabilita temporalmente la restriccion (DISABLE CONSTRAINT) 
-- para hacer una carga masiva de datos y entonces se insertan duplicados por error, y esta 
-- funcion se ejecuta antes de que se limpie los datos y se reactive la restriccion.
CREATE OR REPLACE FUNCTION FN_PRECIO_PRODUCTO (
    p_codigo IN VARCHAR2
) RETURN NUMBER IS
 vn_precio PRODUCTO.precio_unitario%TYPE;
BEGIN
    --Se espera una sola fila
    SELECT precio_unitario
    INTO   vn_precio
    FROM   PRODUCTO
    WHERE  codigo = p_codigo;
    
    RETURN vn_precio;
EXCEPTION
    --No encontro nada
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('Aviso: No se encontro ningun producto registrado con el codigo: ' || p_codigo);
        RETURN -1;
    --Mas filas de las que deberia haber.No deberia pasar
    WHEN TOO_MANY_ROWS THEN
        DBMS_OUTPUT.PUT_LINE('Error critico: Se encontraron multiples productos con el codigo ' || p_codigo || '.');
        RETURN -2;
    --Cualquier otro error
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error en FN_PRECIO_PRODUCTO: ' || SQLERRM);
        RAISE;
        
END FN_PRECIO_PRODUCTO;
/

select FN_PRECIO_PRODUCTO('HM-0001') as codigoExistente,
       FN_PRECIO_PRODUCTO('1') as codigoInexistente
from dual;

------------------------------------------------------------------- 4.2 (2 pts)
-- SP_VALIDAR_DESPACHO
-- Procedimiento que verifique si puede despacharse una cantidad de un producto
-- desde una bodega. Debe declarar una EXCEPCION PROPIA, levantarla con RAISE
-- cuando la cantidad solicitada supere el disponible, y capturarla en el bloque
-- EXCEPTION.
-- Argumente por que conviene nombrar esa condicion en lugar de resolverla con un
-- condicional.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*¿Que hace? El procedimiento recibe un producto, una bodega y la cantidad que se 
quiere despachar, se verifica si se puede hacer el despacho con la cantidad en EXISTENCIA
y la compara con la cantidad pedida, si es mayor a la cantidad en stock se define 
la variable de salida del procedimiento como insuficiente, y se eleva la excepcion si es 
insuficiente, pero si es suficiente se imprimen la cantidad disponible en bodega.
¿por que? Se realiza con una excepcion propia porque oracle no cuenta con una que 
verifique esta regla, lanzar el error con raise separa el caso del error, se usa un 
procedimiento con salida porque el resultado no modifica niinguna tabla. */


CREATE OR REPLACE PROCEDURE SP_VALIDAR_DESPACHO (
    p_id_producto IN NUMBER,
    p_id_bodega   IN NUMBER,
    p_cantidad    IN NUMBER,
    p_suficiente OUT BOOLEAN
) IS
    e_stock_insuficiente EXCEPTION;
    vn_cantidad NUMBER := 0;
    vb_suficiente BOOLEAN := FALSE;
BEGIN
    SELECT cantidad 
    INTO vn_cantidad
    FROM EXISTENCIA 
    WHERE id_producto = p_id_producto
    AND id_bodega = p_id_bodega;
    
    IF  p_cantidad > vn_cantidad THEN
        vb_suficiente := FALSE;
        
        RAISE e_stock_insuficiente;
    ELSE 
        vb_suficiente := TRUE;
        dbms_output.put_line('Cantidad en stock disponible: ' || vn_cantidad || ' ');
    END IF;
    
    p_suficiente := vb_suficiente ;
    
EXCEPTION
    WHEN e_stock_insuficiente THEN
        dbms_output.put_line('La cantidad de productos en stock es insuficiente');
    
END SP_VALIDAR_DESPACHO;
/

-- PRUEBA 4.2
DECLARE
    vb_suficiente BOOLEAN;
    vn_id_producto NUMBER := 1001;
    vn_id_bodega NUMBER := 1;
    vn_cantidad NUMBER := 50;
BEGIN
    
    SP_VALIDAR_DESPACHO(vn_id_producto, vn_id_bodega, vn_cantidad, vb_suficiente); 
    IF vb_suficiente THEN
        dbms_output.put_line('Para la consulta de ' || vn_cantidad || 
        ' produtos de la referencia: ' || vn_id_producto);
        dbms_output.put_line('Resultado: puede despacharse');
    ELSE
        dbms_output.put_line('  Resultado: NO puede despacharse');
    END IF;
END;
/

------------------------------------------------------------------- 4.3 (2 pts)
-- SP_ANULAR_PEDIDO
-- Procedimiento que anule un pedido, usando RAISE_APPLICATION_ERROR con estos
-- codigos:
--     -20010  el pedido no existe
--     -20011  el pedido ya esta anulado
--     -20012  el pedido tiene mas de 30 dias
-- Explique la diferencia entre RAISE y RAISE_APPLICATION_ERROR, y en que caso el
-- cliente de la base de datos puede distinguirlos.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
RAISE permite lanzar una excepción PL/SQL, normalmente una excepción predefinida
o una excepción declarada por el programador.  
RAISE_APPLICATION_ERROR permite generar un error personalizado con un código 
entre -20000 y -20999 y un mensaje definido por el programador. 
Por eso RAISE_APPLICATION_ERROR es apropiado cuando se busca devolver errores específicos, 
indicando un mensaje en cada caso. 
*/
CREATE OR REPLACE PROCEDURE SP_ANULAR_PEDIDO (
    p_id_pedido IN NUMBER
) IS

    vpFecha  PEDIDO.fecha_pedido%TYPE;
    vpEstado PEDIDO.estado%TYPE;

BEGIN

    BEGIN
        SELECT fecha_pedido, estado INTO vpFecha, vpEstado
        FROM PEDIDO
        WHERE id_pedido = p_id_pedido;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20010, 'EL PEDIDO NO EXISTE');
    END;

    IF vpEstado = 'ANULADO' THEN RAISE_APPLICATION_ERROR( -20011, 'EL PEDIDO YA ESTÁ ANULADO' );
    END IF;

    IF vpFecha < SYSDATE - 30 THEN RAISE_APPLICATION_ERROR(-20012, 'EL PEDIDO TIENE MAS DE 30 DÍAS');
    END IF;

    UPDATE PEDIDO SET estado = 'ANULADO' WHERE id_pedido = p_id_pedido;
END SP_ANULAR_PEDIDO;
/

--Pruebas
DECLARE
    v_estado PEDIDO.estado%TYPE;
BEGIN
    FOR r IN (SELECT 999 id, 'no existe' caso FROM dual
              UNION ALL SELECT 7, 'ya anulado'     FROM dual
              UNION ALL SELECT 1, 'mas de 30 dias' FROM dual) LOOP
        BEGIN
            SP_ANULAR_PEDIDO(r.id);
            DBMS_OUTPUT.PUT_LINE(RPAD(r.caso, 16) || '-> anulado (no deberia)');
        EXCEPTION WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE(RPAD(r.caso, 16) || '-> ' || SQLCODE || ' ' || SQLERRM);
        END;
    END LOOP;
    
    INSERT INTO PEDIDO (id_pedido, id_cliente) VALUES (9001, 501);
    SP_ANULAR_PEDIDO(9001);
    SELECT estado INTO v_estado FROM PEDIDO WHERE id_pedido = 9001;
    DBMS_OUTPUT.PUT_LINE(RPAD('pedido valido', 16) || '-> estado ' || v_estado);   -- ANULADO
    ROLLBACK;
END;
/
------------------------------------------------------------------- 4.4 (2 pts)
-- Bloque anonimo que intente insertar un producto con una categoria inexistente
-- y capture el error de integridad referencial asociando ORA-02291 a una
-- excepcion con nombre.
-- Explique que aporta esa asociacion frente a atrapar el error en un manejador
-- generico.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos PRAGMA EXCEPTION_INIT para enlazar un error de Oracle (ORA-02291: violation of foreign key) 
-- con una excepcion de nosotros (e_categoria_invalida). Esto nos deja capturar la falla por su nombre
-- en la clausula WHEN.
-- 
-- WHEN OTHERS: Capturar el error dentro de un WHEN OTHERS es una mala practica porque obliga a tragarse todos los errores posibles.
-- Si usaramos OTHERS,habria que programar un IF para saber que paso. 
-- Al usar el PRAGMA, logramos un control especifico porque atrapamos solo el error especifico 
-- y asi cualquier otro error no visto escale de forma natural.


DECLARE
    --Exepcion propia
    e_categoriaInvalida EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_categoriaInvalida, -2291);

BEGIN
    DBMS_OUTPUT.PUT_LINE('Intentando insertar producto.');
    
    INSERT INTO PRODUCTO (id_producto, codigo, nombre, id_categoria, 
                          precio_unitario, costo_unitario, stock_minimo, activo)
    VALUES (9999, 'PP-0044', 'Prueba2', 999, 
            20000, 15000, 10, 'S');
            
    -- Si el insert funcionara se confirma(no funciona)
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Insercion exitosa.'); 

EXCEPTION
    WHEN e_categoriaInvalida THEN
        DBMS_OUTPUT.PUT_LINE('Error: No se puede registrar el producto porque la categoria indicada no existe.');
        ROLLBACK;
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        RAISE;
END;
/

------------------------------------------------------------------- 4.5 (1 pt)
-- SP_REGISTRAR_ERROR
-- Procedimiento que reciba el origen y registre en LOG_ERRORES el SQLCODE y el
-- SQLERRM actuales. El registro debe persistir aunque la transaccion principal
-- termine en ROLLBACK.
-- Explique por que se requiere esa independencia transaccional y describa un
-- escenario en el que esa misma independencia oculte informacion en lugar de
-- preservarla.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
Se utiliza una transacción autónoma para que el registro del error sea independiente
de la transacción principal. De esta forma, si la operación principal falla y 
posteriormente realiza ROLLBACK, el registro almacenado en LOG_ERRORES permanece. 
SQLCODE y SQLERRM permiten registrar automáticamente el código y mensaje del error
que se encuentra activo cuando se ejecuta el procedimiento. 
*/

CREATE OR REPLACE PROCEDURE SP_REGISTRAR_ERROR (
    p_origen  IN VARCHAR2,
    p_detalle IN VARCHAR2 DEFAULT NULL
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    vn_codigo  NUMBER;
    vc_mensaje VARCHAR2(500);
BEGIN
    vn_codigo  := SQLCODE;
    vc_mensaje := SUBSTR(SQLERRM, 1, 500);  
 
    INSERT INTO LOG_ERRORES (id_log, origen, codigo_error, mensaje, detalle, usuario_bd, fecha_log)
    VALUES (SEQ_LOG.NEXTVAL, p_origen, vn_codigo, vc_mensaje, p_detalle, USER, SYSTIMESTAMP);
    COMMIT;
END SP_REGISTRAR_ERROR;
/
--Pruebas:
DECLARE
    v NUMBER;
BEGIN
    INSERT INTO PEDIDO (id_pedido, id_cliente) VALUES (9002, 501);  
    SELECT 1 / 0 INTO v FROM dual;                                  
EXCEPTION WHEN OTHERS THEN
    SP_REGISTRAR_ERROR('PRUEBA_4_5', 'division por cero provocada');
    ROLLBACK;
END;
/
SELECT COUNT(*) AS pedido_9002_tras_rollback FROM PEDIDO WHERE id_pedido = 9002;   
SELECT origen, codigo_error, mensaje, detalle
FROM   LOG_ERRORES WHERE origen = 'PRUEBA_4_5';  
 
DELETE FROM LOG_ERRORES WHERE origen = 'PRUEBA_4_5';
COMMIT;
/

--==============================================================================
-- PARTE 5 — DISPARADORES                                     (10 puntos / 90 min)
--==============================================================================
-- Los esqueletos de esta parte no incluyen la clausula de disparo. Definirla
-- hace parte del ejercicio.
--==============================================================================

------------------------------------------------------------------- 5.1 (2 pts)
-- TRG_CLIENTE_BI
-- Al insertar un cliente debe asignar el identificador desde SEQ_CLIENTE si
-- llega nulo, convertir el nombre a mayusculas sin espacios sobrantes y forzar
-- el estado activo a 'S' si no se indica.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Usamos el disparador antes de la insercion para garantizar que los datos 
-- defectuosos o incompletos no lleguen a escribirse para no corregirlos despues
-- de guardados.La asignacion automatica solo pasa si el dato falta, para no bloquear
-- cargas manuales o migraciones que necesiten conservar sus propios codigos.
-- La normalizacion de nombres (mayusculas y 
-- sin espacios extra) se dejo a la base de datos para que la 
-- informacion siempre sea uniforme sin depender de la aplicacion externa.
-- Se fuerza el valor 'S' cuando no hay dato para que el sistema no falle por violar el NOT NULL 
-- asegurando que el proceso continue.

CREATE OR REPLACE TRIGGER TRG_CLIENTE_BI
BEFORE INSERT ON CLIENTE
FOR EACH ROW
BEGIN
    --Si llega nulo, asignar el identificador
    IF :NEW.id_cliente IS NULL THEN
        :NEW.id_cliente := SEQ_CLIENTE.NEXTVAL;
    END IF;

    -- Nombre a mayusculas y sin espacios sobrantes
    IF :NEW.nombre IS NOT NULL THEN
        -- TRIM quita espacios a los bordes, REGEXP_REPLACE quita multiples espacios internos
        :NEW.nombre := TRIM(REGEXP_REPLACE(UPPER(:NEW.nombre), '\s+', ' '));
    END IF;

    -- Forzar el estado activo a 'S' si no se indica (llega nulo)
    IF :NEW.activo IS NULL THEN
        :NEW.activo := 'S';
    END IF;
END;
/

INSERT INTO CLIENTE (id_cliente, documento, nombre, ciudad, activo)
VALUES (NULL, '999888777', '   ferreteria    los   andes  ', 'Bogota', NULL);
select * from CLIENTE where documento = '999888777';
/

------------------------------------------------------------------- 5.2 (2 pts)
-- TRG_PRODUCTO_AU_PRECIO
-- Debe registrar en AUDITORIA_PRECIO todo cambio de precio, calculando la
-- variacion porcentual, y dispararse unicamente cuando el precio efectivamente
-- cambie, resolviendo esa condicion con la clausula WHEN y no dentro del cuerpo.
-- Explique la diferencia entre ambas formas.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
El trigger garantiza que cada modificación real del precio de un producto quede 
registrada automáticamente en AUDITORIA_PRECIO, sin depender de que el programador 
recuerde realizar el registro manualmente.  
Se utiliza un trigger AFTER UPDATE porque la auditoría debe realizarse después de
que el cambio de precio haya sido efectuado. Al ser FOR EACH ROW, permite acceder
a :OLD y :NEW para conocer el precio anterior y el nuevo. La cláusula WHEN evita 
generar registros cuando el precio realmente no cambió.  
Además, se calcula variacion_pct para conservar no solamente los dos precios, sino
también el porcentaje de modificación.  
*/
CREATE OR REPLACE TRIGGER TRG_PRODUCTO_AU_PRECIO
    AFTER UPDATE OF precio_unitario ON PRODUCTO
    FOR EACH ROW
    WHEN (OLD.precio_unitario <> NEW.precio_unitario)

BEGIN

    INSERT INTO AUDITORIA_PRECIO (id_auditoria, id_producto, precio_anterior, precio_nuevo, variacion_pct)
    VALUES (SEQ_AUDITORIA.NEXTVAL, :OLD.id_producto, :OLD.precio_unitario, :NEW.precio_unitario,
        ((:NEW.precio_unitario - :OLD.precio_unitario)/ :OLD.precio_unitario) * 100);

END;
/
--Pruebas:
UPDATE PRODUCTO SET precio_unitario = 50000 WHERE id_producto = 1001;           
UPDATE PRODUCTO SET precio_unitario = 50000 WHERE id_producto = 1001;           
UPDATE PRODUCTO SET precio_unitario = precio_unitario WHERE id_producto = 1001; 
UPDATE PRODUCTO SET nombre = nombre WHERE id_producto = 1001;                   
SELECT id_producto, precio_anterior, precio_nuevo, variacion_pct
FROM   AUDITORIA_PRECIO WHERE id_producto = 1001;   
ROLLBACK;
/

------------------------------------------------------------------- 5.3 (2 pts)
-- TRG_PRODUCTO_BIU_MARGEN
-- Debe impedir que se guarde un producto cuyo precio no alcance el margen minimo
-- de su categoria, segun la formula precio >= costo * (1 + margen/100),
-- rechazando la operacion con el error -20020.
-- Considere que debe ocurrir cuando la categoria indicada no existe, y justifique
-- su decision.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/* ¿Que hace? El trigger se dispara en cada intento de insertar o actualizar un producto
cuyo precio unitario sea menor al minimo establecido por la categoria del producto
y el costo unitario del producto, evitando que en algun momento el producto se venda 
muy por debajo del minimo de lo que se puede vender el producto. 
Cuando la categoria no existe se eleva la excepcion NO_DATA_FOUND y se informa que
no se encontro la categoria, elegimos esta opcion porque sin la categoria no se puede 
calcular el minimo, asi que no se puede garantizar la regla y es mas seguro rechazar 
que dejar pasar la fila. Ademas, no permite continuar luego de lanzar la excepcion 
gracias al RAISE_APPLICATION_ERROR (-20021,Categoria no encontrada)
¿Por que? Se usa un trigger con el proposito de evitar que cualquier intento de insertar 
o actualizar un producto de forma incorrecta, se dispara el trigger y cancela cualquier 
intento. Ademas, dentro del trigger usamos BEFORE, y no after, ya que lo que necesitamos
es que se evite que se dispare ANTES de poder insertar o actualizar un producto. Tambien
usamos FOR EACH ROW porque necesita los valores :NEW de cada producto, :NEW y no un 
select porque leer la tabla desde el trigger causaria el error de tabla mutante. */

CREATE OR REPLACE TRIGGER TRG_PRODUCTO_BIU_MARGEN
    BEFORE INSERT OR UPDATE ON PRODUCTO
    FOR EACH ROW
DECLARE
    vn_margen NUMBER;
    vn_minimo NUMBER;
BEGIN
    SELECT margen_minimo
    INTO   vn_margen
    FROM   CATEGORIA
    WHERE  id_categoria = :NEW.id_categoria;

    vn_minimo := :NEW.costo_unitario * (1 + vn_margen / 100);

    IF :NEW.precio_unitario < vn_minimo THEN
        RAISE_APPLICATION_ERROR(-20020,
            'Precio ' || :NEW.precio_unitario || ' por debajo del minimo permitido ' ||
            vn_minimo || ' (margen ' || vn_margen || '%)');
    END IF;
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20021,'No se encontró la categoria');
END;
/

-- PRUEBA 5.3.1 (Deberia disparar)
BEGIN
    INSERT INTO PRODUCTO VALUES (2001, 'TST-001', 'Prueba 1', 1, 20000, 28000, 0, 'S');
    dbms_output.put_line('Insertado.');
    
EXCEPTION
    WHEN OTHERS THEN dbms_output.put_line(SQLERRM);
END;
/
-- PRUEBA 5.3.2 (Deberia insertar)
BEGIN
    INSERT INTO PRODUCTO VALUES (2001, 'TST-001', 'Prueba 1', 1, 40000, 28000, 0, 'S');
    dbms_output.put_line('Insert valido: aceptado');
    
EXCEPTION
    WHEN OTHERS THEN dbms_output.put_line(SQLERRM);
END;
/
-- PRUEBA 5.3.3  (Disparar con una actualizacion)
BEGIN
   BEGIN
        UPDATE PRODUCTO SET precio_unitario = 30000 WHERE id_producto = 2001;
        dbms_output.put_line('Update: aceptado (no deberia)');
EXCEPTION 
    WHEN OTHERS THEN 
        dbms_output.put_line('Actualizacion: ' || SQLERRM);
END;

    
SELECT p.id_producto, p.nombre, c.nombre AS categoria, p.precio_unitario, p.costo_unitario, c.margen_minimo
FROM PRODUCTO p 
LEFT JOIN CATEGORIA c ON p.id_categoria = c.id_categoria;

ROLLBACK;

SELECT text FROM user_source WHERE name = 'TRG_PRODUCTO_BIU_MARGEN' ORDER BY line;
/

------------------------------------------------------------------- 5.4 (2 pts)
-- TRG_DETALLE_AI_STOCK
-- Al insertar una linea de pedido debe descontar el stock de la bodega indicada
-- y registrar el movimiento de SALIDA correspondiente. Si no hay stock suficiente
-- debe abortar la operacion con el error -20030.
-- Explique por que el momento de disparo que eligio es el correcto y que dejaria
-- de funcionar con el contrario.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- El disparador actua despues de insertar porque es propagar un efecto a otras tablas
-- no alterar los datos del propio detalle del pedido. 
-- 
-- Si lo hicieramos ANTES el disparador modificaria el inventario sin saber si el detalle del pedido es valido. 
-- Dejaria de funcionar la logica porque podriamos descontar stock 
-- para una linea de pedido que el motor de base de datos terminara rechazando 
-- despues por violar una restriccion desperdiciando procesamiento en operaciones destinadas a fallar.
--
-- Usamos FOR UPDATE al consultar la existencia para 
-- bloquear la fila y asi evitar que si dos vendedores registran un 
-- detalle al mismo tiempo para el mismo producto el sistema lea el mismo saldo 
-- inicial para ambos y termine aprobando ventas sin stock real.

CREATE OR REPLACE TRIGGER TRG_DETALLE_AI_STOCK
AFTER INSERT ON DETALLE_PEDIDO
FOR EACH ROW
DECLARE
    v_stock_actual EXISTENCIA.cantidad%TYPE;
BEGIN
    --Se consulta el stock actual de la bodega bloqueando la fila
    SELECT cantidad
    INTO   v_stock_actual
    FROM   EXISTENCIA
    WHERE  id_bodega = :NEW.id_bodega
      AND  id_producto = :NEW.id_producto
    FOR UPDATE;

    --Validacion del stock suficiente
    IF :NEW.cantidad > v_stock_actual THEN
        RAISE_APPLICATION_ERROR(-20030, 'Error: Stock insuficiente en la bodega para el producto solicitado.');
    END IF;

    --Actualizacion del inventario
    UPDATE EXISTENCIA
    SET    cantidad = cantidad - :NEW.cantidad
    WHERE  id_bodega = :NEW.id_bodega
      AND  id_producto = :NEW.id_producto;

    --Registro en la bitacora de movimientos
    INSERT INTO MOVIMIENTO_INVENTARIO (
        id_movimiento, 
        id_producto, 
        id_bodega, 
        tipo, 
        cantidad, 
        id_pedido, 
        observacion
    ) VALUES (
        SEQ_MOVIMIENTO.NEXTVAL, 
        :NEW.id_producto, 
        :NEW.id_bodega, 
        'SALIDA', 
        :NEW.cantidad, 
        :NEW.id_pedido, 
        'Despacho automatico por nueva linea de pedido'
    );
    
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- Si la combinacion producto-bodega no existe en EXISTENCIA, no hay stock
        RAISE_APPLICATION_ERROR(-20030, 'Error: El producto no tiene registro en la bodega indicada.');
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        RAISE;
END;
/

SELECT cantidad as cantidad1001 FROM EXISTENCIA WHERE id_bodega = 1 AND id_producto = 1001;
INSERT INTO DETALLE_PEDIDO (id_pedido, linea, id_producto, id_bodega, cantidad, precio_unitario, subtotal)
VALUES (6, 1, 1001, 1, 10, 45000, 450000);
SELECT cantidad FROM EXISTENCIA WHERE id_bodega = 1 AND id_producto = 1001;
SELECT id_movimiento, tipo, cantidad, observacion FROM MOVIMIENTO_INVENTARIO WHERE id_pedido = 6;

INSERT INTO DETALLE_PEDIDO (id_pedido, linea, id_producto, id_bodega, cantidad, precio_unitario, subtotal)
VALUES (6, 2, 1001, 1, 5000, 45000, 225000000);
/


------------------------------------------------------------------- 5.5 (1 pt)
-- TRG_DETALLE_TOTAL
-- Debe recalcular el total de la cabecera del pedido despues de cualquier
-- insercion, actualizacion o borrado de sus lineas.
-- Documente el error que obtiene en su primer intento, en que momento aparece,
-- y como lo resuelve la construccion que finalmente utilizo.
-- Este punto no se califica sin esa explicacion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
El trigger mantiene sincronizado el campo total de PEDIDO con la suma de los subtotales
de sus detalles. Cuando se inserta, modifica o elimina un detalle, el total del pedido
debe recalcularse porque los valores que lo componen han cambiado.  
Se utiliza un compound trigger porque DETALLE_PEDIDO es precisamente la tabla que
contiene los detalles que se están modificando. Intentar o consultar directamente 
esa misma tabla durante determinados momentos de un trigger de fila puede producir
el error de tabla mutante. La solución consiste en guardar durante AFTER EACH ROW
los pedidos afectados y realizar el cálculo cuando termina la sentencia, en AFTER STATEMENT. 

Esto además permite manejar correctamente los tres casos:  
INSERT: aparece un nuevo detalle. 
UPDATE: cambia un detalle existente. 
DELETE: desaparece un detalle. 

Finalmente, el total se obtiene mediante SUM(subtotal) y se actualiza en PEDIDO. 
Esto corresponde directamente con el modelo, donde DETALLE_PEDIDO contiene subtotal 
y PEDIDO contiene total. 
*/
CREATE OR REPLACE TRIGGER TRG_DETALLE_TOTAL
    FOR INSERT OR UPDATE OR DELETE ON DETALLE_PEDIDO
    COMPOUND TRIGGER

    TYPE t_pedidos IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
    v_pedidos t_pedidos;

    AFTER EACH ROW IS
    BEGIN

        IF INSERTING OR UPDATING THEN v_pedidos(:NEW.id_pedido) := TRUE;
        END IF;
        IF DELETING OR UPDATING THEN v_pedidos(:OLD.id_pedido) := TRUE;
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
        v_id_pedido PLS_INTEGER;
    BEGIN

        v_id_pedido := v_pedidos.FIRST;

        WHILE v_id_pedido IS NOT NULL LOOP

            UPDATE PEDIDO SET total = (SELECT NVL(SUM(subtotal), 0) FROM DETALLE_PEDIDO WHERE id_pedido = v_id_pedido)
            WHERE id_pedido = v_id_pedido;
            v_id_pedido := v_pedidos.NEXT(v_id_pedido);
        END LOOP;

    END AFTER STATEMENT;

END;
/
--Pruebas:
DECLARE
    PROCEDURE total(p_msg VARCHAR2) IS
        v NUMBER;
    BEGIN
        SELECT total INTO v FROM PEDIDO WHERE id_pedido = 9001;
        DBMS_OUTPUT.PUT_LINE(RPAD(p_msg, 36) || '-> total ' || v);
    END;
BEGIN
    INSERT INTO PEDIDO (id_pedido, id_cliente) VALUES (9001, 501);
    INSERT INTO DETALLE_PEDIDO VALUES (9001, 1, 1001, 1, 2,  45000, 90000);
    total('INSERT linea 1');                                 
    INSERT INTO DETALLE_PEDIDO VALUES (9001, 2, 1002, 1, 1,  62000, 62000);
    total('INSERT linea 2');                                 
    INSERT INTO DETALLE_PEDIDO                               
        SELECT 9001, 3, 1003, 1, 1, 38000, 38000 FROM dual
        UNION ALL
        SELECT 9001, 4, 1008, 1, 1, 18500, 18500 FROM dual;
    total('INSERT multifila (lineas 3 y 4)');                
    UPDATE DETALLE_PEDIDO SET subtotal = 100000 WHERE id_pedido = 9001 AND linea = 1;
    total('UPDATE linea 1 a 100.000');                       
    DELETE FROM DETALLE_PEDIDO WHERE id_pedido = 9001 AND linea = 2;
    total('DELETE linea 2');                                 
    DELETE FROM DETALLE_PEDIDO WHERE id_pedido = 9001;
    total('DELETE de todas las lineas');                     
    ROLLBACK;
END;
/

------------------------------------------------------------------- 5.6 (1 pt)
-- TRG_V_STOCK_IO
-- Debe permitir actualizar el precio y el stock minimo del producto a traves de
-- la vista V_STOCK_CONSOLIDADO.
-- Explique por que esa vista no es actualizable de forma directa.
-------------------------------------------------------------------------------
-- JUSTIFICACION:

CREATE OR REPLACE TRIGGER TRG_V_STOCK_IO
    INSTEAD OF UPDATE ON V_STOCK_CONSOLIDADO
    FOR EACH ROW
BEGIN

    UPDATE PRODUCTO
    SET precio_unitario = :NEW.precio_unitario,
    stock_minimo = :NEW.stock_minimo
    WHERE id_producto = :OLD.id_producto;
    
END;
/
SHOW ERRORS

UPDATE V_STOCK_CONSOLIDADO SET precio_unitario = 50000 , stock_minimo = 25 WHERE id_producto = 1001;

SELECT id_producto, precio_unitario, stock_minimo
FROM   PRODUCTO WHERE id_producto = 1001;

ROLLBACK;

--==============================================================================
-- PARTE 6 — CASO INTEGRADOR                                   (5 puntos / 45 min)
--==============================================================================

-------------------------------------------------------------------------------
-- PKG_VENTAS
-- Construya un PAQUETE que exponga el procedimiento SP_FACTURAR_PEDIDO, el cual,
-- para un pedido en estado BORRADOR, debe:
--
--   1. Validar que el pedido exista y este en BORRADOR
--   2. Recorrer sus lineas con un cursor y acumular el subtotal
--   3. Calcular el descuento con FN_CALCULAR_DESCUENTO
--   4. Validar contra FN_CUPO_DISPONIBLE que el cliente tenga cupo suficiente
--   5. Actualizar el total del pedido y cambiar su estado a CONFIRMADO
--   6. Incrementar el saldo pendiente del cliente
--   7. Usar SAVEPOINT y revertir parcialmente ante cualquier fallo, registrando
--      el error con SP_REGISTRAR_ERROR
--   8. Devolver por parametros OUT el total facturado y el descuento aplicado
--
-- Firma esperada:
--   PKG_VENTAS.SP_FACTURAR_PEDIDO(p_id_pedido IN NUMBER,
--                                 p_total     OUT NUMBER,
--                                 p_descuento OUT NUMBER)
--
-- Se evalua la integracion. El procedimiento debe apoyarse en los objetos de las
-- partes 1 a 5 y no reimplementar su logica: uno que vuelva a codificar el
-- calculo del descuento pierde la mitad del puntaje de esta parte.
-- Defina explicitamente el alcance transaccional y justifique donde decidio
-- ubicar la confirmacion de la transaccion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
/*
Se construyó un paquete porque el enunciado pide exponer un único punto de entrada
(SP_FACTURAR_PEDIDO) y encapsular la lógica de facturación: la especificación publica 
solo la firma y el cuerpo oculta el cursor y las variables, de modo que nadie puede 
facturar saltándose las validaciones. El procedimiento no vuelve a hacer las reglas
de las partes anteriores, sino que se apoya en ellas: el descuento lo calcula 
FN_CALCULAR_DESCUENTO, el cupo lo valida FN_CUPO_DISPONIBLE y los errores se 
registran con SP_REGISTRAR_ERROR.  

Además, el stock y el total de cabecera ya fueron manejados por TRG_DETALLE_AI_STOCK 
y TRG_DETALLE_TOTAL cuando se insertaron las líneas, por eso aquí no se toca el inventario. 
El pedido se lee con FOR UPDATE para que dos sesiones no lo facturen a la vez y se bloquea 
también la fila del cliente antes de validar el cupo, porque sin ese bloqueo dos pedidos
del mismo cliente facturados en paralelo podrían pasar la validación con el mismo 
saldo y exceder el crédito, además de que los bloqueos se toman siempre en el mismo
orden (pedido y luego cliente) para evitar interbloqueos. Las líneas se recorren
con un cursor parametrizado porque el enunciado lo exige y porque permite acumular 
el subtotal en un solo recorrido, donde un pedido sin líneas se rechaza, ya que no
hay nada que facturar. El total facturado que se guarda en PEDIDO y se devuelve
por p_total es el neto (subtotal menos descuento), y ese mismo valor es el que 
se suma al saldo pendiente del cliente, de modo que lo que se factura, lo que queda
registrado y lo que se adeuda coinciden. El alcance transaccional es todo lo que 
ocurre entre el SAVEPOINT sp_facturar, que es la primera instrucción del procedimiento, y
su final: la actualización de PEDIDO y de CLIENTE forman una sola unidad, de manera 
que ante cualquier fallo el manejador registra el error, revierte únicamente hasta 
el savepoint y relanza la excepción con RAISE, dejando intacto lo que el llamador
hubiera hecho antes de invocarlo y permitiéndole saber que la factura no se generó. 
El registro del error se ejecuta antes del ROLLBACK TO SAVEPOINT porque SQLCODE y
SQLERRM deben seguir vigentes, y sobrevive a la reversión porque SP_REGISTRAR_ERROR 
es una transacción autónoma. La confirmación no se ubicó dentro del paquete sino en 
quien lo llama: facturar es un paso de un proceso de venta más grande (crear el pedido,
insertar líneas que descuentan stock, facturar), y si el procedimiento hiciera COMMIT
dejaría permanentes esos pasos previos, aunque el llamador necesitara deshacerlos
después, además de volverlo imposible de componer con otras operaciones. El único 
COMMIT que existe es el interno de SP_REGISTRAR_ERROR, que solo confirma el log. 
Los errores propios son -20401 (pedido inexistente), -20402 (pedido que no está 
en BORRADOR), -20403 (pedido sin líneas) y -20404 (cupo insuficiente), todos distinguibles
entre sí. Finalmente, el recorrido del cursor es lineal respecto al número de líneas 
y los bloqueos duran hasta que el llamador confirme o revierta, por lo que conviene
que esa decisión se tome de inmediato después de facturar. 
*/

CREATE OR REPLACE PACKAGE PKG_VENTAS IS
    PROCEDURE SP_FACTURAR_PEDIDO (p_id_pedido IN  NUMBER, p_total OUT NUMBER, p_descuento OUT NUMBER);
END PKG_VENTAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_VENTAS IS

    PROCEDURE SP_FACTURAR_PEDIDO (p_id_pedido IN  NUMBER, p_total OUT NUMBER, p_descuento OUT NUMBER
    ) IS
        CURSOR c_lineas (p_pedido PEDIDO.id_pedido%TYPE) IS
            SELECT linea, subtotal FROM   DETALLE_PEDIDO
            WHERE  id_pedido = p_pedido
            ORDER  BY linea;

        vpIdCliente PEDIDO.id_cliente%TYPE;
        vpEstado     PEDIDO.estado%TYPE;
        vcSaldo      CLIENTE.saldo_pendiente%TYPE;
        vnSubtotal   NUMBER := 0;
        vnLineas     PLS_INTEGER := 0;
        vnDescuento  NUMBER;
        vnNeto       NUMBER;
        vnCupo       NUMBER;
    BEGIN
        SAVEPOINT sp_facturar;

        BEGIN
            SELECT id_cliente, estado
            INTO   vpIdCliente, vpEstado
            FROM   PEDIDO
            WHERE  id_pedido = p_id_pedido
            FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20401, 'El pedido ' || p_id_pedido || ' no existe');
        END;

        IF vpEstado <> 'BORRADOR' THEN RAISE_APPLICATION_ERROR(-20402,
                'El pedido ' || p_id_pedido || ' esta en estado ' || vpEstado ||
                ' y solo se factura un pedido en BORRADOR');
        END IF;

        FOR r IN c_lineas(p_id_pedido) LOOP
            vnSubtotal := vnSubtotal + r.subtotal;
            vnLineas   := vnLineas + 1;
        END LOOP;

        IF vnLineas = 0 THEN
            RAISE_APPLICATION_ERROR(-20403, 'El pedido ' || p_id_pedido || ' no tiene lineas');
        END IF;

        SELECT saldo_pendiente INTO   vcSaldo
        FROM   CLIENTE
        WHERE  id_cliente = vpIdCliente
        FOR UPDATE;

        vnDescuento := FN_CALCULAR_DESCUENTO(vpIdCliente, vnSubtotal);
        vnNeto      := vnSubtotal - vnDescuento;
        vnCupo      := FN_CUPO_DISPONIBLE(vpIdCliente);

        IF vnNeto > vnCupo THEN RAISE_APPLICATION_ERROR(-20404,
                'Cupo insuficiente: el total a facturar ' || vnNeto ||
                ' supera el cupo disponible ' || vnCupo);
        END IF;

        UPDATE PEDIDO SET    total  = vnNeto, estado = 'CONFIRMADO'
        WHERE  id_pedido = p_id_pedido;

        UPDATE CLIENTE
        SET    saldo_pendiente = saldo_pendiente + vnNeto
        WHERE  id_cliente = vpIdCliente;

        p_total     := vnNeto;
        p_descuento := vnDescuento;
    EXCEPTION
        WHEN OTHERS THEN
            SP_REGISTRAR_ERROR('PKG_VENTAS.SP_FACTURAR_PEDIDO pedido=' || p_id_pedido);
            ROLLBACK TO SAVEPOINT sp_facturar;
            p_total     := NULL;
            p_descuento := NULL;
            RAISE;
    END SP_FACTURAR_PEDIDO;

END PKG_VENTAS;
/

--Pruebas:
DECLARE
    vpPed    PEDIDO.id_pedido%TYPE;
    vnTotal  NUMBER;
    vnDesc   NUMBER;
    vpEstado PEDIDO.estado%TYPE;
BEGIN
    SP_CREAR_PEDIDO(503, vpPed);
    INSERT INTO DETALLE_PEDIDO VALUES (vpPed, 1, 1002, 1, 2, 62000, 124000);
    INSERT INTO DETALLE_PEDIDO VALUES (vpPed, 2, 1001, 1, 10, 45000, 450000);
    PKG_VENTAS.SP_FACTURAR_PEDIDO(vpPed, vnTotal, vnDesc);
    DBMS_OUTPUT.PUT_LINE('Pedido ' || vpPed || ' facturado. Total: ' || vnTotal || ' | Descuento: ' || vnDesc);
    DBMS_OUTPUT.PUT_LINE('Cupo disponible cliente 503: ' || FN_CUPO_DISPONIBLE(503));

    BEGIN
        PKG_VENTAS.SP_FACTURAR_PEDIDO(vpPed, vnTotal, vnDesc);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Refacturar el mismo pedido: ' || SQLERRM);
    END;

    SP_CREAR_PEDIDO(502, vpPed);
    INSERT INTO DETALLE_PEDIDO VALUES (vpPed, 1, 1004, 1, 2, 320000, 640000);
    BEGIN
        PKG_VENTAS.SP_FACTURAR_PEDIDO(vpPed, vnTotal, vnDesc);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Cliente 502: ' || SQLERRM);
    END;
    SELECT estado INTO vpEstado FROM PEDIDO WHERE id_pedido = vpPed;
    DBMS_OUTPUT.PUT_LINE('Estado del pedido tras el fallo: ' || vpEstado);

    BEGIN
        PKG_VENTAS.SP_FACTURAR_PEDIDO(9999, vnTotal, vnDesc);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Pedido inexistente: ' || SQLERRM);
    END;

    BEGIN
        PKG_VENTAS.SP_FACTURAR_PEDIDO(1, vnTotal, vnDesc);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('Pedido ya confirmado: ' || SQLERRM);
    END;

    ROLLBACK;
END;
/

SELECT id_log, origen, codigo_error, SUBSTR(mensaje, 1, 80) AS mensaje
FROM   LOG_ERRORES
ORDER  BY id_log;

--==============================================================================
-- FIN DE LA PLANTILLA
--==============================================================================
