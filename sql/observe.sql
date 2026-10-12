SELECT ENGINE_LOCK_ID, ENGINE_TRANSACTION_ID, THREAD_ID,
       OBJECT_SCHEMA, OBJECT_NAME, INDEX_NAME,
       LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks WHERE OBJECT_SCHEMA = 'deadlock_lab';

SELECT w.REQUESTING_ENGINE_TRANSACTION_ID AS waiting_trx,
       w.BLOCKING_ENGINE_TRANSACTION_ID AS blocking_trx,
       r.INDEX_NAME, r.LOCK_MODE AS requested_mode,
       r.LOCK_STATUS, r.LOCK_DATA AS requested_data,
       b.LOCK_MODE AS blocking_mode, b.LOCK_DATA AS blocking_data
FROM performance_schema.data_lock_waits w
JOIN performance_schema.data_locks r ON r.ENGINE = w.ENGINE
 AND r.ENGINE_LOCK_ID = w.REQUESTING_ENGINE_LOCK_ID
JOIN performance_schema.data_locks b ON b.ENGINE = w.ENGINE
 AND b.ENGINE_LOCK_ID = w.BLOCKING_ENGINE_LOCK_ID
WHERE r.OBJECT_SCHEMA = 'deadlock_lab';

SHOW ENGINE INNODB STATUS;
