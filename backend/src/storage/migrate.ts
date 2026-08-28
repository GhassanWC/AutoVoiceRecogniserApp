import { readFileSync } from 'fs';
import { join } from 'path';
import { Pool } from 'pg';
import { env } from '../config/env';

async function main(): Promise<void> {
  if (!env.DATABASE_URL) {
    // eslint-disable-next-line no-console
    console.error('DATABASE_URL is not set — nothing to migrate (in-memory mode needs no schema).');
    process.exit(1);
  }
  const pool = new Pool({ connectionString: env.DATABASE_URL });
  const schema = readFileSync(join(__dirname, 'schema.sql'), 'utf8');
  await pool.query(schema);
  await pool.end();
  // eslint-disable-next-line no-console
  console.log('Migration applied.');
}

main().catch((error) => {
  // eslint-disable-next-line no-console
  console.error('Migration failed:', error);
  process.exit(1);
});
