class AddCurrencySplitToShopOrders < ActiveRecord::Migration[8.1]
  def up
    add_column :shop_orders, :frozen_koi_amount, :integer
    add_column :shop_orders, :frozen_gold_amount, :integer, default: 0, null: false

    # Backfill historical orders: koi-currency items were charged entirely in koi,
    # gold-currency items entirely in gold, hours items not charged in either.
    execute <<~SQL.squish
      UPDATE shop_orders SET frozen_koi_amount = shop_orders.frozen_price * shop_orders.quantity
      FROM shop_items
      WHERE shop_items.id = shop_orders.shop_item_id AND shop_items.currency = 'koi'
    SQL
    execute <<~SQL.squish
      UPDATE shop_orders SET frozen_koi_amount = 0,
        frozen_gold_amount = shop_orders.frozen_price * shop_orders.quantity
      FROM shop_items
      WHERE shop_items.id = shop_orders.shop_item_id AND shop_items.currency = 'gold'
    SQL
    execute "UPDATE shop_orders SET frozen_koi_amount = 0 WHERE frozen_koi_amount IS NULL"

    change_column_null :shop_orders, :frozen_koi_amount, false
  end

  def down
    remove_column :shop_orders, :frozen_koi_amount
    remove_column :shop_orders, :frozen_gold_amount
  end
end
