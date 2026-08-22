class AddCreatedAtIndexToCurrencyTransactions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # The admin ledger lists ORDER BY created_at DESC across the whole table. The only
  # created_at index is the composite (user_id, created_at), which can't serve an
  # unfiltered sort — so every page load full-scanned + sorted the table. A plain
  # btree on created_at serves the backward scan and makes the listing snappy.
  def change
    add_index :koi_transactions, :created_at, algorithm: :concurrently, if_not_exists: true
    add_index :gold_transactions, :created_at, algorithm: :concurrently, if_not_exists: true
  end
end
