import { Pool } from 'pg';
import { env } from '../config/env';
import { log } from '../utils/logger';
import { MemoryStore } from './memory';
import { PostgresStore } from './postgres';
import { Store } from './types';

export * from './types';

let store: Store | null = null;

export function getStore(): Store {
  if (store) return store;
  if (env.DATABASE_URL) {
    const pool = new Pool({ connectionString: env.DATABASE_URL });
    store = new PostgresStore(pool);
    log.info('storage: postgres');
  } else {
    store = new MemoryStore();
    log.warn('storage: in-memory (set DATABASE_URL for persistence)');
  }
  return store;
}

/** Test seam. */
export function setStore(custom: Store): void {
  store = custom;
}
